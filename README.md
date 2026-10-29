# PTNetwork Studio / DevNetworkWatcher — macOS 网络调试工作台

基于 SwiftUI/AppKit 的三栏网络检查器，HTTPS 抓包由 **mitmproxy/mitmdump** 实现；并包含 Breakpoint、Map Local、Rewrite 与 **PTools 5.69.0 实时 TLS Bridge**。独立实现 UI，不复制 Proxyman 代码、品牌、图标或受保护设计资源。macOS 14+、Swift 5.9+、Xcode 15+；运行 HTTPS 功能需要安装 mitmproxy。无付费 SDK。

> **1.0.2 编译修复说明（2026-10-25）：** 修复 Bridge 启动失败分支的 `catch { error = error.localizedDescription }` 编译错误：将 `StudioBridgeController.error` 赋值写为 `self.error = error.localizedDescription`，并回退 `isRunning = false`。新增检测以避免 `catch` 内置 `error` 遮蔽 UI 属性的回归。

> **1.0.1 历史修复：** 修复 `ComposerSheet.swift` 中 `@State body` 与 `View.body` 同名造成的 `invalid redeclaration of body`；修复 `StudioRuntime.swift` 使用其他文件内 `private ProxyError` 的作用域问题；移除 1.0 已废弃且未调用的 `HTTPProxyServer.swift`，避免旧 socket 实现参与 Xcode 目标编译。新增 `Scripts/audit-swift-source.py` 防止此类错误回归。**本次未在 macOS Xcode 完成类型检查**；Linux 语法解析并不能代替完整 macOS Build。

> **状态说明：** Python 后端 8 项测试通过（含真正 TLS Bridge + 401 授权测试、规则/断点/Map Local 单元测试）；Swift 源码通过语法解析，SwiftPM manifest 检查通过。当前执行环境是 Linux，**没有在 macOS/Xcode 对 SwiftUI App 或真实 mitmdump 进程做过构建/联调**。请先在 Mac 上按下文实编验证。它是完整的源代码交付，不是经过发布级质量认证的商业网络工具。

## 首次安装

```bash
cd PTNetworkStudio
sh Scripts/setup-macos.sh
sh Scripts/build-macos.sh
open build/PTNetworkStudio.app
```

也可在 Xcode → File → Open → 打开根目录 `Package.swift` → 选择 `PTNetworkStudio` Scheme → My Mac。Backend 文件已以 SwiftPM resources 复制，Xcode 直接运行时可找到脚本。

mitmproxy macOS 官方安装建议：`brew install --cask mitmproxy`，也可安装官方 standalone 发行包。如果安装位置不在 PATH、`/opt/homebrew/bin` 或 `/usr/local/bin`，可设置环境变量 `PTSTUDIO_MITMDUMP` 指向实际 mitmdump 可执行文件。Bridge 如有需要可通过 `PTSTUDIO_PYTHON` 指向 Python 3。

## HTTP/HTTPS 抓包与证书

1. 点击 Capture；默认监听 `127.0.0.1:9090`。
2. 在 Terminal 中验证：`curl -x http://127.0.0.1:9090 http://example.com/`。
3. 启动一次后，mitmproxy 将在 `~/Library/Application Support/PTNetworkStudio/mitmproxy` 生成本机 CA。工具栏 **CA** 定位 `mitmproxy-ca-cert.pem`。
4. 在你控制的 Mac 的 Keychain Access 中导入该证书，并**自行明确设为 SSL 始终信任**（仅供开发调试）。重新打开浏览器，代理设置为 `127.0.0.1:9090`；测试 `curl -x http://127.0.0.1:9090 --cacert "$HOME/Library/Application Support/PTNetworkStudio/mitmproxy/mitmproxy-ca-cert.pem" https://example.com/`。
5. 你也可以在浏览器/目标 App 中设置显式 HTTP/HTTPS 代理。不开信任时 HTTPS 握手一般会因证书错误而失败，而不是偷偷透传/伪装解密成功。

**安全：** 只能调试你拥有或获授权分析的流量。导入 CA 后，本机代理有能力读取 TLS 明文；完成测试请关闭代理，删除无须长期信任的 CA。证书锁定（pinning）的目标 App 可能拒绝 HTTPS 解密；不可自动绕过。此实现不进行系统级透明代理或绕过安全限制。

