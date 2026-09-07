# Device Monitor 产品与跨平台设计规范

> 状态：可作为 macOS 与 Windows 两端并行开发的共同基线
> 当前 macOS 版本：0.1.0
> 协议基线：Peer Status Protocol v1

## 1. 产品定位

Device Monitor 是一款面向个人设备的轻量、常驻、原生系统监控工具。它不试图替代完整的活动监视器或任务管理器，而是让用户用一次点击完成三件事：

1. 在系统菜单栏/托盘快速判断设备是否健康；
2. 查看最近 5 分钟的变化趋势并定位主要资源消耗；
3. 在另一台已配对设备上看到本机的实时摘要与在线状态。

核心原则：低打扰、低开销、数据诚实、默认私密、跨平台语义一致。

## 2. 当前 macOS 产品盘点

### 2.1 入口与信息层级

- 应用以 accessory 模式运行，不显示 Dock 图标，常驻菜单栏。
- 左键打开瞬态浮层；右键显示 Settings / Quit 菜单。
- 菜单栏状态由三根分段压力条和可选的上传、下载速率组成。
- 展示模式：Full、Compact、Minimal；可单独关闭网络速率。
- 总览浮层为 360 × 300 pt；详情浮层为 360 × 400 pt。
- 总览展示 CPU、内存、温度、网络四个入口；点击进入单项详情。

### 2.2 指标能力

| 指标 | 总览 | 详情 | 状态阈值/语义 |
|---|---|---|---|
| CPU | 总使用率 | 5 分钟趋势、平均/峰值、User/System/Idle、5/15 分钟负载、核心拓扑、Top 3 进程 | `<65%` Normal，`65–<90%` Attention，`>=90%` Critical |
| 内存 | 已用/总量 | 5 分钟趋势、平均/峰值、Wired/Compressed/Cached/Swap、Top 3 进程 | 内存占用 `<75%` Normal，`75–<90%` Attention，`>=90%` Critical；同时合并 macOS memory pressure，取更严重者 |
| 温度 | SoC/CPU 平均温度 | 5 分钟最小/平均/最大、系统 thermal pressure、最热传感器、SSD 温度 | SoC 平均 `75/90°C`、最热点 `85/100°C`、SSD `70/85°C` 分别进入 Attention/Critical；与 OS thermal state 取更严重者 |
| 网络 | 主物理接口上下行速率 | 双向 5 分钟趋势、平均/峰值/5 分钟流量/本次运行累计、Wi-Fi RSSI/信道 | 速率不评健康等级；采样失败必须显示 Out of date，不得把旧值伪装成实时值 |

温度传感器在 Apple Silicon 上通过 IOKit/HID bridge 读取。Intel 或无对应传感器时允许显示 Unavailable；OS thermal state 仍可独立工作。

### 2.3 采样与存储

| 配置 | 网络 | CPU/内存 | 温度 | 进程/Wi-Fi 详情 |
|---|---:|---:|---:|---:|
| Balanced（默认） | 1 s | 5 s | 15 s | 30 s |
| Low power | 2 s | 10 s | 30 s | 60 s |
| Responsive | 1 s | 2 s | 10 s | 15 s |

- 趋势只在内存中保留最近 5 分钟，不落盘。
- Top 进程仅在 CPU/内存详情打开时采集；Wi-Fi 元数据仅在网络详情打开时采集。
- 首次 CPU/进程/网络速率读取只是建立差分基线，显示 Collecting，不生成虚假零值。
- 采样失败保留最后成功值，但状态改为 Stale/Out of date；过期样本不写入趋势图。
- 设置持久化；历史曲线、进程列表和会话网络累计不持久化。

### 2.4 隐私与权限

- 当前版本没有网络依赖、账号体系、特权 helper 或云上传。
- 不读取 Wi-Fi SSID，避免为非必要信息申请定位权限。
- 无法取得的数据保持为空，不推测、不插值成“真实值”。
- 进程名称属于较敏感数据，只在本机详情中按需展示。

