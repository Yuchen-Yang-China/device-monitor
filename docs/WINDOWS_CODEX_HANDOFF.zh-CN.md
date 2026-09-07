# 给 Windows 端 Codex 的开工说明

在 Windows 上克隆同一 GitHub 仓库，将 Windows 工程放进 `apps/windows/`。开始前阅读本文件与同目录下这四个文件：

- `PRODUCT_SPEC.zh-CN.md`
- `PEER_SYNC_PROTOCOL_V1.zh-CN.md`
- `status-v1.schema.json`
- `examples/status-v1.json`

然后把下面这段作为任务发给 Windows 端 Codex：

```text
请在 apps/windows/ 中开发 Device Monitor 的 Windows 版本。这是一款个人使用的 Windows 系统托盘监控工具，不是 macOS UI 的像素复制。不要在 apps/windows 内再次执行 git init；它必须与 apps/macos 共用仓库根目录的 Git 历史。

开始前完整阅读并遵守随项目提供的：
1. docs/PRODUCT_SPEC.zh-CN.md
2. docs/PEER_SYNC_PROTOCOL_V1.zh-CN.md
3. docs/status-v1.schema.json
4. docs/examples/status-v1.json

应用图标使用 shared/assets/windows/DeviceMonitor.ico，高清源图使用 shared/assets/windows/DeviceMonitor-1024.png。

技术建议：C# + 当前受支持的 .NET LTS + WPF。优先使用 Windows 自带 API；依赖应少、成熟、可审计。应用以托盘常驻方式运行，不出现控制台窗口。视觉遵循 Windows 11，信息架构、指标语义、状态词和采样档位必须与产品规范一致。

请分阶段完成：

A. 本机监控
- 系统托盘三段压力条和 tooltip；点击打开总览。
- CPU、内存、温度、网络四项详情，5 分钟内存趋势。
- Balanced / Low power / Responsive 三档采样。
- Top 3 进程只在 CPU/内存详情打开时采集。
- 温度或 load average 没有可靠来源时必须显示 Unavailable/隐藏，不允许估算或用不同概念冒充。

B. Peer Status Protocol v1
- 协议 DTO 必须独立于 UI/Windows 采样内部模型。
- 实现 GET /v1/status 只读服务端和每 5 秒轮询 peer 的客户端。
- 严格实现 HMAC-SHA256 canonical form、120 秒时间窗、nonce 防重放、64 KiB body 上限和固定测试向量。
- pairing secret 使用系统安全存储；日志不得包含 secret、签名或完整 body。
- 默认端口 48621；只允许用户选择的私网接口。不要自动开放公网端口或实现 UPnP。
- 使用 fixture 做解码测试；未知字段必须忽略，错误版本/缺失必填字段必须拒绝。

C. 远端设备 UI
- 显示 peer 的 Online/Degraded/Offline、最后接收时间和四项摘要。
- 远端趋势只保留内存 5 分钟；相同 sequence 不重复入图。
- 15 秒无有效响应为 Offline；按 5/10/20/30 秒退避，恢复后回到 5 秒。
- 第一版不得发送或显示远端进程名、SSID、用户名、IP、文件路径，也不实现远程命令。

工程要求：
- 为采样器、协议 DTO、签名、重放保护、轮询状态机和趋势裁剪写单元测试。
- 提供一条可重复的 build/test 命令和简明 README。
- Windows 防火墙规则只允许 Private profile；若安装流程无法安全创建规则，在 UI 中给出明确操作说明。
- 先实现协议合同和测试，再接 UI。不得自行修改 v1 字段名、单位、枚举、端口或签名格式；若发现合同矛盾，停下并列出问题供两端共同决定。

完成后请输出：构建产物路径、测试结果、本机监听地址，以及和 macOS 端联调所需的最短步骤。
```

## 两端联调顺序

1. 分别运行单元测试，确认固定 HMAC test vector 通过。
2. Windows 服务端启动后，在 Mac 上先用协议客户端请求 Windows 的 `/v1/status`；再反向测试。
3. 让两端都指向对方的私网/Tailscale 地址并使用相同 secret。
4. 连续观察 10 分钟，覆盖正常采样、应用退出、重新启动、断网恢复和系统睡眠唤醒。
5. 若 JSON 互通失败，先保存去除签名和设备隐私后的原始 body，比对协议 DTO；不要直接在 UI 层做兼容补丁。