### iPhone Wi-Fi 代理抓包（mitmproxy 模式）

Mac 点击 **Network** → 开启「Allow authenticated LAN proxy clients」，填写至少 12 字符的强密码，启动 Capture。在 iPhone 与 Mac 同一个可信 Wi-Fi 内，打开 Wi-Fi → 配置代理 → 手动，填 Mac 的局域网 IP 和 9090，并启用认证：用户名 `studio`、密码即上面设置的密码。使用 `http://mitm.it` 获取并在 iPhone 上安装 mitmproxy CA；在 **设置 → 通用 → 关于本机 → 证书信任设置** 中主动允许该 CA 的完全信任。建议只用于测试设备，并在结束后清除代理和信任。**局域网代理不应对公网开放。**

这和后面的 PTools SDK Bridge 是两种独立的数据源，可单独使用。

## Rewrite / Map Local / Breakpoint

点击工具栏 **Rules**，逐条添加规则。`pattern` 是**大小写不敏感的 URL glob**，如 `*://api.example.com/v1/*`，`*` 和 `?` 是通配符，不是正则表达式。

- **Rewrite Request**：修改 URL 子串、Header，或正文中的**文字字节**（正文最多 10 MB）。
- **Rewrite Response**：修改 Header 或响应正文文本。
- **Map Local**：选择本地文件；App 会复制到自己的私有 Maps 文件夹，然后匹配 URL 直接返回所选文件的内容、指定 MIME 类型和 HTTP 状态。单文件最大 10 MB，拒绝目录穿越/符号链接越界。
- **Breakpoint Request / Response**：被匹配的请求/响应会暂停。选择流量，点击右侧 **Paused — Resolve**，可直接 Continue、Abort（合成 HTTP 418），也可覆盖 URL、UTF-8 Body、HTTP Status。60 秒无人操作会原样继续，防止长时间挂住业务。

规则按列表顺序执行。请求与响应的编辑仅作用于经过 mitmproxy 的流量；**不会改写由 PTools SDK Bridge 送来的只读观测记录**。对于压缩、二进制、超大、Streaming 或协议特有正文，不承诺通用文本 Rewrite 有效。该工程没有内置可执行 JavaScript 插件沙箱。

## PTools → Mac 实时连接（统一 schema v1）

**连接诊断：** 左侧栏现在会显示独立的 **PTOOLS BRIDGE** 状态（Stopped / Listening / 近期已认证会话数、PTools 事件计数）。只在 iOS Keychain 中出现 `Paired` 不等于连接；Mac 必须收到经过 TLS、Token、Nonce 校验的 `hello` / `heartbeat` 才计为已认证会话。主界面的 `Capture` 是另一个 HTTP 代理（9090），**不负责启动 Bridge**。需在 iPhone → Start Bridge 或启用自动启动；然后让 Debug App 主动发送网络请求，列表才会有 PTools Live 记录。

**证书链：** Bridge 使用原有开发 CA 通过 OpenSSL CA 签发叶证书，启动监听前会验证链是否有效。验证不通过不会发布 Bonjour，以免误报连接就绪。旧 CA 保持不变；如主动更换 Mac TLS 主机名或已失效叶证书被重签，需要在 iPhone 上确认更新后的叶证书指纹。现有开发 CA 如果损坏，需要显式重新建立信任，不能静默绕过 iOS TLS 校验。


**已内置独立 PTools 模块，不要再复制旧 `PToolsIntegration/PTNetworkStudioBridge.swift`。** SPM 显式添加 `PooToolsDEBUG` + `PToolsDebugStudioBridge`；CocoaPods 使用 `PooTools/DEBUG_StudioBridge`。

