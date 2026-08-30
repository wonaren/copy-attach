# CopyAttach Windows 版

`windows-support` 分支为 CopyAttach 提供 Windows 支持。核心思路：**Rust 后端是同一份代码**，通过新增的平台抽象层（`src/platform/`）在 macOS 与 Windows 上各有一份剪贴板/粘贴实现；前端因 SwiftUI 无法运行于 Windows，用 **Swift on Windows + 原生 Win32** 重写为 MVP（`SwiftWin/`）。

## 架构

```
┌─────────────────────────┐      ┌──────────────────────────────┐
│ SwiftWin/ (Windows)     │      │ SwiftApp/ (macOS)            │
│ Win32 + WinSDK module   │      │ SwiftUI + AppKit             │
└───────────┬─────────────┘      └───────────┬──────────────────┘
            │        同一套 C ABI（FFI）       │
┌───────────▼────────────────────────────────▼──────────────────┐
│ Rust 后端 src/  （monitor / history / db+FTS / image / ffi）    │
│                          platform/  ← 平台抽象层               │
│                  ├── macos.rs   NSPasteboard / CGEvent         │
│                  ├── windows.rs GetClipboardSequenceNumber /   │
│                  │              arboard(CF_DIB) / SendInput    │
│                  └── stub.rs    其他平台（显式失败）             │
└────────────────────────────────────────────────────────────────┘
```

### Rust 平台抽象层（`src/platform/`）

统一 API：`change_count` / `read_text` / `capture_image` / `set_clipboard_text` / `set_clipboard_image` / `set_clipboard_file_url` / `simulate_paste` / `check_permission` / `open_preferences`。调用方（`monitor`、`ffi/paste`、`ffi/accessors`）不再直接触碰 OS API。

Windows 实现要点：

- **变更检测**：`GetClipboardSequenceNumber` —— 对应 macOS `changeCount` 的轻量轮询语义，自写检测（`pending_self_write`）机制原样复用。
- **不常驻剪贴板句柄**：Windows 上 `arboard::Clipboard::new()` 会独占打开剪贴板直到句柄释放，长期持有会阻塞所有应用写入剪贴板。因此所有读写按事件新开句柄（仅在检测到变更时，开销可忽略）。
- **图片捕获**：arboard 读 `CF_DIB` 转 RGBA，进入与 macOS 相同的两阶段捕获管线（缩略图同步、全量 PNG 异步、单槽背压队列）。
- **图片粘贴**：macOS 的 `public.file-url` 文件路径约定在 Windows 不存在，改为直接把解码后的图片写进剪贴板（`CF_DIB`），主流应用（Paint/Word/聊天客户端）可直接粘贴。
- **粘贴模拟**：`SendInput` Ctrl+V 发往前台窗口（目标应用由前端在弹出前捕获并在粘贴前交还前台）；无辅助功能权限门控。
- **内存治理**：`MADV_FREE_REUSABLE`/`MADV_FREE_REUSE` 是 macOS 专属，`backend.rs` 中相关逻辑原本就 cfg-gated，Windows 上自动 no-op。

### Swift on Windows 前端（`SwiftWin/`）

MVP 功能面（对齐用户选定的范围）：

- 托盘图标 + 右键菜单（打开历史 / 清除历史 / 退出）
- 全局快捷键（默认 Alt+X，`RegisterHotKey`，可在 `%APPDATA%\CopyAttach\settings.json` 配置 VK 与修饰键）
- 剪贴板监控（Rust 线程，事件 + 500ms revision 轮询刷新 UI）
- 无边框弹窗：搜索框（走 SQLite FTS 全文搜索）+ 虚拟列表（`LVS_OWNERDATA`，万条无压力）
- 键盘操作：↑/↓ 选择、Enter 粘贴、Delete 删除、Ctrl+Z 撤销、Esc 关闭
- 图片条目显示 `Image (W×H)` 标签（缩略图渲染后续迭代）

## 构建（Windows x64）

先决条件：

1. Rust（`rustup target add x86_64-pc-windows-msvc`）
2. Visual Studio 2022 Build Tools（C++ 工作负载；在 "x64 Native Tools Command Prompt" 中运行构建）
3. [swift.org](https://www.swift.org/install/windows/) 的 Swift 6.x 工具链（自带 WinSDK 模块）

```powershell
powershell -ExecutionPolicy Bypass -File build-windows.ps1
```

产物在 `build\windows\CopyAttach\`（`CopyAttachWin.exe` + `copy_attach.dll`）。

macOS 侧的交叉验证（无法运行，仅编译检查）：

```bash
cargo check --target x86_64-pc-windows-gnu   # Rust 侧 Windows 编译验证
```

## 当前限制（后续迭代路线）

| 功能 | 状态 |
|---|---|
| 许可证门禁 | MVP 直接授予完整 entitlement（`clipboard_set_runtime_entitlement(2)`），Ed25519 lease 验证 + 设备绑定需移植（CryptoKit → rust crypto / TPM） |
| 图片缩略图渲染 | 列表显示尺寸标签；WIC 解码渲染后续接入 |
| 图片预览 / 捏合缩放 | 未实现 |
| 原生拖拽 / 文件复制捕获 | 未实现（Windows 需 CF_HDROP + DoDragDrop） |
| 设置界面 | 编辑 `settings.json`（%APPDATA%\CopyAttach\） |
| 忽略规则 UI | Rust 侧规则引擎可用（`clipboard_set_ignore_rules`），前端未接 |
| 前台应用元数据（来源名/图标） | 未接 `clipboard_set_source_app` |
| 自启动 / 开机运行 | 未实现（注册表 Run 键） |

## macOS 构建不受影响

`platform` 抽象层的 macOS 实现由原 `src/macos.rs` 平移而来，`./build.sh` 流程不变；`cargo test`（97 项）在 macOS 上全量通过。
