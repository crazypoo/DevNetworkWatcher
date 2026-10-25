# PTNetwork Studio 1.0.1 编译修正版

## 已修复

1. `Sources/PTNetworkStudio/ComposerSheet.swift`：`@State private var body` 与 SwiftUI `View.body` 同名。重命名为 `requestBody` 并更新 `TextEditor`、发送请求时的访问。
2. `Sources/PTNetworkStudio/StudioRuntime.swift`：此前引用声明在另一文件且为 `private` 的 `ProxyError`，会触发作用域不可见。改用 `StudioRuntimeError`。
3. 移除 1.0 不再使用的 `HTTPProxyServer.swift`，代理引擎依然由 `mitmdump` + `Backend/studio_addon.py` 提供。
4. 新增 `Scripts/audit-swift-source.py`，并纳入 `Scripts/verify.sh`，防止相同问题再次出现。

## 验证结果

Linux: Python 8 tests PASS，`swift package dump-package` PASS，Swift 语法解析 PASS，源码回归扫描 PASS。

未完成：macOS/Xcode SDK 环境编译以及真机连接验收。若构建仍有新的类型检查报错，请提供 Xcode 日志中第一条 `error:`，而不是 `SwiftCompile failed` 摘要。
