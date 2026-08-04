# BOTA BFT-ROKS-ECAT-M8 Python 读取

本目录中的配置已针对以下设备填写：

- 型号：`BFT-ROKS-ECAT-M8`（Gen 0 EtherCAT）
- 序列号：`SN000729`
- Windows 网卡：`Realtek USB GbE Family Controller`
- NPF 标识：`\Device\NPF_{648CD556-4DF0-4024-A8C5-CAE7CE99487C}`

## 连接要求

EtherCAT 不是普通 TCP/IP。请严格按官方快速指南连接：

1. 将传感器线的 M8 插头接到传感器并拧紧。
2. 将该传感器线的 RJ45 端接到供电板的 `POE` 口。
3. 用第二根网线连接供电板的 `LAN` 口和电脑的 Realtek 有线网卡。
4. 将 AC/DC 电源接到供电板的 `DC` 口并上电。

Windows 的 `ipconfig /all` 随后应显示该网卡已连接；EtherCAT 不需要从 DHCP 获得 IP 地址。传感器绿色 LED 表示 EtherCAT 状态，红色 LED 表示 EtherCAT 错误。

Npcap 必须安装，并启用 `WinPcap API-compatible Mode`。不要让 TwinCAT、其他 EtherCAT 主站或抓包程序同时占用这块网卡。

## 更换电脑或网卡

`bota_config.json` 中的 NPF 网卡标识是 Windows 为当前电脑上的网卡分配的，因此换电脑、换 USB 网卡或换拓展坞后通常需要更新。使用同一台传感器时，主要修改以下字段：

```json
"network_interface": "\\Device\\NPF_{648CD556-4DF0-4024-A8C5-CAE7CE99487C}"
```

在新电脑上按以下步骤配置：

1. 安装 Python。
2. 安装 Npcap，并在安装界面勾选 `Install Npcap in WinPcap API-compatible Mode`。
3. 按照前述连接要求给传感器和 POE 板上电，并连接新电脑的有线网卡。
4. 以管理员身份打开 PowerShell，运行以下命令：

```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription, InterfaceGuid, Status, LinkSpeed
```

5. 在输出中找到连接传感器的有线网卡，记录其 `InterfaceGuid`。如果无法确定，可以拔插传感器网线，观察哪一项的 `Status` 发生变化。
6. 打开 `bota_config.json`，使用新 GUID 替换 `network_interface`。例如 PowerShell 显示：

```text
InterfaceGuid : {12345678-ABCD-1234-ABCD-1234567890AB}
```

对应的 JSON 配置应写为：

```json
"network_interface": "\\Device\\NPF_{12345678-ABCD-1234-ABCD-1234567890AB}"
```

JSON 中的反斜杠必须写成 `\\`。不要填写网卡名称、MAC 地址或 IP 地址。

7. 在项目目录中重新创建 Python 虚拟环境并安装依赖：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

8. 确认 Windows 中的有线网卡不再显示 `Network cable unplugged`。链路仍无法建立时，可在网卡的高级属性中将 `连接速度和双工模式` 临时设置为 `100 Mbps 全双工`。
9. 启动读取程序：

```powershell
.\.venv\Scripts\python.exe .\read_bota.py
```

配置字段的修改规则如下：

| 使用情况 | 需要修改的字段 |
| --- | --- |
| 同一传感器，换电脑或网卡 | `network_interface` |
| 更换另一台 BOTA 传感器 | `product_name`、`serial_number`，并确认通信接口类型 |
| 仍使用 `SN000729` | 保持 `product_name`、`serial_number`、`communication_interface_name` 和 `sinc_length` 不变 |

本项目当前传感器使用 `CANopen_over_EtherCAT_gen0`，`sinc_length` 为 `51`。除非更换传感器型号、通信协议或需要调整传感器滤波/输出频率，否则不要修改这两个值。

## 安装与运行

在 PowerShell 中进入本目录，然后运行：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe .\read_bota.py
```

每次程序成功连接传感器后，都会在开始采集前自动执行 tare，将当时的六维力/力矩设为零。启动程序时，请勿触碰传感器，并让它保持在希望作为零点的安装姿态和载荷状态。

Gen 0 EtherCAT 接口不支持硬件 tare，BOTA 驱动会改用软件零偏。因此每次重新运行程序都会重新清零，零偏不会写入传感器固件。

按 `Ctrl+C` 停止。只有在需要保留原始偏置时才跳过自动清零：

```powershell
.\.venv\Scripts\python.exe .\read_bota.py --no-tare
```

运行 30 秒并保存 CSV：

```powershell
.\.venv\Scripts\python.exe .\read_bota.py --duration 30 --rate 100 --csv .\readings.csv
```

输出中的 `Fx/Fy/Fz` 单位是 N，`Tx/Ty/Tz` 单位是 Nm。`invalid=1` 或 `over=1` 时不要把该帧用于测量或控制。
