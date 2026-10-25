# PTNetwork Studio 1.0.2 验证记录 — 2026-10-25

当前构建环境：Linux x86_64 + Swift toolchain + Python 3 + OpenSSL；**无 macOS/Xcode/mitmdump 二进制**。

| 检查 | 结果 | 实施细节 |
|---|---|---|
| 1.0.2 Source regression audit | PASS | 检查 `ComposerSheet` 无存储 `body` 属性、`requestBody` 引用齐全、运行时错误类型可跨文件访问，并移除旧 `HTTPProxyServer`。 |
| SwiftPM Manifest | PASS | `swift package dump-package` |
| Swift Syntax parse | PASS | 所有 macOS Swift 文件与 PToolsIntegration Swift 文件 `swiftc -frontend -parse`；**不等于 typecheck/build** |
| Python compile | PASS | `python3 -m py_compile` |
| Rule tests | PASS | rewrite/matcher, JSON/Header/URL 脱敏, Map Local sandbox |
| Addon lifecycle | PASS (mock) | 假 `mitmproxy.http` Flow 对象验证请求重写 + 断点放行、Map Local 内容返回；无真实 mitmdump 安装 |
| TLS Bridge | PASS | 启动真 TLS1.2+ Server，OpenSSL 自签证书，HTTPSConnection: 错 token→401、正确 token→204、输出数据二次脱敏 |
| macOS SwiftUI build | NOT RUN | 需 Xcode 15+ on macOS 14+ |
| Native mitmdump HTTPS decrypt | NOT RUN | 需要安装官方 mitmdump 并在 Mac 手动信任测试 CA |
| Real PTools 5.69.0 iOS Adapter Build | NOT RUN | 需将 bridge Swift 文件并入 PTools DebugNetwork 目标，在 iOS Simulator/真机编译 |
| PTools iPhone over LAN | NOT RUN | 需要真机、安全配对证书指纹、网络权限、Mac 防火墙放行 |

**结论：** 三组功能的源码和必要 UI 及 Bridge 通道已经落地并通过有限的自动化测试，**未完成 macOS App 的真实编译/运行级别验证**。不能宣称编译已在用户的 Mac 上通过，也不能保证所有 Proxyman 高级能力等效。

## 手动验收建议

1. macOS 安装 mitmdump；运行 `sh Scripts/verify.sh` 与 `sh Scripts/build-macos.sh`。
2. 启动 Capture → curl HTTP → 信任本机 CA → curl HTTPS，核查明文 JSON/状态码。
3. Rewrite Request/Header/Body、Response、Map Local，确保返回替换内容。
4. 设 Breakpoint Request 与 Response，测试 Continue、编辑、Abort、60 秒超时。
5. Mac 启动 PTools Bridge → iOS Debug App 复制接入代码 → 校验证书指纹与 token → 观察 PTools Live 事件。
6. 测试配错 SHA256、配错 token、离线、取消、未授予 Local Network、多个请求并发与隐私导出。
7. 退出 App 时关闭所有监听（当前 1.0 UI 可 Stop；遇到强制结束依赖系统清理子进程，应检查残留 mitmdump/bridge_server 进程）。

## 1.0.2 新增修复

- `StudioRuntime.swift:264`：`catch` 自动绑定的 `error` 是不可变 `Error`；显式使用 `self.error` 写入 `@Published String?`。
- `Scripts/audit-swift-source.py`：补充 `catch { error = ... }` 回归检查，且确保 `self.error = error.localizedDescription` 保留。
- 测试结果：8 个 Python 后端测试 PASS；SwiftPM manifest、Swift frontend parse、源码审计 PASS；macOS Xcode 类型检查 NOT RUN。

## 1.0.1 历史修复

- `ComposerSheet.swift`: `@State private var body` → `requestBody`，包括文本编辑器和 URLRequest 编码。
- `StudioRuntime.swift`: 独立声明可见的 `StudioRuntimeError`，替换无法跨文件访问的 `private ProxyError`。
- `HTTPProxyServer.swift`: 1.0 已迁移至 mitmdump，此文件不再使用，移除以减少多余的编译/并发边界。
- `Scripts/audit-swift-source.py`: 检查上述回归，`verify.sh` 自动调用。

**本次验证范围**：8 个 Python 后端测试、SwiftPM manifest、Swift frontend parse 与源码审计。
**未验证**：Apple Silicon/macOS Xcode 实际编译、SwiftUI 类型检查、真实 mitmdump 动态流程。
