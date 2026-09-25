# AGENTS.md

CopyAttach 是一个 macOS 剪贴板历史管理器：Rust cdylib 后端（`src/`）+ Swift 6 LSUIElement agent 前端（`SwiftApp/`）+ SQLite 持久化 + 许可证体系。

**`CLAUDE.md` 是本仓库权威的行为规范与架构说明，动手前先读它。** 本文件只列"立刻要用"的命令、边界与不变量，原理与实测数据见文末文档索引。

## 命令

| 目的 | 命令 |
|---|---|
| 完整构建（Rust + Swift + bundle + 签名） | `./build.sh` |
| 压力测试构建 | `STRESS=1 ./build.sh` |
| 仅 Rust release | `cargo build --release` |
| 单元测试 | `cargo test [筛选名]` |
| Lint | `cargo clippy --all-targets -- -D warnings` |
| 推送前一致性门禁（11 项，含 clippy + test） | `bash check_push.sh` |
| 打开应用 | `open "CopyAttach.app"` |
| 看调试日志 | `tail -f /tmp/copyattach_debug.log` |
| 看内存（只认 `Writable regions` 行） | `vmmap -summary $(pgrep -f 'CopyAttach.app/Contents/MacOS/CopyAttach') \| head -16` |

- **没有 `Package.swift`，也没有 `.xcodeproj`**：Swift 由 `build.sh` 里的裸 `swiftc` 编译，源文件用 `find SwiftApp -name '*.swift'` 收集 —— 新增 `.swift` 文件自动入编，不需要改构建脚本。
- `./build.sh` 开头 `rm -rf CopyAttach.app`；版本号从 `Cargo.toml` 注入产物 `Info.plist`（源码 `SwiftApp/Info.plist` 里是恒为 `0.0.0` 的死值，不要改它）；签名身份按 `Developer ID Application|Apple Development` 过滤选取。
- `bash stress_test.sh [--quick|--generate-only|--measure-only|--count N]`（默认 10000 条）**会把真实 `~/Library/Application Support/CopyAttach/history.db` 挪走**（退出时恢复），不要在用户数据上随手跑。
- `[profile.release]` 开了 `lto` + `codegen-units=1`，release 构建慢是正常的。

## 硬性约定

1. **不写兜底。** 主流程失败就显式暴露（返回错误/`0`/`null`、日志 + 空结果），由调用方决定。需要"以防万一"的分支通常说明主流程有 bug。
2. **推导 ≠ 验证。** 报"已修好"必须能回答：改动前在**真实调用路径**上失败、改动后成功，两次都观察到。在隔离环境验证替身不算；并发/竞态类问题要连跑 ≥8 次看失败率，不能以"这一次是绿的"收尾。
3. **观测手段先自证。** 采样点本身可能错（例：现代 macOS 拖拽剪贴板是 `Apple CFPasteboard drag`，读 `NSDragPboard` 恒为空）。先证明它能观测到已知为真的现象，再采信它给出的"没有"。
4. **版本号只允许改末尾 patch 位**（`0.105.11` 里只动 `11`），`105`/`0` 由人决定，需要联动大版本时停下问。开发期带 `-dev` 后缀，发布时去掉；CHANGELOG 纯面向用户、简洁。
5. **改任何大缓冲路径前**先读 `docs/engineering-notes.md` 的 madvise / claim 契约：`mark_pages_reusable` / `claim_pages` 必须成对且页对齐。
6. **不要用覆盖的 `HOME` 启动 GUI。** 钥匙串不可达会弹无关对话框，把结论引向"沙箱读不到钥匙串"的错误方向。只有 `cargo test` 的测试二进制可以覆盖 `HOME`（它不碰钥匙串）。
7. 注释写"为什么"和实测数字，不写复述代码的注释。用户可见字符串是中文，标识符与注释是英文。

## 边界与不变量

- **FFI 三处同步**：`src/ffi/` 用 `#[no_mangle]` 定义（`pub use` 汇出）、`SwiftApp/CopyAttach-Bridging-Header.h` 声明（现有 66 个 `extern "C"`）、`ClipboardBackend.swift` 封装。加接口漏掉任一处就是断链。
- **FFI 边界不许 panic**：`extern "C"` 里 panic 会 abort 整个进程。用 `try_backend()` 返回哨兵值（`0` / `-1` / `null`）。
- **内存所有权**（契约写在 bridging header 注释里）：C 字符串 → `clipboard_free_string`；字节缓冲 → `clipboard_free_bytes`；u64 数组 → `clipboard_free_u64_array`；快照 `acquire`/`release` 成对，且快照内的 `char*` 仍要各自 free；预览缓冲由 Rust 拥有，靠 `PreviewBufferBox.deinit` 释放。**长度为 0 时也必须走 FFI free**（`Data(bytesNoCopy:)` 在 count 为 0 时不保证触发 deallocator）。
- **身份不变量**：条目的稳定身份是 `entry_id`（原子递增、水位持久化，Swift 收藏引用它）；`db_id` 必须按**内容 hash** 赋值，绝不按头部位置。
- **自写抑制**：`select_and_paste` 设 `pending_self_write` 标记，监控线程按**精确匹配的 changeCount** 跳过自身写入。
- `src/ffi/stress.rs` 始终编译，只有内部函数被 feature gate —— release 包里也存在 `clipboard_stress_available`。
- 服务端许可证代码**不在本仓库**（本机 `~/copy-attach-license/`，生产 `api.abovepast.shop`）。

## 文档索引

| 文档 | 内容 |
|---|---|
| [CLAUDE.md](CLAUDE.md) | 权威：行为约定、架构、模块表、各子系统踩坑记录 |
| [docs/engineering-notes.md](docs/engineering-notes.md) | 从 CLAUDE.md 精简时移出的原理与实测数据：DB / 两阶段图片捕获与内存治理 / 预览解码 / 粘贴 / 原生拖拽 / 弹窗 UI / 许可证 / 签名分发 |
| [docs/perf-instrumentation.md](docs/perf-instrumentation.md) | 流畅度仪表的埋点契约、门禁与基线；[perf/BASELINE.md](perf/BASELINE.md) 是已实测基线 |
| [docs/licensing-protocol.md](docs/licensing-protocol.md) | 设备身份、Lease、签名信封、HTTP 端点 |
| [README.md](README.md) | 面向用户的功能、快捷键与设计原则 |
