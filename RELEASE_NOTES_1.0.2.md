# PTNetwork Studio 1.0.2 — Bridge 编译错误修复

## 修复

- `Sources/PTNetworkStudio/StudioRuntime.swift:264`：原代码 `catch { error = error.localizedDescription }` 尝试写入 `catch` 块自动生成的不可变 `Error` 变量，而不是写入控制器的 `@Published var error: String?`。改为：

  ```swift
  } catch {
      self.error = error.localizedDescription
      self.isRunning = false
  }
  ```

- `Scripts/audit-swift-source.py`：新增针对此类阴影变量的源码回归检查。
- 保留 1.0.1 的 `ComposerSheet` 和跨文件错误类型修复。所有其他功能模块、后端与 PTools 适配代码均保留。

## 检查

- Python 后端：8 项测试通过。
- SwiftPM manifest、Swift 语法解析、源码回归审计：通过。
- macOS arm64 SwiftUI/AppKit 全量 Build：当前运行环境未提供 macOS SDK，尚未实际执行，**不承诺 Xcode 已通过**。

在 Mac 上验证：

```bash
cd ~/Downloads/PTNetworkStudio
sh Scripts/verify.sh
sh Scripts/build-macos.sh
```

建议先将旧文件夹移走再解压新版 ZIP，避免旧源码参与编译。
