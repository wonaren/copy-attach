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

# 仅 Rust 运行测试（可直接运行，不依赖 Swift 端）
cargo test

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

## 架构概览

**Rust 后端**（`src/lib.rs`，1786 行）—— `cdylib` 类型的库，编译为 `libcopy_attach.dylib`。核心逻辑：

- **剪贴板监控**：后台线程每 300ms 轮询 `arboard` 获取系统剪贴板内容，先检查 NSPasteboard `changeCount`（轻量检测，避免每次读图片），再读取文本或图片。图片通过 `image` crate 编码为 PNG，缩略图缩放至最长边 300px（Lanczos3）。去重依据文本相等或图片哈希（`DefaultHasher`，含 dimensions + raw pixels）。
- **SQLite 持久化**（`rusqlite bundled`）：`~/Library/Application Support/CopyAttach/history.db`，mmap 读取 BLOB（256MB mmap_size），512KB page cache。所有变更通过 write-through 策略实时写入 DB（监控线程 + select_and_paste 均写穿），启动时从 DB 加载最多 3000 条记录。
- **历史管理**：`Arc<Mutex<Vec<ClipboardEntry>>>` 最多 3000 条。添加时去重（相同文本/哈希的旧条目被移除），新条目插入头部。超过阈值时从尾部 pop。
- **paste 模拟**：通过 `CGEventPost` 发送 Cmd+V，需要辅助功能权限（`AXIsProcessTrusted` 检查）。
- **全局状态**：`OnceLock<Backend>` 单例，所有 FFI 函数通过 `backend()` 访问。

**Swift 前端**（`SwiftApp/`）—— 纯菜单栏应用（`LSUIElement: true`，无 Dock 图标），SwiftUI + AppKit。

## 关键数据流

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
- **select_and_paste 流程**：查 history（by index 或 entry_id）→ 从 DB 加载完整 png_data → 写系统剪贴板（设 last_seen）→ DB write-through（insert + delete + trim，更新 db_id）→ move entry to top of history → sleep 50ms → Cmd+V 模拟。

## Swift 文件职责

| 文件 | 职责 |
|---|---|
| `CopyAttachApp.swift` | App 入口（MenuBarExtra），AppDelegate 管理生命周期（settings window 创建/复用） |
| `ClipboardBackend.swift` | Rust FFI 封装层，`ObservableObject`，定时轮询（0.5s），Snapshot 读取，缩略图缓存（NSCache），`ClipboardItem` 枚举定义 |
| `HistoryPopupView.swift` | `NSPanel` 浮动弹窗（透明背景、圆角），SwiftUI 列表 + 键盘导航（↑↓回车空格Esc），item 行渲染（app 图标、文本截断、图片缩略图） |
| `PreviewWindow.swift` | `NSPanel` 非 key 预览窗口（可跟随弹窗焦点切换），大文本 NSTextView 渲染，图片全尺寸加载 |
| `HotkeyManager.swift` | 全局快捷键管理（Carbon RegisterEventHotKey + NSEvent global monitor 双注册），快捷键录制，`debugLog()` 工具函数 |

### SwiftUI 模型关系

- `ClipboardBackend.shared` — `@StateObject`，驱动弹窗列表刷新
- `HotkeyManager.shared` — `@ObservedObject`，驱动快捷键显示/录制
- `HistoryPopupWindow.shared` — NSPanel 单例（`.floating` level，`.nonactivatingPanel` style）
- `PreviewWindow` — 每次打开创建新实例，`PreviewContentModel` (`ObservableObject`) 驱动内容更新
- 弹窗关闭时动画顺序：popup 0.15s fade → preview 0.1s fade → close

### 热点键系统（双机制）
- **Carbon RegisterEventHotKey**：需辅助功能权限，应用不在前台时也触发
- **NSEvent global monitor**：补充机制，绕过某些 Carbon API 限制
- 快捷键录制：`NSEvent local monitor` capture → 保存 HotkeyConfig（Codable → UserDefaults）→ 自动 deregister + reregister

### 中文文本视觉截断
`visualWidth()` 函数按 CJK 字符 = 2、ASCII = 1 计算视觉宽度，实现中英文混排的合理截断。`prefix/suffix(whileVisualWidth:)` 用于 ItemRowView 中长文本的 "头……尾" 截断显示。

## Cargo 特性

- `migration`（默认开启）：启用 `serde`/`serde_json`/`base64` 依赖，提供从旧版 `history.json` 到 SQLite 的迁移。
- `default = ["migration"]`：迁移完成后考虑移除。

## 单测清单（Rust）

`cargo test` 运行以下测试（均在 `src/lib.rs` 的 `mod tests` 中）：
- `test_add_text_item` / `test_add_multiple_items_order` — 基本添加与顺序
- `test_text_deduplication` / `test_image_deduplication` — 去重（保留新条目）
- `test_text_and_image_mixed` — 混合类型
- `test_encode_decode_png` / `test_create_thumbnail` / `test_image_hash_consistency` / `test_image_hash_different` — 图片处理
- `test_source_app_fields` / `test_item_types` / `test_item_timestamps` — 元数据
- `test_label_text` / `test_label_image` / `test_label_multibyte` — label 生成（多字节安全）
- `test_free_string_null_safe` — null 释放安全

## 调试日志

`debugLog()` 函数在 `HotkeyManager.swift` 中，写入 stderr 和 `/tmp/copyattach_debug.log`。Swift 端其他 `print("[ClipboardBackend] ...")` 输出到 stderr。Rust 端通过 `eprintln!` 输出。监控：
```bash
tail -f /tmp/copyattach_debug.log
```

## 应用图标

`assets/icon.svg` 通过 `sips` 渲染 + `iconutil` 生成 `AppIcon.icns`，构建时自动处理。

## 权限管理

- 在 `.claude/` 目录下维护 `settings.local.json`，包含常用命令的白名单
- 向 `settings.local.json` 的 `permissions.allow` 数组添加新权限，而非创建全局设置
