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

# 仅 Rust 运行测试
cargo test

# 调试日志
tail -f /tmp/copyattach_debug.log

# 打开应用
open "CopyAttach.app"
```

所有命令在项目根目录执行。构建脚本（[build.sh](build.sh)）流程：
1. `cargo build --release` → 产出 `target/release/libcopy_attach.dylib`
2. 拷贝 dylib 到 `CopyAttach.app/Contents/Frameworks/`，设置 `install_name`
3. `swiftc` 编译 SwiftApp 下所有 `.swift` 文件，带 `-import-objc-header` 和 `-lcopy_attach` 链接
4. 拷贝 `Info.plist`，codesign ad-hoc

## 架构概览

**Rust 后端**（[src/lib.rs](src/lib.rs)）—— `cdylib` 类型的库，编译为 `libcopy_attach.dylib`。核心逻辑：

- **剪贴板监控**：后台线程每 300ms 轮询 `arboard` 获取系统剪贴板内容，先检查 NSPasteboard `changeCount`（轻量检测，避免每次读图片），再读取文本或图片。图片通过 `image` crate 编码为 PNG，缩略图缩放至最长边 300px。去重依据文本相等或图片哈希（`DefaultHasher`）。
- **SQLite 持久化**（`rusqlite bundled`）：`~/Library/Application Support/CopyAttach/history.db`，mmap 读取 BLOB，512KB page cache。所有变更通过 write-through 策略实时写入 DB（监控线程 + `select_and_paste` 均写穿），启动时从 DB 加载最多 3000 条记录。
- **历史管理**：`Arc<Mutex<Vec<ClipboardEntry>>>` 最多 1000 条。添加时去重（相同文本/哈希的旧条目被移除），新条目插入头部。
- **paste 模拟**：通过 `CGEventPost` 发送 Cmd+V，需要辅助功能权限（`AXIsProcessTrusted` 检查）。
- **全局状态**：`OnceLock<Backend>` 单例，所有 FFI 函数通过 `backend()` 访问。

**Swift 前端**（[SwiftApp/](SwiftApp/)）—— 纯菜单栏应用（`LSUIElement: true`），SwiftUI + AppKit。

## 关键数据流

```
Rust 监控线程捕获新剪贴板内容
  ↓ 写穿 SQLite + 更新内存历史
Swift Timer (0.5s) 轮询 clipboard_get_count()
  ↓ 计数变化
Swift 通过 Snapshot API 批量读取所有条目（单次加锁，免竞争）
  ↓ 构建 [ClipboardItem] 数组
SwiftUI 渲染 HistoryPopupContent
  ↓ 用户选择条目
clipboard_select_and_paste_by_id() → 写回系统剪贴板 → sleep 50ms → Cmd+V
```

## FFI 关键模式

- **Snapshot API**（`clipboard_snapshot_acquire/release`）：Swift 批量读取时，在 Rust 侧一次性加锁 clone 全部历史，后续读取不持有锁。所有 `snapshot_` 前缀函数操作此快照。
- **旧式 API**（`clipboard_get_count`, `clipboard_get_item_text` 等）：每次调用单独加锁，遗留接口，新代码优先用 Snapshot API。
- **所有权规则**：`*_free_string` 释放 Rust 分配的 `*mut c_char`；`*_free_bytes` 释放 Rust 分配的 `*mut u8` 缓冲区（含长度）。
- **图片加载**：缩略图通过 `clipboard_get_image_thumb_by_db_id`（仅 SQLite 读，不碰 history 锁）；大图通过 `clipboard_get_image_full`（优先内存缓存，后备 DB 加载）。
- **稳定 ID**：`entry_id`（`u64`）单调递增，用于 select_and_paste_by_id，避免数组索引竞争。

## Cargo 特性

- `migration`（默认开启）：启用 `serde`/`serde_json`/`base64` 依赖，提供从旧版 `history.json` 到 SQLite 的迁移。
- `default = ["migration"]`：迁移完成后考虑移除。

## 调试日志

`debugLog()` 函数在 [HotkeyManager.swift](SwiftApp/HotkeyManager.swift) 中，写入 stderr 和 `/tmp/copyattach_debug.log`。Swift 端其他 `print("[ClipboardBackend] ...")` 也输出到 stderr。Rust 端通过 `eprintln!` 输出。监控：
```bash
tail -f /tmp/copyattach_debug.log
```

## 应用图标

`assets/icon.svg` 通过 `sips` 渲染 + `iconutil` 生成 `AppIcon.icns`，构建时自动处理。
