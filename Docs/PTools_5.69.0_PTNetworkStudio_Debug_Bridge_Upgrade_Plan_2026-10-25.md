# PTools 5.69.0 → PTNetwork Studio 联动升级实施计划

> 基线：2026-10-25 检查 `crazypoo/PTools` 默认分支 `master`，`VERSION = 5.69.0`。本文件是**PTools 仓库尚待合并和验收的升级计划**，不是 PTools 主分支已完工清单。Mac 端 1.0 源码已包含 HTTPS MITM（mitmdump 后端）、规则/断点编辑，以及可选的 PTools 桥接样例 `PToolsIntegration/PTNetworkStudioBridge.swift`；这些源码已通过有限的 Linux 测试，但尚未经 macOS 真正构建/iPhone 集成验证，也尚未合并进 PTools。
>
> 原则：PTools 现有 DebugNetwork 2.0 是**只读采集层**；不得为了兼容桌面抓包工具破坏业务网络、增添不可逆 hook 或默认暴露敏感数据。

## 1. 已核实的现状与问题边界

| PTools 模块 / 证据 | 当前能力 | 对 PTNetwork Studio 的意义 |
|---|---|---|
| `PooToolsSource/DebugNetwork/PTNetworkCaptureStore.swift` | actor 存储 `PTNetworkCaptureRecord`、`AsyncStream<PTNetworkCaptureChange>`、限制记录数/正文预算、exactly-once finalize | 可以增量输出经过脱敏的快照，不必新建第二套抓包事实源 |
| `PooToolsSource/DebugNetwork/PTNetworkCaptureModels.swift` | `PTNetworkCaptureRecord` / `PTNetworkRequestSnapshot` / `PTNetworkTiming` 等 `Codable, Sendable` | 可作为 DTO 映射的来源，但不能直接传本地文件 URL 或未知私有字段 |
| `PooToolsSource/DebugNetwork/PTNetworkExporters.swift` | `PTNetworkHARExporter`、cURL、Text；HAR 1.2 额外含 `_ptools` 元数据 | Mac MVP 已可从菜单导入 HAR；完全不需要改变现有 HAR 导出 |
| `PooToolsSource/DebugNetwork/PTNetworkRedactor.swift` 和 `docs/debug/DEBUG_NETWORK_PRIVACY.md` | Authorization/Cookie/Query/JSON 递归脱敏 | 桥接通道仍须再次统一调用同一隐私策略，不允许 UI 或传输层绕开 |
| `PooToolsSource/DebugNetwork/PTCustomHTTPProtocol.swift` | `URLProtocol` 只转发并观察 HTTP/HTTPS 请求 | 保留当前转发语义，不能将它改成通用 MITM、Rewrite 或缓存决策器 |
| `docs/debug/DEBUG_NETWORK_CAPABILITY_MATRIX.md` | background URLSession、WKWebView、WebSocket、Network.framework 尚有明确限制 | 新桥接不能把目前不可见的流量伪造成“已支持” |
| `docs/debug/DEBUG_NETWORK_ARCHITECTURE.md` | Capture Engine 与每个 Scene 的 PresentationSession 分离，UI 批量更新 | 桌面桥接是新的消费者，不能反向控制 Scene 或 UI 主线程 |
| `docs/debug/DEBUG_NETWORK_EXAMPLE.md` | 已有 GET/POST、错误、重定向、大文件和隐私夹具验收项 | 在原有测试基础上增加 Mac 链路，不重复建设 |

**结论**：需要升级的是跨设备传输、桌面协议握手、设备身份与安全、会话恢复和工具联动，而不是推翻 DebugNetwork 2.0。桌面端真正的 HTTP/HTTPS 代理、MITM、Map Local、Rewrite 应独立演进，PTools 只提供可选的**只读诊断 Bridge**。

## 2. 目标形态

