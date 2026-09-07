# Device Monitor

Device Monitor 是一个个人使用的跨平台系统监控项目。macOS 与 Windows 应用各自遵循原生平台设计，同时通过同一份 Peer Status Protocol v1 在可信局域网或加密组网中交换只读状态。

## 仓库结构

```text
apps/
  macos/              macOS 菜单栏应用（Swift / SwiftUI）
  windows/            Windows 托盘应用
docs/                 PRD、跨平台协议、JSON Schema 与联调说明
shared/assets/         两端共用的图标与视觉素材
.github/workflows/    持续集成
```

## macOS

```sh
cd apps/macos
swift test
./Scripts/build-app.sh
```

完整说明见 [apps/macos/README.md](apps/macos/README.md)。

## Windows

Windows 工程统一放在 `apps/windows/`，不要在该目录内再次执行 `git init`。Windows 端开始或继续开发前，应先阅读：

- [产品规格](docs/PRODUCT_SPEC.zh-CN.md)
- [Peer Status Protocol v1](docs/PEER_SYNC_PROTOCOL_V1.zh-CN.md)
- [JSON Schema](docs/status-v1.schema.json)
- [Windows Codex 交接说明](docs/WINDOWS_CODEX_HANDOFF.zh-CN.md)

Windows 图标素材位于 [shared/assets/windows](shared/assets/windows)。

在 Windows PowerShell 中执行完整构建与测试：

```powershell
cd apps/windows
.\build.ps1
```

构建、测试、自包含发布并生成安装包：

```powershell
cd apps/windows
.\build.ps1 -Publish
```

Windows 详细运行、温度传感器和 Peer 配置说明见 [apps/windows/README.md](apps/windows/README.md)。

## 协作规则

- `docs/PEER_SYNC_PROTOCOL_V1.zh-CN.md` 和 `docs/status-v1.schema.json` 是两端互通合同；破坏兼容性的修改必须升级协议版本。
- 不提交 `.build`、`bin`、`obj`、`.app`、安装包、ZIP 或 IDE 本地状态。
- 不提交配对密钥、证书、签名凭据、设备地址或其他本机配置。
- macOS 与 Windows 的功能改动应分别通过各自测试后再推送。

## 网络安全

Peer v1 使用 HMAC 做认证和完整性校验，但不加密状态内容。只应在可信家庭局域网或 Tailscale/WireGuard 等加密隧道中使用，禁止将 `48621/TCP` 直接映射到公网。