### 2.5 当前实现结构

- Swift 6 / SwiftPM，最低 macOS 14；AppKit 管生命周期、菜单栏与 popover，SwiftUI 管界面。
- `SystemMonitor` 在单独串行 utility queue 上维护全部可变采样状态，UI 更新切回 MainActor。
- `MonitorStore` 保存最新快照和裁剪后的 5 分钟趋势；`AppSettings` 用 UserDefaults 保存展示/采样偏好。
- `ProcessSampler` 独立负责进程两点差分；`SensorBridge` 用 C + IOKit 读取 Apple Silicon HID 温度。
- `MenuBarController` 只按影响渲染的签名变化重画菜单栏图像，并持续更新 tooltip/辅助功能文本。
- 代码层应继续维持 `sampler -> domain snapshot -> store -> UI` 的单向流动；peer 功能作为 snapshot 的消费者/提供者接入，不让网络请求直接触发 UI 或硬件采样。

## 3. 设计语言

### 3.1 视觉与交互

- **原生而克制**：使用系统字体、系统图标、系统色和毛玻璃/材质背景；不引入品牌色主导界面。
- **渐进披露**：托盘看状态，总览看四类指标，详情看趋势和拆分。
- **数值稳定**：动态数字使用等宽数字；单位随量级变化但字段含义不变。
- **语义色有限**：绿色表示正常、橙/黄表示注意、红色表示严重；采集中、不可用、过期统一使用次要灰色。
- **状态不只依赖颜色**：颜色旁始终有 Normal、Attention、Critical、Collecting、Unavailable 或 Out of date 文本。
- **轻交互**：行级点击区域；hover 约 6% 主色透明度、pressed 约 12%、圆角 7 pt；详情左右切换约 0.2 秒。
- **尊重辅助设置**：支持键盘、VoiceOver/屏幕阅读器、tooltip，并在 Reduce Motion 开启时移除位移动画。

### 3.2 Windows 适配而非像素复制

Windows 端保留相同的信息架构、状态词、指标定义和采样配置，视觉上遵循 Windows 11。建议使用 C#、当前受支持的 .NET LTS 与 WPF；托盘图标可使用成熟的 NotifyIcon 封装。

Windows 托盘图标实际可用像素远小于 macOS 菜单栏宽度，因此：

- 托盘图标只画三根压力条，不把实时网速硬塞进小图标；
- 网速显示在 tooltip 和弹出面板顶部；
- 弹出面板保持约 360 × 300/400 的逻辑尺寸，并正确响应 DPI；
- 可使用 Mica/Acrylic，但必须能在不支持材质效果时优雅降级为系统背景。

### 3.3 Windows 指标映射

| 共同语义 | Windows 建议数据源 | 差异处理 |
|---|---|---|
| CPU 总量与拆分 | `GetSystemTimes`/PDH | 与 macOS 同阈值；按差分计算，首样本 Collecting |
| 核心拓扑 | `GetLogicalProcessorInformationEx` | 能识别时显示 P/E core，否则只显示 logical processors |
| load average | 无直接等价系统概念 | 协议中发 `null`，UI 隐藏此区，不用 processor queue 冒充 |
| 内存 | `GlobalMemoryStatusEx`，必要时补充性能计数器 | 先按使用率采用共同阈值；Windows 没有完全等价的 macOS memory pressure |
| Swap/Page file | 性能计数器或系统 API | 字段不可可靠取得时为 `null` |
| 温度 | 可选硬件 API/传感器库 | 第一版允许整体 Unavailable，绝不编造；OS/硬件可用后再按能力上报 |
| 网络 | `GetIfTable2` + 默认路由/适配器筛选 | 排除 loopback；接口切换时重建基线，避免速率尖峰 |
| Wi-Fi | Native Wi-Fi API | RSSI/信道按能力展示；SSID 默认不采集、不远程发送 |
| Top 进程 | `Process.GetProcesses()` 两次采样 | Top 3；只在本机详情按需采集 |

