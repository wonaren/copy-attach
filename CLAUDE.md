# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 行为约定

### 从第一性原理分析代码
分析代码时从第一性原理出发：先理解核心数据流和不变量的本质，再逐层验证具体实现是否忠实于这些原理。不依赖既有注释、命名或架构图作为理解起点——它们可能是过时或错误的。最终目标是确认或修正对系统本质的理解。

### 不要搞兜底实现
不要为实现某个功能编写 fallback / 兜底逻辑。兜底实现会掩盖主流程的错误，让 bug 难以被发现和调试。如果主流程失败，应该让错误显式暴露（panic、返回错误、日志 + 空结果），而不是用降级方案静默吞掉失败。调用方应当能感知到失败并决定如何处理。

## 构建与测试

```bash
# 构建全部（Rust + Swift 应用）
./build.sh

# 仅 Rust release 构建
cargo build --release

# 快速编译检查（不用完整构建）
cargo check

# Lint
cargo clippy

# 运行所有 Rust 测试（可直接运行，不依赖 Swift 端）
cargo test

# 运行单个测试（按名称匹配）
cargo test test_add_text_item
cargo test test_auto_cleanup  # 匹配前缀

# 调试日志
tail -f /tmp/copyattach_debug.log

# 打开应用
open "CopyAttach.app"
```

所有命令在项目根目录执行。构建脚本（[build.sh](build.sh)）流程：
1. `cargo build --release` → 产出 `target/release/libcopy_attach.dylib`
2. sips + iconutil 从 `assets/icon.svg` 生成 AppIcon.icns
3. 拷贝 dylib 到 `CopyAttach.app/Contents/Frameworks/`，设置 `install_name`
4. `swiftc` 编译 SwiftApp 下所有 `.swift` 文件，带 `-import-objc-header` 和 `-lcopy_attach` 链接
5. 拷贝 `Info.plist`，codesign ad-hoc

## Rust 后端模块结构

`cdylib` 库编译为 `libcopy_attach.dylib`。`src/lib.rs` 仅做模块声明，核心逻辑分散在以下模块：

| 模块 | 文件 | 职责 |
|---|---|---|
| `types` | `src/types.rs` | `ClipboardEntry` 枚举（Text/Image），`SourceApp` 元数据，label 生成 |
| `backend` | `src/backend.rs` | `OnceLock<Backend>` 单例，entry_id（`AtomicU64`），常量（3000 阈值、300ms 轮询间隔） |
| `image` | `src/image.rs` | PNG 编解码（`image` crate），Lanczos3 缩略图（最长边 500px），`DefaultHasher` 内容哈希 |
| `history` | `src/history.rs` | `add_to_history()` —— 去重 + 头部插入，纯函数式（返回新 Vec） |
| `db` | `src/db.rs` | SQLite write-through（`rusqlite bundled`），mmap 256MB，512KB page cache，JSON 迁移 |
| `macos` | `src/macos.rs` | NSPasteboard `changeCount`（轻量检测），`CGEventPost` Cmd+V，`AXIsProcessTrusted`。cfg-gated，非 macOS 编译用空桩 |
| `monitor` | `src/monitor.rs` | 后台线程每 300ms 轮询 `arboard`，先 changeCount 再读内容，write-through DB |
| `ffi` | `src/ffi.rs` | 所有 `#[no_mangle] extern "C"` 函数，Snapshot API，select_and_paste，history 管理 |
| `tests` | `src/tests.rs` | 单元测试（cfg-gated） |

### 核心机制

- **剪贴板监控**：后台线程每 300ms 轮询 `arboard`。先用 `macos::pasteboard_change_count()` 轻量检查（避免每次读图片），有变化再读取文本或图片。图片编码为 PNG（`image` crate），缩略图 Lanczos3 缩放至最长边 500px。去重依据文本相等或 `DefaultHasher`（dimensions + raw pixels）。
- **SQLite 持久化**：`~/Library/Application Support/CopyAttach/history.db`，mmap 32MB + 512KB page cache。所有变更 write-through 实时写入（监控线程 + select_and_paste 均写穿），启动时从 DB 加载最近条目。
- **历史管理**：`Arc<Mutex<Vec<ClipboardEntry>>>`，上限 3000（可调，范围 100–10000）。添加时去重，新条目插入头部，超限从尾部 pop。阈值变更即时 trim。
- **paste 模拟**：`CGEventPost` 发 Cmd+V（key code 9），需辅助功能权限（`AXIsProcessTrusted`）。
- **全局状态**：`OnceLock<Backend>` 单例，`backend()` panic 式访问 / `try_backend()` Option 式访问。
- **搜索**：HistoryPopupContent 中 searchText 驱动 filteredItems 过滤，匹配 label 和 sourceName（不区分大小写）。selectedIndex 0 固定为搜索栏，选中搜索栏时自动 focus。搜索结果变更时 selectedIndex 回 0。
- **条目删除**：按住 Control 时选中条目显示删除图标，Control+Delete 键删除。Swift 端通过 `clipboard_delete_by_id(entry_id)` 删除内存和 DB 中的条目。
- **两阶段图片捕获**：Phase 1（同步）— hash + CatmullRom 缩略图（最长边 300px）→ 更新内存历史。Phase 2（异步）— 完整 PNG 编码 → DB write-through → 更新 db_id。避免大幅图片（如 4K 截图）阻塞监控线程。