```text
UIKit / PTools Network / URLProtocol / Network adapters
            │
            ▼
   PTNetworkCaptureStore  (唯一事实源)
            │  immutable, redacted, bounded snapshots
            ▼
   PTNetworkStudioBridge (可选 Debug 产品、独立生命周期)
            │  版本协商 + mTLS或配对凭证 + backpressure
            ├──── TLS 1.2+ HTTPS POST ──►  PTNetwork Studio Desktop Collector
            │      bearer token + pinned server cert SHA-256（目前样例实现）
            └──── 脱敏 HAR export ───►  PTNetwork Studio Import HAR (MVP 已实现)

[独立 macOS Proxy Server] ──►  Desktop Collector / Unified Session View
```

Mac 应用自身的显式 HTTP proxy 不等于 PTools 的 `URLProtocol`；两者数据来源必须保留 `source` 标识、时钟偏差、请求 ID、是否经过 TLS 解密等元数据。

## 3. 分阶段改造清单

### P0：冻结契约及审计（变更前必须完成）

- [ ] 对 `master` 最新提交锁定审计 SHA；保存 PTools 5.69.0 当前 public API baseline。
- [ ] 复核 `PTNetworkCaptureRecord` / `PTNetworkRedactor` / HAR schema，明确预览截断、磁盘 URL、body length -1 的行为。
- [ ] 新增 `PTNetworkStudioCapabilities`：`captureHTTP`、`observeTaskMetrics`、`observeWebSocketMessages`、`supportsBackgroundSession` 等显式能力位。能力以真实适配器验证为准。
- [ ] 规范来源枚举扩展与版本协商；保留现有 `PTNetworkCaptureSource` 编码值，不破坏旧 archive。
- [ ] 保证 bridge 关闭时额外任务数为 0，不新增 `URLProtocol` swizzle。

### P1：新增隔离的纯诊断模型层

建议文件结构（最终路径依照 Package.swift 的 target ownership）：

```text
PooToolsSource/DebugNetwork/StudioBridge/
  PTStudioEnvelope.swift
  PTStudioCapabilities.swift
  PTStudioSnapshotMapper.swift
  PTStudioPrivacyGate.swift
  PTStudioBridgeConfiguration.swift
  PTStudioBridge.swift
  PTStudioTransport.swift
  PTStudioPairing.swift
  PTStudioBackpressure.swift
  PTStudioSessionClock.swift
```

- [ ] `PTStudioEnvelope: Codable, Sendable`，字段包含 `schemaVersion`、`sessionID`、`deviceID`（随机非设备硬件 ID）、`eventID`、`requestID`、`sequence`、`monotonicTime`、`wallTime`、`source`、`kind`、`payload`。
- [ ] 类型化消息：`hello`、`capabilities`、`recordUpsert`、`recordFinalize`、`recordDelete`、`sessionReset`、`heartbeat`、`ack`、`error`。**禁止**直接序列化闭包、URLSessionTask 或 `PTNetworkBodyCapture.file(url:)` 的本机路径。
- [ ] `PTStudioSnapshotMapper` 由原生 `PTNetworkCaptureRecord` 映射，响应体默认只发脱敏 bounded preview、正文真实大小及 truncated 标志。
- [ ] `PTStudioPrivacyGate` 必须在编码、存储队列、发送、离线缓存和导出之前生效；不能发送 raw token，然后寄希望于桌面端隐藏。
- [ ] 用 `actor PTStudioBridge` 维护连接状态；唯一从现有 `PTNetworkCaptureStore.changes()` 订阅。断线自动取消流，避免重复 observer。

**建议内部 schema 样例（示意，不是当前已存在的 PTools API）：**

```json
{
  "schemaVersion": 1,
  "kind": "recordFinalize",
  "sessionID": "UUID",
  "eventID": "UUID",
  "requestID": "UUID",
  "sequence": 19,
  "source": "urlProtocol",
  "timestamp": "2026-10-25T12:00:00Z",
  "payload": { "method": "GET", "url": "https://api.example.com/data?token=%3Credacted%3E", "status": 200, "bodyTruncated": false }
}
```