1. Mac 打开 **iPhone**，优先使用预填的稳定 `.local` 主机名并点击 **Start Bridge**。端口 **9453**，接口 `POST /v1/events`。Bridge 就绪后通过 Bonjour `_ptstudio._tcp.` 广播，附带协议版本、安装 UUID 和 TLS 主机名，**不广播 Token、证书指纹或流量数据**。如改用手输 IP，IP 变动会重新签发叶证书并更新指纹。
2. 点击 **Reveal Development CA (.cer)**。只在授权开发设备上通过 AirDrop/Files 安装该 CA，并在 iOS **设置 → 通用 → 关于本机 → 证书信任设置** 中主动启用完全信任。此 CA 与 mitmproxy 抓包 CA 不同；PTools 必须同时通过系统 TLS 信任和叶证书 SHA-256 校验。
3. iOS Debug App 的 Info.plist 添加 `NSLocalNetworkUsageDescription` 和 `NSBonjourServices = [_ptstudio._tcp]`。在 Debug 设置页使用 `PTStudioAutoConnectionManager.shared.discovery.peers` 选择已发现的 Mac；首次配对输入 Studio UI 中的 Token 和 64 位叶证书 SHA-256 指纹，调用 `approvePairing(peerID:token:fingerprintHex:)` 后保存在 Keychain。Bonjour TXT 仅用于发现，绝不用于认证。
4. 先调用 `PTDebugManager.shared.start(identifier: "network")` 启动抓包，然后使用以下 Swift API 建立只读 Bridge：

```swift
#if DEBUG
import PooToolsDEBUG
import PToolsDebugStudioBridge

@MainActor
func connectMac(host: String, token: String, fingerprintHex: String) async throws {
    PTDebugManager.shared.start(identifier: "network")
    let credentials = try PTStudioPairingCredentials(
        bearerToken: token, leafCertificateSHA256Hex: fingerprintHex
    )
    let transport = try PTStudioHTTPSPushTransport(
        endpoint: URL(string: "https://\(host):9453/v1/events")!,
        credentials: credentials
    )
    try await PTStudioBridge.shared.start(
        using: transport, configuration: .init(isEnabled: true)
    )
}

@MainActor
func disconnectMac() async {
    await PTStudioBridge.shared.stop()
    PTDebugManager.shared.stop(identifier: "network")
}
#endif
```

5. Mac 显示数据源 `PTools Live`。这是只读网络事件流；Rewrite、Map Local、Breakpoint 仅作用于经过 mitmproxy 的代理流量。

### Bonjour 自动发现与已授权重连（默认关闭）

Mac 的 **iPhone → Start Bridge** 成功后才发布服务；停止服务或进程退出时自动撤销广播。可勾选 **Start secure Bridge automatically when Studio opens**，此设置是明确的开发者选择，首次启动仍不会默认开启。Studio 窗口会显示最近一次通过认证的 PTools 会话时间，不公开设备身份。

iOS Debug App 需要开发者明确开启一次自动连接，才调用 `PTStudioAutoConnectionManager.shared.start()` 并保存该开关；此后重新打开 App 可恢复扫描。发现 Keychain 已授权的 Studio 后自动连接，Studio 关闭、网络变更或重启后可以重新发现并重连，前后台切换调用 `refresh()`。连接依旧必须通过系统信任、SHA-256 叶证书 Pin 和 Bearer Token，未配对的广告不启动网络采集。更换 Token 或叶证书后需重新确认配对。开发者关闭自动发现时调用 `stop()`，撤销配对时调用 `revokePairing(peerID:)`。

**限制：** 同一可信局域网内的 mDNS 多播必须可用；iOS 本地网络权限、Mac 防火墙 TCP 9453、开发 CA 完全信任仍需逐项确认。默认 TLS 主机名为 Mac 的 `.local` 名称，如实际 mDNS 名称不一致需在 Studio 调整。真实 iPhone/macOS end-to-end 自动发现联调尚待验证。

Mac Collector 验证 Bearer token、`X-PTStudio-Nonce`、`X-PTStudio-Sent-At`、schema 版本及 eventID 去重，返回 HTTP 200 JSON ACK（`schemaVersion/sessionID/acceptedSequence`）。客户端批量发送最多 24 个事件，根据 ACK 重试。iPhone 与 Mac 需处于可互访的可信局域网，Mac 防火墙须允许 TCP 9453。

