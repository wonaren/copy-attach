# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在此仓库中工作时提供行为指引。

## 行为约定

### 从第一性原理分析代码
分析代码时从第一性原理出发：先理解核心数据流和不变量的本质，再逐层验证具体实现是否忠实于这些原理。不依赖既有注释、命名或架构图作为理解起点——它们可能是过时或错误的。最终目标是确认或修正对系统本质的理解。

### 不要搞兜底实现
不要为实现某个功能编写 fallback / 兜底逻辑。兜底实现会掩盖主流程的错误，让 bug 难以被发现和调试。如果主流程失败，应该让错误显式暴露（panic、返回错误、日志 + 空结果），而不是用降级方案静默吞掉失败。调用方应当能感知到失败并决定如何处理。

## 构建与测试

```bash
# 构建全部（Rust 库 + Swift 应用包）
./build.sh

# 仅 Rust：release 构建
cargo build --release

# 仅 Rust：运行测试
cargo test

# 打开应用
open "CopyAttach.app"
```

所有命令的项目根目录为 `clipboard-manager/`。构建脚本将 Rust 编译为 `target/release/libcopy_attach.dylib`，拷贝到 `CopyAttach.app/Contents/Frameworks/`，用 `swiftc` 编译 Swift 源码，ad-hoc 签名后产出 `CopyAttach.app`。

## 架构

**Rust 后端**（[src/lib.rs](src/lib.rs)）——一个 `cdylib`，通过扁平的 C FFI 暴露接口。通过 `arboard` 每 300ms 轮询 macOS 剪贴板，捕获文本和 PNG 编码图片，基于文本相等或图片哈希去重，维护最多 1000 条历史记录。通过 `CGEventPost`（Cmd+V）模拟粘贴，通过 `AXIsProcessTrusted` 检查辅助功能权限。所有状态存放于 `OnceLock<Backend>` 单例中，`Arc<Mutex<Vec<ClipboardEntry>>>` 历史数据与后台监控线程共享。

**Swift 前端**（[SwiftApp/](SwiftApp/)）——仅菜单栏的应用（`LSUIElement: true`），使用 SwiftUI + AppKit：

- [CopyAttachApp.swift](SwiftApp/CopyAttachApp.swift)——`@main` 入口，含 `MenuBarExtra` 和 `AppDelegate`，启动时初始化 Rust 后端，管理设置窗口和弹窗切换。
- [ClipboardBackend.swift](SwiftApp/ClipboardBackend.swift)——Rust C FFI 的 `ObservableObject` 封装。每 0.5s 通过 Timer 轮询 `clipboard_get_count()`，有变更时重载条目，周期性调用 `clipboard_set_source_app()` 告诉 Rust 当前前台应用。
- [HistoryPopupView.swift](SwiftApp/HistoryPopupView.swift)——`NSPanel`（浮动、无边框、非激活面板）承载 SwiftUI `HistoryPopupContent`，支持键盘导航（↑↓ Enter Esc）、悬停/选中高亮、滚动到选中项、以及每项的应用图标+来源名显示。
- [HotkeyManager.swift](SwiftApp/HotkeyManager.swift)——双重机制的全局热键：Carbon `RegisterEventHotKey`（主）+ `NSEvent.addGlobalMonitorForEvents`（备）。支持运行时录制新快捷键，配置以 JSON 持久化到 `UserDefaults`。默认为 ⌥⌘V。
- [CopyAttach-Bridging-Header.h](SwiftApp/CopyAttach-Bridging-Header.h)——与 Rust `#[no_mangle] extern "C"` 函数匹配的 C FFI 声明，`swiftc` 通过 `-import-objc-header` 导入。

**数据流**：Rust 在后台线程监控剪贴板 → Swift 通过 FFI 轮询条目数 → 有变更时 Swift 将标签/缩略图重载为 `ClipboardItem` 枚举（`.text` / `.image`）→ SwiftUI 在弹窗中渲染。用户选择条目时 Swift 调用 `clipboard_select_and_paste()`，通过 `arboard` 写回剪贴板，sleep 50ms，然后通过 `CGEvent` 发送 Cmd+V。

**FFI 所有权规则**：Rust 返回的字符串（`clipboard_get_item_text` 等）调用方必须用 `clipboard_free_string` 释放；字节缓冲区（`clipboard_get_image_thumb`）必须用 `clipboard_free_bytes` 释放。Swift `ClipboardBackend` 封装已处理这些。

**调试日志**：[HotkeyManager.swift](SwiftApp/HotkeyManager.swift) 中的 `debugLog()` 函数写入 stderr 和 `/tmp/copyattach_debug.log`。开发时可用 `tail -f /tmp/copyattach_debug.log` 监控。