### P2：安全连接和发现

- [ ] 初版建议先支持**Mac + iOS Simulator 的 loopback 配对**；真机 LAN 接入需额外做设备发现与权限。
- [ ] 传输层使用 `Network.framework` 的加密连接或等效 TLS 信道；不得在局域网明文广播所有抓包日志。
- [ ] 双端确认配对码/短期 token，存储在 Keychain，定期轮换；防重放 nonce / 超时 / 版本白名单。
- [ ] `NSLocalNetworkUsageDescription`、Bonjour 服务类型（若使用）、用户主动开关；非开发构建默认禁用。
- [ ] Mac Collector 仅监听用户明确开启的接口；提供连接详情、配对撤销、拒绝未知设备。控制命令与观测流权限分离。
- [ ] 明确 TLS interception / CA trust 是桌面代理功能，不与这个诊断 Bridge 的端到端加密混同。

### P3：流控和稳定性

- [ ] 100–200ms 聚合变更，按 requestID 合并 `upsert/finalize`；一次 finalize 的语义端到端保持。
- [ ] 限制序列化大小、队列事件数、正文大小及磁盘占用；断线仅保留有限的脱敏 ring-buffer。
- [ ] 加入 ack、水位线、掉线重连指数退避、session sequence gap 提醒；不得阻塞主线程、URLSession delegate 或业务请求完成路径。
- [ ] 支持多个 Scene 共用 Bridge 一个 connection，UI 退出不关闭 DebugNetwork 全局采集。
- [ ] Bridge 与应用进入后台的处理以 iOS 真实进程生命周期为准：不虚构后台常驻能力。

### P4：独立高级工具（主要在 macOS App 实施）

- [ ] 完成系统 HTTP/HTTPS proxy 手动配置状态检测与一键恢复；系统级改动必须有用户确认，异常退出恢复原设置。
- [ ] HTTPS MITM **明确按域名白名单开启**：生成本机 CA、Keychain 私钥保管、逐域名证书签发、用户安装/信任步骤、证书轮换与撤销、pinning 检测及失败提示。不得静默安装或绕过证书固定。
- [ ] 代理增加 HTTP/2、HTTP/3/QUIC 能力边界与 WebSocket/SSE frame inspector；当前 MVP 仅 HTTP/1.1 + CONNECT 透传。
- [ ] Map Local、Map Remote、Breakpoint、Rewrite、Repeat、Compose、Block List、弱网模拟分别做独立规则执行器，有清楚匹配优先级和冲突检测。
- [ ] 提供 Timeline、搜索规则保存、重复请求 Diff、GraphQL/JSON 格式化、HAR 回放；保证隐私策略贯穿所有输出。
- [ ] 远程设备代理须增加局域网监听的访问控制和防开放代理风险，不能简单把当前 `127.0.0.1` 改为 `0.0.0.0`。

### P5：集成验证矩阵

| 场景 | 最低必须通过的测试 |
|---|---|
| `URLSession.shared` / async / ephemeral / Alamofire | 正常业务、超时、取消、重试、缓存语义不变；Bridge 的 record 与当前 UI 一致 |
| 401、403、5xx、重定向和 gzip | 状态、耗时、原始与脱敏视图边界正确 |
| 10,000 个短请求、100 MB 响应 | bounded memory + backpressure；不出现 UI 全量重载或主线程卡顿 |
| 断网 / App 后台 / 锁屏 / 恢复 | 连接状态正确、丢包显式提示、无泄露或重复 finalization |
| 敏感凭证（header/query/嵌套 JSON/form） | Mac 屏幕、文件、HAR、cURL、日志均不得出现原值 |
| 多 Scene / iPhone Duo 开合与横竖屏 | Bridge 不依赖 UIKit Scene 高度或视图存活，重复订阅为零 |
| WKWebView / WebSocket / Network.framework | 未接适配器时标注未支持；有适配器后用真机测试升级状态 |
| 不同设备时钟 | duration 用单调时间计算，时间轴用 wall clock + 显式校正 |
| 配对撤销 / 误连接 / 非调试构建 | 拒绝未授权设备；Release 默认关闭，失效凭证无法连接 |

