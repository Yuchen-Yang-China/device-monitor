# Peer Status Protocol v1

本文是 Mac Monitor 与 Windows Monitor 的互通合同。关键词“必须 / 不得 / 应当 / 可以”具有规范意义。

## 1. 传输模型

- 每个应用既是只读 HTTP 服务端，也是对另一台设备的轮询客户端。
- 默认监听端口：`48621/TCP`。
- 状态接口：`GET /v1/status`。
- Content-Type：`application/json; charset=utf-8`。
- 客户端每 5 秒请求一次；服务端必须返回当前内存快照，不因请求触发昂贵采样。
- 协议允许可信 LAN 上的 HTTP。跨互联网必须置于 Tailscale/WireGuard 等加密隧道内；v1 服务不得直接映射到公网。
- 首版只允许一对一 peer。服务端应将监听地址限制在用户选择的私网接口，并通过系统防火墙仅允许 Private network。

HTTP 响应：

| 状态码 | 含义 |
|---:|---|
| 200 | 成功，body 为 v1 status |
| 400 | 请求头格式错误 |
| 401 | 签名缺失或错误 |
| 409 | nonce 已使用，疑似重放 |
| 426 | API 版本不兼容 |
| 429 | 请求过于频繁 |

所有响应包含 `Cache-Control: no-store`。错误 body 只返回稳定错误码，例如 `{"error":"invalid_signature"}`，不泄漏 secret、期望签名或内部异常。

## 2. 配对身份

每次安装首次启动时生成并持久化：

- `deviceId`：随机 UUID v4，小写、带连字符；重命名设备不得改变它；
- `deviceName`：用户可编辑的显示名；
- `pairingSecret`：32 个密码学随机字节，使用无 padding 的 Base64URL 显示/粘贴。

两台设备配置同一个 pairing secret。secret 只存入 Keychain（macOS）或 DPAPI/Windows Credential Manager（Windows），不得写入日志、普通配置文件、崩溃报告或 UI 截图可见区域。

## 3. 请求认证与防重放

每次请求必须包含：

```http
X-DM-Device-Id: 64bd9fc8-3cdf-45f7-9dd6-57d628f15e2a
X-DM-Timestamp: 1788681600123
X-DM-Nonce: c29tZS1yYW5kb20tbm9uY2U
X-DM-Signature: 6633...lowercase-hex...
X-DM-Api-Version: 1
```

- timestamp 是 UTC Unix epoch milliseconds 的十进制整数。
- nonce 至少 16 个随机字节，以无 padding Base64URL 编码；每个请求重新生成。
- body hash 为原始 HTTP body bytes 的 SHA-256 小写十六进制；GET 请求 body 为空，因此使用空字节的 SHA-256。
- canonical request 使用 UTF-8，字段之间只有一个 LF (`\n`)，末尾没有 LF：

```text
GET
/v1/status
{timestamp}
{nonce}
{lowercase_hex_sha256_body}
```

- signature 为 `HMAC-SHA256(pairingSecretBytes, canonicalRequestBytes)` 的小写十六进制。
- 服务端必须使用 constant-time comparison 验证签名。
- 服务端只接受与本机时间相差不超过 120 秒的 timestamp，并在内存保存已接受 nonce 5 分钟；重复 nonce 返回 409。
- 设备时间错误应在 UI 中显示 “Clock mismatch”，不可自动放宽验证窗口。

响应必须回显请求 nonce，并签名 body，避免可信 LAN 中的响应被篡改：

```http
X-DM-Timestamp: 1788681600456
X-DM-Nonce: c29tZS1yYW5kb20tbm9uY2U
X-DM-Signature: ab19...lowercase-hex...
X-DM-Api-Version: 1
```

canonical response：

```text
200
/v1/status
{response_timestamp}
{request_nonce}
{lowercase_hex_sha256_raw_response_body}
```

客户端必须先验证 nonce、时间窗口和响应签名，再解析或展示 body。HMAC 提供认证和完整性，不提供内容加密；因此异地使用必须依赖加密隧道。

### 3.1 固定请求签名测试向量

两端必须用以下固定数据得到完全相同的结果；这是实现互通的最低门槛：

```text
pairingSecret bytes (hex): 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
pairingSecret (Base64URL): AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8
timestamp: 1788681600123
nonce bytes (hex): 000102030405060708090a0b0c0d0e0f
nonce (Base64URL): AAECAwQFBgcICQoLDA0ODw
empty body SHA-256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

Canonical request 的 UTF-8 内容为：

```text
GET
/v1/status
1788681600123
AAECAwQFBgcICQoLDA0ODw
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

期望 HMAC-SHA256 小写十六进制：

```text
ba66319222045ec9fde8f1aee9e39a378d77af5c3413c0b6306b05c62b83586f
```

## 4. JSON 合同

权威示例见 [examples/status-v1.json](examples/status-v1.json)，机器可读约束见 [status-v1.schema.json](status-v1.schema.json)。

### 4.1 顶层字段

| 字段 | 类型 | 必填 | 说明 |
|---|---|---:|---|
| `apiVersion` | integer | 是 | 固定为 `1` |
| `sequence` | integer | 是 | 当前应用进程内单调递增；应用重启可从 1 开始 |
| `capturedAt` | string | 是 | 快照生成时的 UTC RFC 3339 时间，必须含毫秒和 `Z` |
| `device` | object | 是 | 发送设备身份和版本 |
| `capabilities` | object | 是 | 平台实际可提供的能力 |
| `metrics` | object | 是 | 当前指标快照 |

发送方可以新增字段；接收方必须忽略未知字段。v1 必填字段不得删除或改变含义。

### 4.2 单位与空值

