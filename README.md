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

## 安装与运行

在 PowerShell 中进入本目录，然后运行：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe .\read_bota.py
```

按 `Ctrl+C` 停止。将当前无载荷状态清零后读取：

```powershell
.\.venv\Scripts\python.exe .\read_bota.py --tare
```

运行 30 秒并保存 CSV：

```powershell
.\.venv\Scripts\python.exe .\read_bota.py --duration 30 --rate 100 --csv .\readings.csv
```

输出中的 `Fx/Fy/Fz` 单位是 N，`Tx/Ty/Tz` 单位是 Nm。`invalid=1` 或 `over=1` 时不要把该帧用于测量或控制。
