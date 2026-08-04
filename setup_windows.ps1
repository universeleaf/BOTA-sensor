[CmdletBinding()]
param(
    [string]$NetworkInterfaceGuid,
    [string]$ConfigPath,
    [string]$NpcapInstallerPath,
    [switch]$SkipNpcap,
    [switch]$SkipPython
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$NpcapVersion = "1.88"
$NpcapUrl = "https://npcap.com/dist/npcap-$NpcapVersion.exe"
$ProjectRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ProjectRoot "bota_config.json"
}
$VenvPath = Join-Path $ProjectRoot ".venv"
$VenvPython = Join-Path $VenvPath "Scripts\python.exe"
$RequirementsPath = Join-Path $ProjectRoot "requirements.txt"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-NpcapState {
    $service = Get-Service -Name "npcap" -ErrorAction SilentlyContinue
    $parameters = Get-ItemProperty `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Services\npcap\Parameters" `
        -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        Installed = $null -ne $service
        Running = $null -ne $service -and $service.Status -eq "Running"
        WinPcapCompatible = $null -ne $parameters -and $parameters.WinPcapCompatible -eq 1
    }
}

function Install-NpcapIfNeeded {
    $state = Get-NpcapState
    if ($state.Installed -and $state.WinPcapCompatible) {
        Write-Host "Npcap 已安装，WinPcap 兼容模式已启用。" -ForegroundColor Green
        return
    }

    Write-Step "准备安装 Npcap $NpcapVersion"
    $installerPath = $NpcapInstallerPath
    if ([string]::IsNullOrWhiteSpace($installerPath)) {
        $localInstaller = Join-Path $ProjectRoot "npcap-$NpcapVersion.exe"
        if (Test-Path -LiteralPath $localInstaller) {
            $installerPath = $localInstaller
        }
        else {
            $downloadDirectory = Join-Path $env:TEMP "bota-sensor-setup"
            New-Item -ItemType Directory -Force -Path $downloadDirectory | Out-Null
            $installerPath = Join-Path $downloadDirectory "npcap-$NpcapVersion.exe"
            Write-Host "正在从官方地址下载 $NpcapUrl"
            Invoke-WebRequest -Uri $NpcapUrl -OutFile $installerPath -UseBasicParsing
        }
    }

    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "找不到 Npcap 安装程序：$installerPath"
    }

    $signature = Get-AuthenticodeSignature -FilePath $installerPath
    $signer = if ($null -ne $signature.SignerCertificate) {
        $signature.SignerCertificate.Subject
    }
    else {
        ""
    }
    if ($signature.Status -ne "Valid" -or $signer -notmatch "Nmap Software LLC") {
        throw "Npcap 安装程序签名验证失败，已停止安装。文件：$installerPath"
    }

    Write-Host "即将打开 Npcap 官方安装窗口。请确认 UAC，并点击 Install。" -ForegroundColor Yellow
    Write-Host "WinPcap API-compatible Mode 已由脚本强制启用。"
    $process = Start-Process `
        -FilePath $installerPath `
        -ArgumentList @("/winpcap_mode=enforced", "/admin_only=disabled") `
        -Wait `
        -PassThru

    if ($process.ExitCode -eq 3010) {
        Write-Warning "Npcap 已安装，但 Windows 要求重启。请重启后再次运行 .\setup.bat。"
        exit 3010
    }

    $state = Get-NpcapState
    if (-not $state.Installed) {
        throw "未检测到 Npcap 服务。可能取消了安装，请再次运行 .\setup.bat。"
    }
    if (-not $state.WinPcapCompatible) {
        throw "Npcap 已安装，但未检测到 WinPcap 兼容模式。请重新运行安装程序。"
    }

    Write-Host "Npcap 安装和兼容模式检查通过。" -ForegroundColor Green
}

