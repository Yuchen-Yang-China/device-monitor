# Device Monitor for Windows

轻量的 Windows 11 系统托盘监控工具，并严格实现 Peer Status Protocol v1。应用默认仅在托盘运行，不显示控制台窗口；peer 功能默认关闭。

## 环境与构建

- Windows 11 x64
- .NET SDK 10.0.400（.NET 10 LTS）

```powershell
.\build.ps1
```

构建、测试并发布自包含版本：

```powershell
.\build.ps1 -Publish
```

发布后的入口是 `artifacts\win-x64\Device Monitor.exe`，安装程序是 `artifacts\installer\Device Monitor Setup.exe`，MSI 是 `artifacts\installer\Device Monitor.msi`。开发运行可用：

```powershell
dotnet run --project src/DeviceMonitor.App/DeviceMonitor.App.csproj
```

## 功能

- 三段压力条托盘图标与 CPU、内存、网络 tooltip
- CPU、内存、温度和网络详情；本机与远端内存 5 分钟趋势
- 简体中文与英文，可在 Settings/设置中即时切换并持久化
- Balanced、Low power、Responsive 三档采样
- CPU/内存详情可见时才采集 Top 3 进程
- 使用 LibreHardwareMonitor 读取真实 CPU、GPU 和主 SSD/存储温度；Intel CPU 温度需要安装 PawnIO 驱动并以管理员身份运行
- 若硬件或权限仍不提供 CPU/存储传感器，协议保持 Unavailable/null，绝不估算；Windows load average 始终为 null
- 对称的签名状态服务与 peer 轮询客户端；默认端口固定为 48621/TCP

## Peer 配置

1. 打开托盘窗口的 Settings，勾选 **Enable peer monitoring**。
2. 选择一个当前有效的私网 IPv4/Tailscale IPv4；应用不会绑定 `0.0.0.0` 或公网地址。
3. 填写对端 `host` 或 `host:port`，未写端口时固定使用 `48621`。
4. 两端粘贴相同的 32 字节 Base64URL pairing secret，然后 Save/Test connection。
5. pairing secret 仅以当前用户 DPAPI 密文保存在 `%LOCALAPPDATA%\DeviceMonitor\pairing-secret.dat`；普通设置文件不含 secret。

应用不会自动创建防火墙规则。如果需要局域网入站访问，请以管理员身份创建仅适用于 Private profile 的 TCP 48621 入站规则，并把程序路径限制到发布后的 `Device Monitor.exe`。不要把 48621 直接映射到公网；异地互联应使用 Tailscale/WireGuard。

## 最短 Mac 联调步骤

1. 两端先运行各自合同与 HMAC 固定向量测试。
2. 两端使用同一 secret，互填对方的私网/Tailscale 地址。
3. Mac 先请求 Windows 的 `/v1/status`，确认有效签名与 fixture 解码；再反向测试。
4. 连续观察 10 分钟并覆盖退出、重启、断网恢复与睡眠唤醒。

协议实现与 UI/Windows 采样域模型分离。认证窗口固定为 120 秒，nonce 保留 5 分钟，响应体上限固定为 64 KiB；轮询为 5 秒，失败退避为 5/10/20/30 秒，15 秒无有效响应显示 Offline。

Windows 按 Peer Status Protocol v1 使用 `metrics.thermal.gpuCelsius` 和 `metrics.thermal.storageCelsius` 发送 GPU/主存储温度，并始终显式发送不可用核心指标的 JSON `null`。接收端允许 Mac 省略 `gpuCelsius` 或发送 `null`；Windows 不发送早期兼容名 `ssdCelsius`/`ssdTemperature`。

温度读取使用 MPL-2.0 许可的 `LibreHardwareMonitorLib` 0.9.6，项目与许可证见 <https://github.com/LibreHardwareMonitor/LibreHardwareMonitor>。

应用、测试和安装器都位于本目录；图标不重复存放，构建时直接使用仓库根目录的 `shared/assets/windows/DeviceMonitor.ico` 和 `DeviceMonitor-1024.png`。不要在 `apps/windows` 中执行 `git init`，也不要提交 `artifacts`、`bin`、`obj`、`.vs`、`TestResults`、EXE、MSI 或本机配置。