## 4. 双机状态功能

### 4.1 第一版目标

当 Mac 与 Windows 应用同时在线且已经配对时，任意一端都能在“Devices”区域看到另一端：

- 设备名、平台、应用版本；
- Online / Degraded / Offline；
- CPU、内存、温度（可能不可用）、上下行速率；
- 最后接收时间；
- 点击后查看远端最近 5 分钟趋势。

第一版是**只读监控**，不支持杀进程、关机、执行命令、文件传输或远程控制。远端默认不传进程名称、Wi-Fi SSID、IP 地址、用户名和历史记录。

### 4.2 推荐架构

两端采用完全对称的结构：

```text
OS sampler -> Local snapshot store -> Local UI
                         |
                         +-> read-only status endpoint

Configured peer -> poll every 5 s -> Remote snapshot store -> Devices UI
```

- 每台设备都运行同一个只读状态服务，也运行同一个 peer poller。
- 网络层与采样层解耦，严格依赖 `Peer Status Protocol v1`，不要直接序列化 Swift/C# 内部模型。
- 第一版每 5 秒拉取一次，15 秒没有成功响应显示 Offline。与 WebSocket 相比，轮询更容易跨 Swift/.NET 实现、调试和恢复，对两台个人设备的负载可以忽略。
- 远端趋势由接收端用收到的最新样本构建，只保留内存中的 5 分钟。
- 只在数据序号变化时追加趋势，避免重复轮询产生重复点。

详细接口、字段、认证与兼容规则见 [PEER_SYNC_PROTOCOL_V1.zh-CN.md](PEER_SYNC_PROTOCOL_V1.zh-CN.md)。

### 4.3 局域网与互联网

| 场景 | 是否自建云服务器 | 推荐方式 | 难度 |
|---|---|---|---|
| 同一可信局域网 | 不需要 | 手动填写局域网 IP/主机名；之后可增加 mDNS 自动发现 | 低 |
| 异地、两端安装 Tailscale/WireGuard 类组网 | 不需要自建 | 填写对方稳定的组网 IP/MagicDNS 名称；流量端到端加密 | 低到中 |
| 直接穿越任意家庭/公司 NAT | 通常需要 | rendezvous + NAT traversal，失败时还要 TURN/relay | 中到高 |
| 自有公网产品化服务 | 需要 | HTTPS API/长连接中继、账号/设备注册、密钥轮换、限流、监控和运维 | 高 |

结论：互联网能力不必等于“租一台自己的云服务器”。个人双机第一版推荐使用加密组网，应用只负责状态协议；这样局域网和异地使用同一套代码。若未来希望用户不安装任何组网工具，再在 `PeerTransport` 后增加云 relay，不改指标模型和 UI。

### 4.4 网络设置页面

新增 “Devices” 设置区：

- Enable peer monitoring（默认关闭）；
- This device：设备名、device ID、监听端口、当前可达地址；
- Peer address：`host:port`，允许局域网 IP 或组网域名；
- Pairing secret：生成 32 字节随机 secret，可复制/粘贴；界面默认遮挡；
- Test connection；
- Forget peer；
- 明确提示：普通局域网模式只适用于可信网络；异地访问需通过加密 VPN/组网，禁止把端口直接映射到公网。

默认端口为 `48621/TCP`。服务只允许 GET 状态接口；不提供任意查询参数、文件路径或命令接口。

## 5. 数据与状态规则

### 5.1 共同状态枚举

| 协议值 | UI 文案 | 含义 |
|---|---|---|
| `normal` | Normal | 成功采样且未越阈值 |
| `elevated` | Attention | 需要注意 |
| `critical` | Critical | 严重 |
| `collecting` | Collecting | 尚未取得计算所需基线 |
| `unavailable` | Unavailable | 平台或权限不支持 |
| `stale` | Out of date | 当前采样失败，可能保留最后成功值 |