function Test-PythonExecutable {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        & $Path -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 12) and sys.maxsize > 2**32 else 1)" 2>$null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Get-PythonExecutable {
    $pyLauncher = Get-Command "py.exe" -ErrorAction SilentlyContinue
    if ($null -ne $pyLauncher) {
        foreach ($pyVersion in @("-3.12", "-3")) {
            try {
                $candidate = (& $pyLauncher.Source $pyVersion -c "import sys; print(sys.executable)" 2>$null | Select-Object -Last 1).ToString().Trim()
                if (Test-PythonExecutable -Path $candidate) {
                    return (Resolve-Path -LiteralPath $candidate).Path
                }
            }
            catch {
                # Continue to other Python discovery methods.
            }
        }
    }

    $pythonCommand = Get-Command "python.exe" -ErrorAction SilentlyContinue
    if ($null -ne $pythonCommand -and $pythonCommand.Source -notmatch "WindowsApps") {
        if (Test-PythonExecutable -Path $pythonCommand.Source) {
            return $pythonCommand.Source
        }
    }

    $knownRoots = @(
        (Join-Path $env:LocalAppData "Programs\Python"),
        $env:ProgramFiles
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }

    foreach ($root in $knownRoots) {
        $pythonDirectories = Get-ChildItem `
            -Path $root `
            -Directory `
            -Filter "Python*" `
            -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending
        foreach ($directory in $pythonDirectories) {
            $candidate = Get-ChildItem `
                -Path $directory.FullName `
                -Filter "python.exe" `
                -Recurse `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $candidate -and (Test-PythonExecutable -Path $candidate.FullName)) {
                return $candidate.FullName
            }
        }
    }

    return $null
}

function Install-PythonIfNeeded {
    $python = Get-PythonExecutable
    if ($null -ne $python) {
        return $python
    }

    Write-Step "安装 Python 3.12 x64"
    $winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw "未找到 Python 或 winget。请从 https://www.python.org/downloads/windows/ 安装 Python 后重试。"
    }

    & $winget.Source install `
        --id "Python.Python.3.12" `
        --exact `
        --source "winget" `
        --scope "user" `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "winget 安装 Python 失败，退出代码：$LASTEXITCODE"
    }

    $python = Get-PythonExecutable
    if ($null -eq $python) {
        throw "Python 安装结束，但当前进程仍无法定位 python.exe。请关闭 PowerShell 后再次运行 .\setup.bat。"
    }
    return $python
}

function Select-BotaNetworkAdapter {
    if (-not [string]::IsNullOrWhiteSpace($NetworkInterfaceGuid)) {
        $normalizedGuid = $NetworkInterfaceGuid.Trim().Trim("{", "}")
        try {
            $requestedGuid = [Guid]$normalizedGuid
        }
        catch {
            throw "NetworkInterfaceGuid 不是有效的 GUID：$NetworkInterfaceGuid"
        }

        $adapter = Get-NetAdapter -IncludeHidden | Where-Object {
            [Guid]$_.InterfaceGuid -eq $requestedGuid
        } | Select-Object -First 1
        if ($null -eq $adapter) {
            throw "未找到 InterfaceGuid 为 {$normalizedGuid} 的网卡。"
        }
        return $adapter
    }

    $physicalAdapters = @(Get-NetAdapter -Physical)
    $adapters = @($physicalAdapters | Where-Object {
        $_.MediaType -eq "802.3" -or $_.PhysicalMediaType -eq "802.3"
    } | Sort-Object Name)

    if ($adapters.Count -eq 0) {
        # Some USB NIC drivers do not report MediaType consistently.
        $adapters = @($physicalAdapters | Where-Object {
            $_.InterfaceDescription -notmatch "(?i)wi-?fi|wireless|802\.11|bluetooth"
        } | Sort-Object Name)
    }

    if ($adapters.Count -eq 0) {
        throw "未找到物理有线网卡。请连接 USB 网卡或拓展坞后再次运行 .\setup.bat。"
    }
    if ($adapters.Count -eq 1) {
        return $adapters[0]
    }

    Write-Host "检测到多块有线网卡，请选择连接 BOTA 传感器的网卡：" -ForegroundColor Yellow
    for ($index = 0; $index -lt $adapters.Count; $index++) {
        $adapter = $adapters[$index]
        Write-Host ("  [{0}] {1} | {2} | {3} | {4}" -f `
            ($index + 1), $adapter.Name, $adapter.InterfaceDescription, `
            $adapter.Status, $adapter.LinkSpeed)
    }

    while ($true) {
        $selectionText = Read-Host "输入序号"
        $selection = 0
        if ([int]::TryParse($selectionText, [ref]$selection) -and `
            $selection -ge 1 -and $selection -le $adapters.Count) {
            return $adapters[$selection - 1]
        }
        Write-Warning "请输入 1 到 $($adapters.Count) 之间的序号。"
    }
}