**Swift 前端**（`SwiftApp/`）—— 纯菜单栏应用（`LSUIElement: true`，无 Dock 图标），SwiftUI + AppKit。

## 关键数据流

参阅 [README.md](README.md) 中的架构 ASCII 图和「一分钟上手」章节，快速理解系统全貌。

```
Rust 监控线程捕获新剪贴板内容（300ms 轮询，先 changeCount 轻量检测）
  ↓ write-through SQLite + 更新内存历史
Swift Timer (0.5s) 轮询 clipboard_get_count()
  ↓ 计数变化
Swift 通过 Snapshot API 批量读取所有条目（单次加锁 clone 整个 Vec，后续无锁读取）
  ↓ 构建 [ClipboardItem] 枚举数组
SwiftUI 渲染 HistoryPopupContent 列表
  ↓ 用户选择条目
clipboard_select_and_paste_by_id() → 写回系统剪贴板 → sleep 50ms → Cmd+V (CGEventPost)
```

### Suppress re-capture 机制
select_and_paste 先设置 `last_seen_text` / `last_seen_image_hash` 再写剪贴板，监控线程发现匹配时跳过，避免自己捕获自己。

## FFI 关键模式

- **Snapshot API**（`clipboard_snapshot_acquire/release`）：Swift 批量读取时，在 Rust 侧一次性加锁 clone 全部历史，后续读取不持有锁。所有 `snapshot_` 前缀函数操作此快照。
- **旧式 API**（`clipboard_get_count`, `clipboard_get_item_text` 等）：每次调用单独加锁，遗留接口，新代码优先用 Snapshot API。
- **所有权规则**：`*_free_string` 释放 Rust 分配的 `*mut c_char`；`*_free_bytes` 释放 Rust 分配的 `*mut u8` 缓冲区（含长度）。
- **图片加载**：缩略图通过 `clipboard_get_image_thumb_by_db_id`（仅 SQLite 读，不碰 history 锁）；大图通过 `clipboard_get_image_full_by_db_id`（优先内存缓存，后备 DB 加载）。
- **稳定 ID**：`entry_id`（`u64`，静态 AtomicU64 单调递增），用于 `select_and_paste_by_id`，避免数组索引竞争。
- **select_and_paste 流程**：查 history（by entry_id）→ 从 DB 加载完整 png_data → 写系统剪贴板（设 last_seen）→ DB write-through（insert + delete + trim，更新 db_id）→ move entry to top of history → sleep 50ms → Cmd+V 模拟。Swift 端统一走 `clipboard_select_and_paste_by_id()`（by-index 变体是遗留接口）。

## Swift 文件职责

| 文件 | 职责 |
|---|---|
| `CopyAttachApp.swift` | App 入口（MenuBarExtra），AppDelegate 管理生命周期（settings window 创建/复用 + 内联设置页面 InlineSettingsView） |
| `ClipboardBackend.swift` | Rust FFI 封装层，`ObservableObject`，定时轮询（0.5s），Snapshot 读取，缩略图缓存（NSCache），`ClipboardItem` 枚举定义，App Icon 缓存 |
| `HistoryPopupView.swift` | `NSPanel` 浮动弹窗（透明背景、圆角），SwiftUI 列表 + 键盘导航（↑↓回车空格Esc），item 行渲染（app 图标、文本截断、图片缩略图） |
| `PreviewWindow.swift` | `NSPanel` 非 key 预览窗口（可跟随弹窗焦点切换），大文本 NSTextView 渲染，图片全尺寸加载 |
| `HotkeyManager.swift` | 全局快捷键管理（Carbon RegisterEventHotKey + NSEvent global monitor 双注册），快捷键录制，`debugLog()` 工具函数 |

**FFI 接口**：`CopyAttach-Bridging-Header.h` 声明约 40 个 `extern "C"` 函数，涵盖生命周期、查询、快照、图片加载、粘贴、权限管理、历史管理等。新功能如需 Rust 向 Swift 暴露调用点，需在此文件添加声明。