## 4. macOS MVP 已实现与未实现的分界

**独立 macOS 源码已提供：** 三栏深色界面、手动启动/停止的 `127.0.0.1` HTTP/1.1 显式代理、HTTP 请求/响应观察、HTTPS CONNECT 隧道元数据、已知敏感字段脱敏、域名过滤、Compose、Session JSON 与 HAR 读写、PTools HAR 导入。

**未实现（需要后续开发）：** PTools 实时设备 Bridge、远程真机接入、HTTPS 解密和 CA 信任管理、自动修改系统代理、WebSocket frame/HTTP2、Map Local/Remote、Breakpoint/Rewrite、流量限制与脚本执行。**不要将这些列为已完成。**

## 5. 推荐发布与兼容策略

- PTools：在 5.69.x 增量版本增加 `PToolsDebugStudioBridge` 可选模块，依赖现有 DebugNetwork，但不让 Core/Network 反向依赖桌面端；最小支持仍为 iOS 17+。
- macOS：PTNetwork Studio 0.1 使用 SwiftUI + AppKit + Darwin socket，macOS 14+；提升网络核心到 Network.framework 或 SwiftNIO 应建立可比较的性能基线再决定。
- 5.x 不移除 `PTNetworkHelper`、`PTNetworkCaptureStore` 或既有 ExportManager public API；新增入口配合旧接口保持源码兼容。
- 使用 `#if DEBUG` + 显式用户开关，发布包默认不发出抓包诊断流量；如内部测试包要求开启，必须显式声明隐私范围。
- 不建议为桌面工作台在 PTools 内引入 AppKit、SwiftUI、macOS socket server、SSL MITM 依赖。

## 6. 完成定义（DoD）

1. 纯 Debug Bridge 能在 PTools Demo iOS17+ 和 macOS app 双端编译，5.69.0 旧调用无需迁移。
2. 导出 HAR 与 Bridge 展示的请求数、requestID、status、duration、error 一致；断线重连无重复。
3. 真机与 Simulator 使用明确标记的 fixture 检查连接、权限、隐私、性能及场景生命周期。
4. SSL MITM 必须独立交付安全审计、授权 UI、证书卸载和 pinning 边界测试后才可宣称完成。
5. macOS App 在目标 macOS Tahoe 26 + Apple Silicon Xcode 环境实编、启动并以 `curl -x` 进行 HTTP/HTTPS 连通验收，不能仅以 Linux 静态解析通过作为可运行结论。

## 7. 已查阅源码依据

- https://github.com/crazypoo/PTools/blob/master/VERSION
- https://github.com/crazypoo/PTools/blob/master/docs/debug/DEBUG_NETWORK.md
- https://github.com/crazypoo/PTools/blob/master/docs/debug/DEBUG_NETWORK_ARCHITECTURE.md
- https://github.com/crazypoo/PTools/blob/master/docs/debug/DEBUG_NETWORK_CAPABILITY_MATRIX.md
- https://github.com/crazypoo/PTools/blob/master/docs/debug/DEBUG_NETWORK_PRIVACY.md
- https://github.com/crazypoo/PTools/blob/master/PooToolsSource/DebugNetwork/PTNetworkCaptureStore.swift
- https://github.com/crazypoo/PTools/blob/master/PooToolsSource/DebugNetwork/PTNetworkCaptureModels.swift
- https://github.com/crazypoo/PTools/blob/master/PooToolsSource/DebugNetwork/PTNetworkExporters.swift
- https://github.com/ProxymanApp/Proxyman
- https://docs.proxyman.com/