数值与状态是两个独立字段。`stale` 时允许带最后成功数值；`unavailable` 时对应数值应为 `null`。接收端不得根据数字重新解释发送端的 `collecting/unavailable/stale`。

### 5.2 设备在线状态

- `Online`：最近 15 秒内请求成功且快照格式有效。
- `Degraded`：连接成功，但至少一个主要指标为 stale/critical，或发送端采样时间明显落后。
- `Offline`：连续 15 秒没有成功响应；继续展示最后值时必须标注 “Last seen …”。
- 网络失败使用指数退避：5、10、20、30 秒，上限 30 秒；一旦成功恢复 5 秒节奏。
- 睡眠唤醒、网络切换和地址变化后立即尝试一次，不等退避计时结束。

## 6. 范围划分

### MVP 必须完成

- Windows 本机托盘、总览、四项详情、三档采样、5 分钟内存趋势；
- Windows 可用指标与 macOS 语义一致，不可用能力诚实降级；
- macOS 与 Windows 均实现协议 v1 的服务端和轮询客户端；
- 中英文界面切换；Mac 可以接收并展示 Windows 的独立 GPU/SSD 温度，Mac 无可靠独立 GPU 传感器时上报 `null`；
- 单一 peer 配置、共享 secret、请求签名、防重放、离线/恢复状态；
- 远端摘要与详情，不发送 Top 进程和 Wi-Fi SSID；
- 合同 fixture、签名 test vector、跨平台互通测试。

### MVP 明确不做

- 自建云服务器、账号登录、推送通知；
- 多设备群组、历史落盘、跨设备设置同步；
- 远程控制或远程执行；
- 自动端口映射、直接公网暴露；
- 为追求平台一致而伪造 Windows 温度/load average。

### 后续候选

- mDNS 局域网发现和图形化六位码配对；
- 系统启动时运行；
- 阈值自定义与本地通知；
- 多 peer、端到端加密云 relay；
- 用户明确开启后，按白名单共享进程摘要。

## 7. 验收标准

1. Mac/Windows 在同一可信网络或同一加密组网内，配置地址和 secret 后 30 秒内互相显示 Online。
2. 任一端退出后，另一端在最后一次成功响应后 15 秒内显示 Offline；恢复后无需重新配对。
3. 断网、换网卡、睡眠唤醒不会制造 CPU/网络尖峰，也不会把旧值显示为实时值。
4. Windows 不支持温度时，Mac 端远程卡片显示 Unavailable，其余指标正常。
5. 错误 secret、过期时间戳、重复 nonce、被修改的响应体全部被拒绝。
6. 未知 JSON 字段被忽略；缺少 v1 必填字段的响应被拒绝；`apiVersion != 1` 显示 Incompatible。
7. 默认任何远端报文都不含进程名、SSID、用户名、IP、文件路径。
8. 两端持续运行 8 小时，采样与远程趋势内存不随时间无限增长。
9. Reduce Motion、键盘访问、屏幕阅读器文本和高 DPI 下均可用。

## 8. 并行开发边界

为避免两端完成后无法互通，macOS 与 Windows 开工前共同冻结以下内容：

- `docs/PEER_SYNC_PROTOCOL_V1.zh-CN.md` 中的 endpoint、JSON 字段、单位、枚举、签名算法；
- `docs/examples/status-v1.json` 作为兼容 fixture；
- 端口 `48621`、轮询 5 秒、离线 15 秒；
- 所有时间使用 UTC RFC 3339 毫秒格式，所有流量值使用 bytes 或 bytes/second，百分比使用 `0...100`；
- 可选值使用 JSON `null`，不发送 `"--"`、`"N/A"` 或带单位的字符串。

两端内部技术栈可以不同，但协议模型必须单独定义，并通过 fixture 解码测试。任何破坏性协议修改都新开 `apiVersion`，不得悄悄改变 v1 字段含义。