**App 类型**：纯菜单栏应用（`Info.plist` 中 `LSUIElement: true`），无 Dock 图标。`-target arm64-apple-macosx15.0` 硬编码在 build.sh 中。

### SwiftUI 模型关系

- `ClipboardBackend.shared` — `@StateObject`，驱动弹窗列表刷新
- `HotkeyManager.shared` — `@ObservedObject`，驱动快捷键显示/录制
- `HistoryPopupWindow.shared` — NSPanel 单例（`.floating` level，`.nonactivatingPanel` style）
- `PreviewWindow` — 每次打开创建新实例，`PreviewContentModel` (`ObservableObject`) 驱动内容更新
- 弹窗关闭时动画顺序：popup 0.15s fade → preview 0.1s fade → close
- **FocusState 双管理**：`isSearchFocused` 和 `isContainerFocused` 两个 FocusState。selectedIndex=0 时 focus 搜索框，selectedIndex>0 时 focus 容器（使 `.onKeyPress` 继续生效）。解决 SwiftUI 中 TextField focus 接管后 onKeyPress 失效的问题。
- **搜索**：`searchText` → `filteredItems` 计算属性（匹配 `label.lowercased()` + `sourceName.lowercased()`）。搜索栏是 index 0，项目从 index 1 开始。搜索变更时 `selectedIndex` 归零。搜索结果滚动通过 `proxy.scrollTo` 定位到第一项。

### 热点键系统（双机制）
- **Carbon RegisterEventHotKey**：需辅助功能权限，应用不在前台时也触发
- **NSEvent global monitor**：补充机制，绕过某些 Carbon API 限制
- 快捷键录制：`NSEvent local monitor` capture → 保存 HotkeyConfig（Codable → UserDefaults）→ 自动 deregister + reregister

### 中文文本视觉截断
`visualWidth()` 函数按 CJK 字符 = 2、ASCII = 1 计算视觉宽度，实现中英文混排的合理截断。`prefix/suffix(whileVisualWidth:)` 用于 ItemRowView 中长文本的 "头……尾" 截断显示。

## Cargo 特性

- `migration`（默认开启）：启用 `serde`/`serde_json`/`base64` 依赖，提供从旧版 `history.json` 到 SQLite 的迁移。
- `default = ["migration"]`：迁移完成后考虑移除。

## 单测

所有 Rust 测试集中在 `src/tests.rs`（cfg-gated）。运行方式：

```bash
# 运行所有测试
cargo test

# 按名称筛选测试
cargo test test_add_text_item          # 精确匹配
cargo test test_auto_cleanup           # 匹配前缀
cargo test test_trim_percent           # 匹配子串
```

测试覆盖：基本添加与顺序、去重（文本/图片/混合）、图片编解码与缩略图、内容哈希一致性、SourceApp 元数据、label 生成（含多字节安全）、FFI 空指针安全、阈值清理（多个阈值 + 边界 + 百分比 trim + ceil 行为）、阈值变更。

## 调试日志

`debugLog()` 函数在 `HotkeyManager.swift` 中，写入 stderr 和 `/tmp/copyattach_debug.log`。Swift 端其他 `print("[ClipboardBackend] ...")` 输出到 stderr。Rust 端通过 `eprintln!` 输出。监控：
```bash
tail -f /tmp/copyattach_debug.log
```

## .claude 配置

`.claude/settings.local.json` 包含命令白名单权限，避免频繁弹 permission 提示。新命令需要时在此文件中添加：

```json
{
  "permissions": {
    "allow": [
      "cargo build --release",
      "cargo test",
      ...
    ]
  }
}
```

## 构建依赖

- macOS 14.0+（Sonoma）
- Xcode 16+（含 macOS SDK 15.0）
- Rust 1.75+

## lib.rs 特性

- `#![allow(dead_code)]` 全局开启，因为部分模块函数仅由 FFI 或 cfg-gated 路径使用。不建议移除。

## 应用图标

`assets/icon.svg` 通过 `sips` 渲染 + `iconutil` 生成 `AppIcon.icns`，构建时自动处理。

## 设计参考

`UI-DESIGN.md` 包含完整的 Apple 风格设计系统（色板、字体层级、间距、圆角、组件）。在涉及 UI 样式调整时参考此文件，而不是从零硬编码颜色值。

## 安装的 Skills

`.claude/skills/` 目录包含多个动画/设计相关的 skill（软链接），可用于 UI 动效分析和改进：
- `apple-design`, `emil-design-eng`: Apple 风格 UI 设计原则
- `animation-vocabulary`, `improve-animations`, `find-animation-opportunities`: 动画分析与改进

## 权限管理

- 在 `.claude/` 目录下维护 `settings.local.json`，包含常用命令的白名单
- 向 `settings.local.json` 的 `permissions.allow` 数组添加新权限，而非创建全局设置