function Update-BotaConfig {
    param([object]$Adapter)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "找不到 BOTA 配置文件：$ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $config.driver_config.communication_interface_params) {
        throw "配置文件缺少 driver_config.communication_interface_params。"
    }

    $guid = ([Guid]$Adapter.InterfaceGuid).ToString().ToUpperInvariant()
    $npfPath = "\Device\NPF_{$guid}"
    $config.driver_config.communication_interface_params.network_interface = $npfPath

    $json = $config | ConvertTo-Json -Depth 20
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        (Resolve-Path -LiteralPath $ConfigPath).Path,
        $json + [Environment]::NewLine,
        $utf8WithoutBom
    )

    Write-Host "已自动写入网卡配置：$npfPath" -ForegroundColor Green
    Write-Host "网卡：$($Adapter.Name) / $($Adapter.InterfaceDescription)"
    if ($Adapter.Status -ne "Up") {
        Write-Warning "该网卡当前状态为 $($Adapter.Status)。运行传感器前请确认供电和网线链路已连接。"
    }
}

function Install-PythonDependencies {
    param([string]$PythonExecutable)

    Write-Step "创建 Python 环境并安装依赖"
    if ((Test-Path -LiteralPath $VenvPython) -and -not (Test-PythonExecutable -Path $VenvPython)) {
        Write-Warning "现有 .venv 不是 64 位 Python 3.12+，将重建自动生成的虚拟环境。"
        $resolvedVenv = [System.IO.Path]::GetFullPath($VenvPath).TrimEnd("\")
        $expectedVenv = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot ".venv")).TrimEnd("\")
        if ($resolvedVenv -ne $expectedVenv) {
            throw "拒绝删除非项目目录下的虚拟环境：$resolvedVenv"
        }
        Remove-Item -LiteralPath $resolvedVenv -Recurse -Force
    }

    if (-not (Test-Path -LiteralPath $VenvPython)) {
        & $PythonExecutable -m venv $VenvPath
        if ($LASTEXITCODE -ne 0) {
            throw "创建 Python 虚拟环境失败，退出代码：$LASTEXITCODE"
        }
    }

    Write-Host "虚拟环境 Python：$(& $VenvPython -c 'import sys; print(sys.executable)' | Select-Object -Last 1)"
    $pipArguments = @(
        "-m", "pip", "install", "--disable-pip-version-check",
        "-r", $RequirementsPath
    )
    & $VenvPython @pipArguments
    $pipExitCode = $LASTEXITCODE
    if ($pipExitCode -ne 0) {
        Write-Warning "当前 pip 软件源没有返回可用的 bota-driver，正在重试官方 PyPI。"
        $officialPipArguments = $pipArguments[0..3] + `
            @("--index-url", "https://pypi.org/simple") + `
            $pipArguments[4..($pipArguments.Count - 1)]
        & $VenvPython @officialPipArguments
        $pipExitCode = $LASTEXITCODE
    }
    if ($pipExitCode -ne 0) {
        throw "安装 Python 依赖失败。请确认使用 64 位 Python 3.12+，并能访问 https://pypi.org。退出代码：$pipExitCode"
    }

    & $VenvPython -c "import bota_driver, serial; print('Python dependencies: OK')"
    if ($LASTEXITCODE -ne 0) {
        throw "Python 依赖导入检查失败。"
    }
}

try {
    Write-Host "BOTA BFT-ROKS-ECAT-M8 Windows 一键配置" -ForegroundColor White
    Write-Host "项目目录：$ProjectRoot"

    if ($SkipNpcap) {
        Write-Warning "已跳过 Npcap 安装和检查。"
    }
    else {
        Install-NpcapIfNeeded
    }

    $adapter = Select-BotaNetworkAdapter
    Write-Step "配置 BOTA 使用的 NPF 网卡"
    Update-BotaConfig -Adapter $adapter

    if ($SkipPython) {
        Write-Warning "已跳过 Python 环境安装。"
    }
    else {
        $python = Install-PythonIfNeeded
        Write-Host "使用 Python：$python"
        Install-PythonDependencies -PythonExecutable $python
    }

    Write-Step "配置完成"
    Write-Host "读取传感器：" -ForegroundColor Green
    Write-Host "  .\.venv\Scripts\python.exe .\read_bota.py"
    Write-Host "读取并输出 Fz 到串口（示例 COM7）："
    Write-Host "  .\.venv\Scripts\python.exe .\read_bota.py --serial-port COM7 --serial-baud 115200"
    exit 0
}
catch {
    Write-Host "`n配置失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