- percentage：数字 `0...100`；不可用时为 `null`。
- bytes：非负整数；不可用时为 `null`。
- bytes per second：非负数字；不可用时为 `null`。
- temperature：摄氏度数字；不可用时为 `null`。
- 时间：UTC RFC 3339，固定三位毫秒，例如 `2026-09-06T08:00:00.123Z`。
- 不得在数值字段中发送带单位字符串、NaN 或 Infinity。

### 4.3 状态与 freshness

每个主要 metric 必须带 `state`：

```text
normal | elevated | critical | collecting | unavailable | stale
```

- `sampledAt` 表示该 metric 最后成功采样时间；从未成功时为 `null`。
- `stale` 可以携带最后成功值，`sampledAt` 保持为最后成功时间。
- `unavailable` 的能力值和度量值应为 `null`。
- 接收端使用“最后一次成功收到有效响应”的本地 monotonic clock 判断 Online/Offline，不只依赖对方时钟。

### 4.4 能力协商

`capabilities` 的 boolean 只说明当前平台/版本能否提供对应字段，不代表这一刻采样一定成功。例如 `temperatureSensors: true` 但临时读取失败时，thermal state 可以为 `stale`。

首版能力：

- `cpuBreakdown`
- `loadAverage`
- `hybridCoreTopology`
- `memoryBreakdown`
- `swap`
- `temperatureSensors`
- `osThermalState`
- `wifiSignal`
- `gpuTemperature`（v1 可选扩展；旧端缺失时按 false）
- `storageTemperature`（v1 可选扩展；旧端缺失时根据 `storageCelsius` 是否存在判断）

接收端根据能力隐藏不适用 UI，不用“0”填充不可用能力。

## 5. 字段语义

### CPU

- `utilizationPct`：所有逻辑处理器整体非 idle 比例，不是单核累加百分比。
- `userPct`、`systemPct`、`idlePct`：同一采样窗口的整体拆分，允许因四舍五入不严格等于 100。
- `loadAverage*`：仅在 OS 提供 Unix load average 语义时填写；Windows v1 必须为 `null`。
- `performanceCores`/`efficiencyCores`：逻辑核心数量。无法识别异构类型时 `performanceCores` 放逻辑处理器总数，`efficiencyCores` 为 0，`hybridTopology` 为 false。

### Memory

- `usedBytes`：平台定义的当前活动/实际使用内存，需在该平台版本内保持一致。
- `totalBytes`：物理内存总量。
- `usedPct`：发送端按 `usedBytes / totalBytes * 100` 计算，用于跨平台趋势。
- breakdown 字段是平台相关补充，可以为 `null`；接收端不应尝试让各项相加等于 total。

### Thermal

- `averageCelsius`：主要 CPU/SoC 传感器平均温度。
- `hottestCelsius`：同组传感器最大值。
- `storageCelsius`：主存储温度。
- `gpuCelsius`：独立 GPU 温度。Apple Silicon 无可靠独立 GPU 读数时为 `null`；接收端仍须展示 Windows 端提供的值。
- 早期 Windows 构建若已使用 `ssdCelsius`/`ssdTemperature`，Mac 接收端会兼容读取；后续发送端应统一使用规范名 `storageCelsius`/`storageTemperature`。
- `osState`：`nominal | fair | serious | critical | unavailable`。
- 没有可靠传感器时保持 `null`/`unavailable`，不得用 CPU 使用率估算温度。

### Network

- `uploadBytesPerSecond`/`downloadBytesPerSecond`：默认路由对应的主物理接口差分速率。
- `session*Bytes`：发送端本次应用运行期间累计的有效差分，重启可以归零。
- 接口切换、计数器回绕或重置时必须重建 baseline，不发送异常尖峰。
- v1 不发送 SSID、适配器名或地址。

## 6. 轮询与错误处理

1. 应用启动、网络恢复、系统唤醒或 peer 设置变更时立即请求。
2. 正常间隔 5 秒。失败后使用 5/10/20/30 秒退避，成功即恢复 5 秒。
3. 最近 15 秒内至少一次成功响应为 Online；超过 15 秒为 Offline。
4. JSON/HMAC 校验失败不得更新“最后成功时间”或覆盖最后有效快照。
5. 同一 `device.id` 和应用会话内，只有 sequence 增大才追加趋势；sequence 相同只刷新连接存活时间。
6. sequence 变小且 `device.startedAt` 变更表示对方重启，清空该设备远端趋势并接受新序列。
7. HTTP body 上限 64 KiB；超过即拒绝。连接/读取超时建议 2 秒。
8. 日志只记录 peer device ID 的短前缀、错误类别和时间；不得记录 secret、签名、完整 body。

## 7. 互通测试清单

两端仓库都必须把示例 JSON 加入单元测试，并覆盖：

- 正确解码 fixture，保留 `null`；
- 忽略一个额外未知字段；
- 拒绝错误 apiVersion、缺失必填字段、NaN/Infinity、负 bytes；
- 生成完全一致的请求/响应 HMAC；
- 拒绝被修改的 body、过期 timestamp 和复用 nonce；
- sequence 相同不追加趋势；peer 重启后接受重新从 1 开始的 sequence；
- 3 次 5 秒窗口无响应后显示 Offline，恢复后回到 Online。

端到端验收时，Mac 和 Windows 各自运行服务并指向对方地址，连续交换 10 分钟；比较抓取到的 JSON，而不是比较各平台内部模型。

## 8. 将来升级

- mDNS 发现、二维码/短码配对、WebSocket push 和云 relay 都属于 transport/pairing 层升级。
- v1 JSON metric contract 可原样复用。
- 增加可选字段不提升版本；删除字段、改单位、改枚举意义或改认证 canonical form 必须使用新版本 endpoint（例如 `/v2/status`）。
