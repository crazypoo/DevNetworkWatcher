# PTNetwork Studio — macOS 网络调试工作台（源码 1.0.2 编译修正版）

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

## PTools 5.69.0 → Mac 实时连接

**不需要为 PTools 的 `PTNetworkCaptureStore` 另做一套抓包器。** 已确认当前主分支已提供：`PTNetworkCaptureRecord.redacted()`、`PTNetworkCaptureStore.shared.records()`、`changes()` 和 `record(id:)`。Bridge 复用它们并走独立 TLS 通道。

1. 在 Mac 工具栏点击 **iPhone → Start Bridge**。显示端口 `9443`、32 字节随机 token 和本机服务端证书 SHA-256 指纹。桥接监听局域网，使用自签名 TLS 证书并验证 Bearer token。
2. 把 `PToolsIntegration/PTNetworkStudioBridge.swift` 复制到 **PTools 源码目录** `PooToolsSource/DebugNetwork/`（或运行 `sh Scripts/install-ptools-bridge.sh /你的/PTools/源码目录`）。与 PTools 5.69.0 的 `PTNetworkCaptureStore`/Record 在同一 module 内编译，不需要额外 import PTools。
3. 你使用 **PTools 源码版**（或自己的 fork）编译 iOS App，在合适的 Debug 入口使用如下接口，填写 Mac 在 Wi-Fi 中的实际 LAN IPv4 地址及 Mac UI 显示的 token/指纹：

```swift
#if DEBUG
Task {
    try? await PTNetworkStudioBridge.shared.start(
        macAddress: "192.168.1.20", // 替换成自己的 Mac 局域网 IP
        port: 9443,
        pairingToken: "粘贴 Mac UI 当前生成的随机 Token",
        certificateSHA256: "粘贴 Mac UI 显示的 64 位 SHA256"
    )
}
#endif
```

4. iOS App 的 Info.plist 应包含 `NSLocalNetworkUsageDescription`，确保真机已授权本地网络访问，设备与 Mac 在同一个可达 LAN。防火墙需允许 macOS App/Python Bridge 的传入 TCP 9443。首次连接需要解锁并确认提示。
5. 在 App 中打开 PTools DebugNetwork；随后产生的网络流量会被 SDK 读取并发送到 Mac。Mac 中会以 **PTools Live** 数据源出现，不要求客户端系统信任 mitmproxy CA，也不会修改业务请求。
6. 调试完成，在 iOS 端调用 `await PTNetworkStudioBridge.shared.stop()`，在 Mac 点击 Stop Bridge。不要将实际 token 或指纹硬编码到发布版本；不要在 Release 中启用 Bridge。

Bridge 是**进程内、开发构建的只读事件传输器**，由 iOS `URLSession` 携带带证书指纹固定校验的 TLS 请求发送。它不支持直接连接未修改的 PTools 5.69.0 二进制：需要按步骤增加 SDK 源文件，或按升级计划正式纳入 PTools。

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
  StudioRuntime.swift, Models.swift, PrivacyFilter.swift, SessionFiles.swift
  Backend/
    studio_addon.py                   # 真实 HTTP/HTTPS MITM 观察、重写、断点、映射
    studio_rules.py                   # 与 mitmproxy 解耦的隐私过滤和规则原语
    bridge_server.py                 # TLS + token + 二次脱敏 iPhone 接收服务
PToolsIntegration/PTNetworkStudioBridge.swift
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
- Bridge 对 PTools 5.69.0 需要手动合并源文件；尚未向 GitHub 主分支提交或 PR。
- 来源：PTools https://github.com/crazypoo/PTools ；Proxyman 功能参考 https://github.com/ProxymanApp/Proxyman ；mitmproxy https://docs.mitmproxy.org/stable/ 。安装和随附任何外部二进制时须遵守其发布许可证。