**2026-10-29 配对安全修复：** PTools 示例 App 已移除随启动自动连接和硬编码的配对凭据；此版本 Collector 首次启动时废弃旧的 `bridge-token` 文件并生成 `bridge-token-v2`，旧凭据必须重新配对。之后 Token 在正常重启时保持有效；怀疑泄露时先 Stop Bridge，点击 **Rotate Pairing Token**，再 Start Bridge 获取新 Token。Bridge 按钮在 Python 初始化期间显示 Starting，只有收到 `bridgeReady` 后才表示监听成功；PTools 侧应检查 `PTStudioBridge.status().deliveryState` 是否为 `.connected`（收到 ACK），不能只检查 `isRunning`。

**验证边界：** Python 后端真实 TLS/CA、身份校验、ACK/重试及脱敏测试不代表已完成 macOS Xcode/iOS 真机联调。仅用于开发调试；测试完成关闭 Bridge 并按需撤销开发 CA 信任。

## 其他功能与界面

- 原生 3 栏：Host/快速分类 → 请求流量列表 → Request/Response/Summary Inspector。
- 手工 Compose、过滤检索、复制脱敏 cURL、Session JSON 与 HAR 导入导出（含 PTools 5.69.0 生成的 HAR）。
- HTTP/HTTPS 经 mitmproxy 的上游证书校验默认开启；支持 HTTPS 目标与 HTTP/2（由 mitmproxy 实现），WebSocket 帧当前仅记录长度与目标元数据。
- 可配置本地监听与 LAN（LAN 模式需代理用户名/密码），没有默认开启全系统代理。
- 采集正文预览大小上限 64 KiB。已知 Header、Query、JSON/Form 敏感字段会被遮盖；未知类型 Body 默认隐藏。不能保证对所有私有业务字段的识别。导出前不要放入未审核的敏感数据。
- PTools Bridge 仅上传已经 PTools 自身隐私策略处理的 JSON 和可选大小受限的脱敏 JSON 正文；Mac 再进行一层脱敏。

## 主要项目文件

```
Package.swift
Sources/PTNetworkStudio/
  StudioApp.swift, StudioContentView.swift, FeatureSheets.swift, ComposerSheet.swift
  StudioRuntime.swift, StudioBonjourAdvertiser.swift, Models.swift, PrivacyFilter.swift, SessionFiles.swift
  Backend/
    studio_addon.py                   # 真实 HTTP/HTTPS MITM 观察、重写、断点、映射
    studio_rules.py                   # 与 mitmproxy 解耦的隐私过滤和规则原语
    bridge_server.py                 # TLS + token + 二次脱敏 iPhone 接收服务
Tests/BackendTests/               # 含 TLS 桥接与 addon 生命周期测试
Tests/PTNetworkStudioTests/
Scripts/setup-macos.sh, build-macos.sh, verify.sh, audit-swift-source.py
Docs/PTools_5.69.0_PTNetworkStudio_Debug_Bridge_Upgrade_Plan_2026-10-25.md
VALIDATION.md
```

## 构建／验证

```bash
sh Scripts/verify.sh
```

在 Mac 上会执行 Python 测试、SwiftPM manifest 检查、Swift 语法解析、源码回归检查、`swift test` 和 App bundle 打包。请务必在真实 macOS Tahoe 26/Apple Silicon 上进一步做 Safari HTTPS 信任、证书锁定 App、USB/Wi-Fi iOS Bridge、请求/响应断点、Map Local 大小/路径以及多并发流量验收。

## 限制及许可证

- HTTPS 引擎依赖外部的 **mitmdump**，需要使用官方 mitmproxy 二进制；并非一个零依赖自研 TLS 引擎。
- 与商业 Proxyman 的功能范围并非完全等同：不提供其专有 UI、扩展生态、自动系统代理、HTTP/3 透明捕获、完整 WebSocket Frame Inspector 或大规模生产流量性能保证。
- PTools Studio Bridge 已作为独立模块提供，不需要从本仓库复制源码。
- 来源：PTools https://github.com/crazypoo/PTools ；Proxyman 功能参考 https://github.com/ProxymanApp/Proxyman ；mitmproxy https://docs.mitmproxy.org/stable/ 。安装和随附任何外部二进制时须遵守其发布许可证。
