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

# 启用 stress-test feature 构建（生成 1 万条测试数据）
STRESS=1 ./build.sh

# 仅 Rust release 构建
cargo build --release

# 带 stress-test feature 的 Rust 构建
cargo build --release --features stress-test

# 快速编译检查
cargo check

# Lint
cargo clippy

# 运行所有 Rust 测试
cargo test

# 按名称匹配测试
cargo test test_add_text_item
cargo test test_auto_cleanup   # 前缀匹配

# stress-gen CLI（需 stress-test feature）
cargo run --bin stress-gen --features stress-test -- --help

# bench CLI（需 stress-test feature）
cargo run --bin bench --features stress-test

# 压力测试编排（生成数据 → 部署 DB → 启动 App → 采集内存/CPU/功耗/冷启动指标，报告到 /tmp）
bash stress_test.sh                 # 完整 10000 条
bash stress_test.sh --quick         # 1000 条快速测试
bash stress_test.sh --generate-only # 仅生成数据到 /tmp/copyattach_stress.db
bash stress_test.sh --measure-only  # 用现有 DB 仅采集指标

# 调试日志（Swift debugLog + Rust eprintln 均落盘）
tail -f /tmp/copyattach_debug.log
# AppDelegate 启动时 dup2 stderr → 日志文件，Rust 侧任何 DB 失败/守卫拒绝可见

# 打开应用
open "CopyAttach.app"
```

build.sh 流程：读取 `Cargo.toml` 版本号 → 通过 PlistBuddy 同步到 `Info.plist`（只需在 Cargo.toml 中改版本） → `cargo build --release` → sips + iconutil 生成图标 → 拷贝 dylib + 设置 install_name → `swiftc` 编译 SwiftApp 下所有 `.swift`（带 FFI 桥接头，**`-O -whole-module-optimization`——发布必须是优化构建，缺省 `-Onone` 会让 SwiftUI 前端全速跑在未优化代码上**） → codesign（优先用已安装的 Apple Development 身份，无身份时回退 ad-hoc）。

**版本号约定**：每次功能/修复提交都在 `Cargo.toml` 中提升 `version` 并写入提交信息（习惯写法「版本号升至 X.Y.Z」）；开发中的版本带 `-dev` 后缀（如 `0.93.0-dev`），发布版本去掉后缀。`build.sh` 以 `Cargo.toml` 为唯一版本来源同步到 `Info.plist` 的 `CFBundleShortVersionString`。

### 生产构建（连接生产 License Server）

生产配置已内置为默认值：直接 `./build.sh` 即连接生产服务器，无需环境变量。可通过环境变量覆盖，本地开发用 `LICENSE_ENV=local` 指向 `127.0.0.1:8787` 并传入本地 dev 公钥：

> license-server 服务端代码**不在本仓库**，是独立部署（本机开发部署在 `~/copy-attach-license/`，生产在 `api.abovepast.shop`）。本仓库只含客户端验证与请求逻辑（`SwiftApp/Licensing/`）。本地联调前需自行启动一个 license-server 并取得其 dev 公钥。

```bash
# 默认（生产）：无需任何环境变量
./build.sh

# 本地开发
LICENSE_ENV=local COPYATTACH_LICENSE_PUBLIC_KEY='<license-server 启动时输出的 dev 公钥>' ./build.sh

# 显式覆盖生产参数
COPYATTACH_LICENSE_SERVER_URL='https://api.abovepast.shop' \
COPYATTACH_LICENSE_KEY_ID='production-2026-08' \
COPYATTACH_LICENSE_PUBLIC_KEY='efsKYx9a7urNlr-UXR7b0-Fl9w0mJNKe3RME-OeseOs' \
./build.sh
```

参数写入 App bundle 的 `Info.plist`（`CopyAttachLicenseServerURL/KeyID/PublicKey`），源码里的 `Info.plist` 不保留这些值（构建后回删）；代码侧 `LicenseConfiguration`（`LicenseLeaseVerifier.swift`）保留同一套生产值作为回退。公钥与 license-server 的 `data/production-signing.key` 一一对应；App 用 CryptoKit Ed25519 验证服务器签发 lease 的签名（`LicenseLeaseVerifier.swift`）。协议细节（接口清单、签名信封、challenge 续租）见 `docs/licensing-protocol.md`。

## 代码库架构

### Rust 后端（`src/`，cdylib + rlib → `libcopy_attach.dylib`）

| 模块 | 职责 |
|---|---|
| `ffi/` | 所有 `#[no_mangle] extern "C"` 导出函数（目录模块）：`snapshot.rs`(Snapshot API)、`search.rs`、`init.rs`(生命周期/ignore rules)、`accessors.rs`(索引访问/图片加载/存储权限)、`paste.rs`(select_and_paste)、`history.rs`(删除/撤销/trim)、`stress.rs`(cfg-gated)。`mod.rs` 持共享助手并 `pub(crate) use` 重导出保持 `crate::ffi::*` 路径 |
| `tests/` | 单元测试（cfg-gated），按主题拆分子模块：history/image/search/cleanup/db/backend；共享 helpers 在 `mod.rs`。覆盖：去重/顺序/图片编解码/FFI 安全/阈值清理/边界值/ignore rules |
| `db/` | SQLite write-through（rusqlite bundled），目录模块：`schema.rs`(连接/建表/FTS5 索引/元数据回填)、`crud.rs`(load/insert/dedup/trim + `persist_entry_to_db` 单事务写穿)、`migration.rs`(legacy JSON)、`search.rs`(FTS/LIKE/text 加载)。**禁用 mmap + 4MB LRU page cache**（`cache_size=-4096`，负数按 KiB 计 = 4MB；FTS5 trigram 索引若被 mmap 会整段计入驻留内存，实测 ~1:1 RSS 膨胀，故全部走有界页缓存）。**FTS 索引尺寸上限（0.99.16）**：`FTS_MAX_INDEXED_TEXT_LEN`（512K 字符）以上的 text 行不建 trigram 索引——实测索引放大 ~6.4×（10.6MB 文本 → 68MB DB）、2MB 文本同步插入 ~170ms，无上限会让大文本把捕获路径卡数百 ms 且 DB 无界膨胀；不入索引的行在 ≥3 字符查询时由 `db::search_history` 走 LIKE 兜底（只扫罕见的超大行，子串语义不丢，见 `test_fts_cap_skips_huge_text` 绊线）；触发器以 DROP+CREATE 替换旧版无上限触发器（触发器按库持久化，IF NOT EXISTS 不会更新存量），启动时清理存量超大行（幂等，`test_fts_cap_legacy_oversized_rows_evicted` 覆盖）。**WAL + `synchronous=NORMAL`**：捕获/粘贴的 insert+dedup+trim 合并为 `persist_entry_to_db` 单事务一次 WAL append（1 次 fsync 而非 3 次），读（搜索/缩略图）不再被写阻塞。**text 行持久化 preview/label/text_hash**（`hash` 列复用作 text_hash，**算法为稳定 FNV-1a 64**——std `DefaultHasher` 文档不保证跨版本稳定，持久化后若漂移会让旧行去重失配；`ensure_history_table` 以 `PRAGMA user_version` 门控：0=旧库 text 逐行回填、1=0.99.15-dev 的 DefaultHasher text 值全量重算、2=text 已 FNV（同步盖 2）、3=text+image 全 FNV）——冷启动 `load_history_from_db` **只读元数据列、绝不读 `text` 列**；无 preview 的 text 行视为未回填损坏，显式跳过并日志（不回读 text 兜底）。**图片 hash 同为 FNV-1a（`types::fnv1a`）**，旧 DefaultHasher 值的迁移（user_version 2→3）在 `ffi::init::spawn_image_hash_migration` **后台线程逐行解码重算**（`schema::migrate_one_image_row`：一次只锁 DB 一行、解码在锁内逐行进行，捕获只等单行解码而非整库；每行完成后同步镜像进内存条目，同会话重复复制即时去重；完成盖 3，中断幂等重跑，不可解码行显式计数不阻塞盖章；stress-test 构建跳过——其 DB 全部新生成）。**dedup/trim 索引化**：`idx_history_type_hash(entry_type, hash)` 使 `delete_matching_entry` 从全表扫描变索引查找（text 仍带 exact-text 谓词兜底防 2⁻⁶⁴ 碰撞误删），`trim_db_history` 改为 `id <= (SELECT id ... OFFSET ?)` 范围删除——只触达被删行，表内 ≤阈值时子查询为 NULL 完全不扫描（原 `NOT IN` 形态每次捕获全表扫描）。**`migrate_from_json_to_db` 插入的旧 JSON 行同步盖 `entry_id = rowid`**——ensure 的 entry_id 回填先于迁移执行，迁移行若不盖章则每次加载都换新 ID（收藏按 entry_id 存储，重启即失效）；迁移体参数化目录（`migrate_from_json_to_db_at`，test-only 重导出），回归测试用临时目录 |
| `monitor.rs` | 后台线程每 300ms 轮询 arboard，先 `changeCount` 轻量检测再读内容，write-through DB，ignore rules 过滤，Finder 文件复制支持。文本捕获 db_id 赋值按**内容 hash 匹配**（`history::assign_db_id_by_text_hash`，与图片 Phase 2 对称，绝不按头部位置） |
| `ignore.rs` | 捕获时忽略规则：按 app bundle ID、文本/图片类型、短文本阈值（Unicode scalar count）过滤。规则在插入前求值 |
| `stress/` | 应力测试数据生成与基准测试，feature-gated behind `stress-test`（不在 release 构建中发布）。目录模块：`text.rs`/`image.rs`(内容生成)、`inject.rs`(DB 注入 + FFI/bench 助手)。生成 1 万条混合文本/图片数据 |
| `types.rs` | `ClipboardEntry` 枚举（Text/Image），`SourceApp` 元数据，label 生成 |
| `image.rs` | PNG/JPEG/GIF/WebP/BMP/TIFF 编解码，CatmullRom 缩略图（最长边 300px），**内容哈希为稳定 FNV-1a 64**（`types::fnv1a`，与 text_hash 同算法同理由——持久化值不依赖 std 不保证跨版本稳定的 `DefaultHasher`） |
| `backend.rs` | `OnceLock<Backend>` 单例，entry_id（`AtomicU64`），常量（3000 阈值、300ms 轮询间隔），`HISTORY_REVISION`/`IMAGE_ENCODING_COUNTER` 原子计数器，`PendingSelfWrite` 自写抑制，`reload_history_from_db` |
| `macos.rs` | NSPasteboard `changeCount` + 文件 URL 读写（`set_pasteboard_file_url`），CGEventPost Cmd+V / Ctrl+V，AXIsProcessTrusted，文件复制检测。cfg-gated，非 macOS 用空桩 |
| `history.rs` | `add_to_history()` — 去重 + 头部插入，纯函数式（返回新 Vec） |
| `bench_tests/` | 性能基准测试（cfg-gated on `test` + `stress-test`），目录模块：`thresholds.rs`/`images.rs`/`memory_probe.rs`，共享测量助手在 `mod.rs`。覆盖：历史阈值扩展性、图片捕获/编码/缩略图性能、DB 存储规模测试 |
| `lib.rs` | 仅模块声明，`#![allow(dead_code)]` 全局开启 |

**`src/bin/stress_gen.rs`**：独立的 CLI 二进制，通过 Rust FFI 生成应力测试数据并写入 SQLite。需要 `stress-test` feature。

**`src/bin/bench.rs`**：独立的性能基准 CLI，测试快照克隆、计数、图片编解码、CJK 搜索过滤。需要 `stress-test` feature。

**关键机制**：
- **两阶段图片捕获**：Phase 1 同步 hash + CatmullRom 缩略图（最长边 300px）→ 更新内存。Phase 2 异步完整 PNG 编码 → DB write-through → 更新 db_id。避免 4K 截图阻塞监控线程。**内存治理（0.99.10）**：① 启动不做基线剪贴板读取——monitor 的 changeCount seed 已防止重启重复捕获，删除该读取消除了每次启动解码当前剪贴板图片的 ~65MB 滞留（`clipboard_init` 曾用 arboard 解码，实测空剪贴板启动 15MB vs 截图在板 93MB）；② 图片捕获不走 arboard（其 macOS 实现只读 `public.tiff`，22.5MB/张），改由 `macos::pasteboard_image_data()` 按 PNG→TIFF→JPEG→GIF→WebP→BMP 顺序读最小全分辨率表示（截图 PNG 仅 ~1MB）+ `image` crate 解码（CFData 释放后大块滞留 OS 不回收——实测 `malloc_zone_pressure_relief` 对之无效，故无此调用）；③ rgba 以所有权移入 Phase 2（零拷贝，原 `to_vec()` 16MB/张）；④ Phase 2 编码输出复用全局 scratch（`backend::ImageEncodeScratchGuard`，跨捕获保留容量，消灭每次 8MB 倍增 realloc 链；RAII drop 时若容量超过 64MB 保留上限则整池归还——一次超大图编码不得把峰值容量钉到进程退出）。
- **Suppress re-capture**：select_and_paste 先通过 `pasteboard_event_lock` + `pending_self_write` 标记自身的粘贴板写入，监控线程发现匹配的 changeCount 时跳过。不再依赖内容比对。
- **HISTORY_REVISION**：去重时条目数不变但顺序变了——UI 通过此计数器感知"需要刷新列表"而不仅仅是 count 变化。
- **Ignore rules**：捕获时求值，在条目分配/插入/持久化之前过滤。App 匹配使用 bundle identifier（显示名可变，不可靠）。
- **undo 删除**：通过 `clipboard_last_restored_id()` 精确定位恢复项，避免监控线程插入竞争。撤销栈 `push_deleted` 双上限：最多 `DELETE_STACK_LIMIT`(10) 条 + 总字节 `MAX_UNDO_BYTES`(48MB，**文本正文与图片 png+thumb blob 统一计入**——撤销栈是唯一能累积完整载荷的地方，图片不计数曾可无界钉住数百 MB，直到进程退出)——超大文本粘贴/超大图片被删后不得在栈里钉住内存；正常条目远低于上限，只有超大载荷提前淘汰最老槽位（与单条超限文本本就不可撤销的既有语义对称）。`clipboard_delete_by_id` 入栈为**移动语义**（原 `entry.clone()` 每次删除多一次全 PNG memcpy，峰值翻倍）。
- **原生拖拽**：历史条目支持拖到其他应用。文本→`NSItemProvider(object:)`，图片→临时 PNG 文件 (`public.file-url`)。窗口拖动区限制为 PopupHostingView 外 3pt 边框，避免行拖拽误触窗口移动。拖拽结束检测用 **`NSEvent.pressedMouseButtons` 轮询**（40ms Timer，注册 `.common` + `.eventTracking` 双 run loop 模式）——拖拽期间 run loop 处于 `NSEventTrackingRunLoopMode`，global/local monitor 收不到 mouse-up（官方文档确认该模式限制事件投递），Timer 是可靠信号。**拖拽在途时弹窗智能防遮挡停车**（`tickDragParking`，与松手检测共用同一个 40ms watcher tick）：每 tick 累积鼠标横向位移，累计 ≥`dragOcclusionThreshold`(40pt) 即停靠到拖拽方向对侧的屏幕边缘（右拖停左、左拖停右），绝不遮挡落点；方向在每 tick 连续重估，停靠后反向位移 ≥40pt 即翻转到另一侧边缘（停靠后同向漂移用 min/max 钳制、不计入反向累积——否则长同向行程后的部分反向需超过整段行程才能翻转，弹窗会停在正好盖住新落点的旧边缘）。`park(at:)` 用 `animator().setFrame` 驱动滑动（无边框 NSPanel 上 `setFrameOrigin` 静默不动画，`setFrame` 才真正滑动）；`tickParkingSlide` 侦测 CA 事务停顿（事件跟踪模式下帧动画可能卡死，3 tick 无位移即 `setFrameOrigin` 直接落位）。拖拽结束时开关关闭（保持弹窗开启）走 `restoreFromParking()` 滑回居中；开启走下面「拖拽后自动关闭」的 `close()` 路径。`show()`/`close()`/`completeItemDrag` 均 `resetDragParking()`，防停靠状态跨开闭循环残留。开关「拖拽后自动关闭弹窗」（`ClosePopupAfterDrag`，默认开，`object(forKey:) as? Bool ?? true`）开启时，拖拽结束（松手或弹窗失 key）**直接 `close()`——与按 Esc 相同的关闭路径**，无动画、无 completion 依赖；关闭时保持弹窗开启可连续拖拽，下一次外部点击（global click monitor）正常关闭。
- **db_id 不变量（幽灵条目根修，0.99.13）**：内存条目的 `db_id` 必须指向 DB 中该条目的行，且赋值必须**按内容身份匹配、绝不按头部位置**——文本捕获 Scope 2 曾用 `hist.get_mut(0)` 无条件写头部条目（图片 Phase 2 一直按 hash 匹配，不对称）：并发 select-and-paste/undo 在 Scope 1 释放 history 锁后把别的条目移到头部时，本次捕获条目 db_id 保持 0（列表可见但无法预览/粘贴/**删除被拒**——`clipboard_delete_by_id` 对 db_id=0 文本显式拒绝，幽灵删不掉，重启后才消失），头部条目被指向他人行，后续删除会**误删该条目的行**（实测 symptom：DB 主表+FTS 双查无此文本、entry_id 连续缺失）。修复：`history::assign_db_id_by_text_hash` 按 hash 匹配赋值（与图片对称），3 个回归测试覆盖头部竞争/头部正常/无匹配 no-op。交叉验证过全部交错路径：paste/undo 的 add_to_history 去重会移除同文本条目，修复后两条路径自洽，无需其他改动。**配套**：Rust eprintln 此前被 launchd 丢弃（DebugLog 只拦 Swift 侧），所有 DB 失败静默——AppDelegate 启动 `dup2` stderr → `/tmp/copyattach_debug.log`，Rust 侧失败从此可见（符合「失败显式暴露」哲学）。
- **Cargo 特性**：`migration`（默认开启）启用 serde/base64 依赖，提供旧版 history.json → SQLite 迁移。`stress-test` 启用应力测试面板和 CLI。

### Swift 前端（`SwiftApp/`，LSUIElement agent app——无 Dock 图标）

**LSUIElement agent app 的本质**：`Info.plist` 设 `LSUIElement=true`，CopyAttach 是**无 Dock 图标的 agent 应用**，只以 MenuBarExtra（菜单栏图标）+ 浮动 NSPanel 存在。级联后果：① 它不是合法粘贴目标——`CGEventPostToPid` 的目标 pid 绝不能是自身（见「粘贴目标 pid 不变式」）；② nonactivating panel 上浮期间 agent 收不到 `applicationDidBecomeActive`、`NSApp.isActive` 误报 true，预览捏合手势需 `NSApp.activate(ignoringOtherApps:)` 真实激活；③ 唯一有边框的窗口是许可证门禁窗（LicenseGateView），其余都是无边框 NSPanel。

```
SwiftApp/
  ├── CopyAttachApp.swift              ← @main, MenuBarExtra（含「许可证…」菜单入口）
  ├── ClipboardBackend.swift           ← Rust FFI 封装，@Observable，快照轮询/缓存
  ├── HotkeyManager.swift              ← Carbon + NSEvent 双注册，录制模式
  ├── ColorTheme.swift                 ← 深色/浅色 AppTheme 颜色体系
  │
  ├── Licensing/                       ← 许可证体系（激活/试用/Lease 验证/续租/庆祝动画）
  │   ├── LicenseManager.swift         ← 状态机 + 激活/试用/续租；celebration 发布激活成功
  │   ├── LicenseGateView.swift        ← 强制激活窗口（固定 500×470），窗口内播庆祝
  │   ├── LicenseCelebrationView.swift ← 激活庆祝动画（TimelineView+Canvas，粒子从左右下角沿贝塞尔弧线向斜上喷射，约 2s）
  │   ├── LicenseModels.swift          ← EntitlementState 状态机 + CelebrationInfo + SignedLease/LeasePayload
  │   ├── LicenseAPIClient.swift       ← /v1/* 客户端（activate/trial/challenge/refresh/deactivate/status）
  │   ├── LicenseLeaseVerifier.swift   ← CryptoKit Ed25519 验证服务器签名
  │   ├── LicenseRefreshSchedule.swift ← Lease 半程续租调度
  │   ├── LicenseSettingsView.swift    ← 许可证设置页（永久权益不显示「下次联网验证期限」）
  │   ├── LicenseSelfTests.swift       ← 自测（COPYATTACH_LICENSE_SELF_TEST=1）
  │   ├── DeviceIdentity.swift         ← Secure Enclave P-256 设备身份 + hardware_anchor
  │   └── KeychainStore.swift          ← keychain 读写（svce=com.example.copyattach.licensing）
  │
  ├── App/AppDelegate.swift            ← 生命周期, 弹窗/设置窗口管理, entitlement 门控, 庆祝时序, 启动时 dup2 stderr → 调试日志
  │
  ├── Settings/
  │   └── InlineSettingsView.swift     ← 5 标签页设置面板（通用/快捷键/存储/忽略/关于）
  │
  ├── Popup/
  │   ├── HistoryPopupContent.swift    ← 主内容：搜索/列表/预览/Undo，日期分组
  │   ├── HistoryPopupWindow.swift     ← NSPanel 浮动弹窗，开/关动画与拖拽生命周期管理
  │   ├── PopupHostingView.swift       ← 键盘事件拦截（箭头/⌘Z/⌃⌫/⌥P/IME/Esc）
  │   ├── ItemRowView.swift            ← 条目行：文本截断/十六进制色票/图片缩略图（缩略图异步解码，`.task(id: dbId)` 不占主线程）
  │   ├── DateSeparatorView.swift      ← 按日历日分组的分隔符视图
  │   ├── LargeTextView.swift          ← NSTextView 大文本渲染
  │   └── ClipboardDragProvider.swift  ← 原生拖拽：文本→NSString，图片→tmp PNG→fileURL
  │
  ├── Preview/
  │   ├── PreviewWindow.swift          ← 非 key 预览 NSPanel，自适应大小
  │   ├── PreviewContent.swift         ← 预览内容（文本/图片异步加载；图片走 ImageIO 降采样解码）
  │   ├── PreviewTextLayout.swift      ← 等宽字体 14pt + 行间距 5pt，高度测量
  │   └── ZoomableImageView.swift      ← 捏合缩放/平移/双击重置
  │
  ├── Backend/
  │   ├── ClipboardItem.swift          ← 条目枚举（text/image, Identifiable）
  │   ├── ImageDecode.swift            ← 离主线程解码助手：`DecodedImage`（@unchecked Sendable 盒）+ `ImageDecode.previewImage`（ImageIO 降采样：解码预算 = 显示尺寸×scale 与 2048px 缩放余量的较小值，GIF 保动画）
  │   └── AppIcon+Ext.swift            ← NSImage 扩展 + bundleId → 36pt 单尺寸图标缓存（NSWorkspace 图标多尺寸全量可达数百 KB/张，18pt 行只用 36px，缓存前降采样）
  │
  ├── Hotkey/
  │   └── HotkeyConfig.swift           ← Codable 配置，UserDefaults 持久化
  │
  ├── Stress/
  │   ├── StressTestPanel.swift        ← 应力测试 SwiftUI 面板
  │   └── StressTestViewModel.swift    ← 应力测试 ViewModel
  │
  ├── SyntaxHighlight/                 ← 语法高亮（预留，当前为空目录）
  │
  └── Utility/
      ├── DebugLog.swift               ← Swift debugLog 写 /tmp/copyattach_debug.log（stderr 已 dup2 到同一文件，Rust eprintln 也落盘）
      └── VisualWidth.swift            ← CJK=2/ASCII=1 视觉宽度，prefix/suffix 截断
```

**关键 FFI 模式**：
- **Snapshot API**（`clipboard_snapshot_acquire/release`）：Swift 批量读取时一次性加锁构建**紧凑快照**（`SnapshotRow`：类型/id/时间戳/label/source/图片尺寸 + preview，**不含全文**），后续 `snapshot_` 函数无锁访问。避免深克隆 Vec（含全文）造成的刷新瞬态峰值。新功能优先用此 API。
- **稳定 ID**：`entry_id`（u64，AtomicU64 单调递增），用于 `select_and_paste_by_id`，避免数组索引竞争。
- **所有权规则**：`*_free_string` 释放 Rust 分配的 `*mut c_char`；`*_free_bytes` 释放 `*mut u8` 缓冲区（含长度）。
- **图片加载**：缩略图走 `clipboard_get_image_thumb_by_db_id`（仅 SQLite 读，不碰 history 锁）；大图走 `clipboard_get_image_full_by_db_id`（优先内存缓存，后备 DB）。**解码一律离主线程（0.99.16）**：列表行缩略图经 `ClipboardBackend.loadThumbnail`（Task.detached 内 FFI 读 + PNG 解码 → 写回 10MB NSCache），行 body 只做同步 NSCache 命中检查（`cachedThumbnail`，零 IO）——滚动不再有主线程 DB/解码串行工作；预览大图经 `ImageDecode.previewImage`（ImageIO 降采样，解码预算 = 显示尺寸×scale 与 2048px 缩放余量的较小值，`kCGImageSourceShouldCacheImmediately` 保证解码发生在 detached task 内而非首帧绘制，GIF 走 `NSImage(data:)` 保动画）。
- **select_and_paste 流程**：先查 accessibility 权限（`macos::check_permission`），未授权直接 return 0 且**不动剪贴板**——Cmd+V 无权限必然失败，先覆盖用户剪贴板只会毁掉其内容（临时 PNG 60s 后被 TTL 清理成死路径），且旧逻辑 fall-through 返回 1 被 Swift 误判为粘贴成功并关闭弹窗 → 查 history（by entry_id）→ DB 加载 png_data（**加载失败显式 return 0 + 日志，不用内存副本兜底**——内存条目不持 PNG blob，静默降级只会掩盖 DB 故障）→ 写系统剪贴板（设 pending_self_write）→ DB write-through（insert/delete/trim，更新 db_id）→ move entry to top → sleep 50ms → Cmd+V。**图片粘贴走唯一的拖拽同款文件路径模式**：图片一律先写入 `$TMPDIR/CopyAttach/Paste/` 临时 PNG，剪贴板只放 `public.file-url`（Finder「复制文件」同款约定，`macos::set_pasteboard_file_url`）再 Cmd+V——终端将其翻译为路径文本，Claude Code 等 TUI Agent 直接消费，聊天/笔记类 app 粘贴为文件；不再区分终端与非终端，无开关。
- **粘贴目标 pid 不变式**：Cmd+V 用 `CGEventPostToPid` 投递给 `source_app.pid`（`clipboard_set_source_app` 由 Swift 事件驱动更新：`NSWorkspace.didActivateApplicationNotification` + 启动时种子值——0.99.11 起不再 0.3s 轮询，每次 `NSRunningApplication` 属性访问都触发 LaunchServices 同步 XPC，实测 10 小时轮询在 LS 客户端累积 ~115MB（2KB 节点 × 5 万）；app 切换是低频事件，通知恰好在源变化时触发）。该 pid 必须是用户打开弹窗前的 app，**绝不能是 CopyAttach 自身**（agent 应用没有粘贴目标）。预览窗口通过 `NSApp.activate(ignoringOtherApps:)` 真实激活才能收到捏合手势（LSUIElement agent 在 nonactivating panel 上浮期间从不收到 applicationDidBecomeActive，`NSApp.isActive` 误报 true），这会让 agent 成为前台应用——`updateSourceApp()` 检测到自 pid 时直接跳过覆盖，保留上一应用为粘贴目标。
- **image_encoding_counter**：Swift 轮询此计数器检测 Phase 2 编码完成，及时刷新缩略图。

**SwiftUI 模型关系**：
- `ClipboardBackend.shared`（@State）— 单数据源，驱动列表刷新
- `HotkeyManager.shared`（@State）— 快捷键显示/录制
- `HistoryPopupWindow.shared` — NSPanel 单例
- FocusState 双管理：isSearchFocused（selectedIndex=0）和 isContainerFocused（selectedIndex>0），解决 TextField focus 接管后 onKeyPress 失效
- Escape 键三层拦截：SwiftUI `.onKeyPress(.escape)`（正常焦点时）→ PopupHostingView 的 NSEvent local monitor（NSTextView 第一响应者时）→ Notification 转发。Escape 在当前焦点下优先关闭预览，否则关闭弹窗。
- **触控板双指左右滑动切换标签页**：PopupHostingView 的 `.scrollWheel` local monitor（`popupSwipeNotification`，方向 "left"=上一标签/"right"=下一标签，与箭头键同约定；页面随手指行进——左滑=下一标签、右滑=上一标签）在 ScrollView 消费事件之前拦截——只认手指手势（`event.phase != []`），鼠标滚轮/惯性动量一律忽略；水平位移累积 ≥50pt 且水平:垂直 ≥ 1.5:1 即在**手势中途**提交切换（`swipeActivationThreshold`/`swipeAxisRatio`，不等松手——内容在手指还在动时就响应，跟手），累积前按 `isDirectionInvertedFromDevice` 还原手指实际方向（自然滚动开/关下行为一致）；监视器只认**弹窗自身窗口**的事件（`event.window === self.window`）——预览窗/设置窗等兄弟窗口上的滑动原样放行，不会误触弹窗标签；事件只在**提交切换后**才吞掉（防止残留位移拨动新列表），提交前全部透传——未达阈值（<50pt）的横滑、以及从未满足 1.5:1 的对角手势都不产生冻结死区，直接当普通滚动处理；`.stationary`（手势中途停顿）保留累积进度、不重置（`.began` 每个手势只来一次，中途重置会让接近阈值的滑动永远无法提交），`menuTracking` 期间让位。手势中途**反向重定向**：当前事件的横向位移与已累积方向相反、且达到已累积量的 0.5 时丢弃旧 run 重新累积——先小幅试滑再反方向主力滑动的出手会切到手指实际前进方向的标签，而不是被净位移抵消卡在阈值以下。内容侧 `HistoryPopupContent.switchFilterTab(direction:animated:)` 与搜索框 ←/→ 监视器、列表 ←/→ 按键共用；切换动画为**同源数据重过滤**（不做翻页滑动——标签本质是对同一条数据流的过滤条件）：行按 `entry_id` 保持稳定身份，`filterRowTransition` 只让**被过滤掉的行就地溶解**（透明度 + 0.96 缩放，无方向位移）、**新出现的行就地浮现**；**幸存的行没有任何过渡、原地不动**，仅随列表坍缩平滑上移（`filterSwitchAnimation(removed:added:)` 自适应时长：基础 `easeOut(0.15s)`，按实际变更行数——离场 + 入场、各方向封顶 6 行——线性加时至上限 0.28s；标签胶囊用 `.animation(.easeOut(duration: 0.08), value: filterMode)` 即时响应——控件反馈不拖沓，列表动画保持可读；无弹簧过冲）——「同一数据、不同条件」的视觉锚点。日期分隔符同规则；**切换后默认选中新列表第一条**：`switchToFilterTab` 切换前**不捕获选中条目 id**，只统计 removed/added 行数来选定时长。**切换 = 先滚到顶、再切 filter**（单一主流程，无回退）：切标签时先把 `scrollTarget` 指向**列表顶部锚点**（`listTopAnchorID`，LazyVStack 上方一个恒 0 高的普通视图——它始终被布局，位置确定，不依赖 LazyVStack 对未物化行的行高估算），**再在下一个 runloop turn 切换 `filterMode`**（含 `withAnimation` 过渡）。为什么必须这样：若滚动与内容变化同事务/同时发生，scrollPosition 会与 LazyVStack 的行高估算和 ScrollView 的「偏移保持」（新列表比视口短时视口偏移被钳制/调整）竞速——实测表现为滚动完全丢失（视口停在深处）或反复振荡（offset 1261→0→541→0→289 这类拉锯），按住 ↓ 深滚后立刻切换可稳定复现；**先滚到顶（旧内容上，锚点目标精确）后，内容切换时视口已在顶部、无可保持的偏移，干净落位**。切标签后的处理在 `onChange(of: filterMode)`：关预览；`selectedIndex != 0` 时重置为 `displayItems.isEmpty ? 0 : 1`——**新列表第一条**（新标签是对同一数据池的不同过滤，旧行号没有跨标签意义），**空列表落回搜索栏**（selectedIndex=0，搜索框高亮）；搜索框聚焦（selectedIndex == 0）时切换则**不预滚**、保持 0，搜索焦点随之保留。滚动靠 `itemsListScrollView` 的 `.scrollPosition(id: $scrollTarget)`：`itemsList` 的 `onChange(of: selectedIndex)` 在选中项移动时用 `scrollTargetForItem(at:)` 设目标（含其上方日期分隔符 id），**无 ScrollViewReader/`scrollTo`**。底栏计数用 `.contentTransition(.numericText())` 滚动数字。标签点击与双指滑动共用同一 `withAnimation`。
- 搜索：searchText → CJK 感知 debounce（CJK 150ms / ASCII 80ms）→ 离线线程过滤 → cached searchResults。**全文搜索走 SQLite FTS5 trigram 索引**（`db::search_history`：≥3 字符用 `MATCH` 子串匹配 + **对超出索引上限（`FTS_MAX_INDEXED_TEXT_LEN`=512K 字符）的超大文本行做 LIKE 兜底**——索引上限保护捕获路径与 DB 体积，兜底只扫罕见的超大行、子串语义不丢；<3 字符退回 LIKE 全表扫描，`clipboard_search_ids` 返回匹配 entry_id）——全文只存在 DB，内存历史 Vec 不持正文（Text 条目只带 preview/label/text_hash，粘贴/预览/拖拽按 `db_id` 从 DB 按需载入，与图片同约定）。**LIKE 回退是有意保留的语义承诺**：1-2 字符查询必须命中长文中段（曾提议改扫内存 preview 换取无磁盘读，因静默丢失长文中段匹配被否——`test_search_short_query_matches_full_text_middle` 是语义绊线）；已知代价是首两次击键的全表扫描与 LIKE 仅 ASCII 大小写折叠。标签/来源名匹配在 Swift 侧并集（`$0.label`/`$0.sourceName`，图片靠 label "Image (WxH)" 可搜），日期 label 亦在 Swift（DayGroup 是 UI 派生文本）。FTS 索引同步用 SQLite 触发器（AFTER INSERT/DELETE on `clipboard_history`，**触发器 DROP+CREATE 以替换旧版无上限触发器**，backfill 只跑一次且含上限条件，启动时清理存量超大行）。行渲染：`ItemRowView` 无 `#` 的文本跳过正则、hex 色票 NSImage 按色值缓存（`swatchCache`，countLimit 64）——不再每帧 lockFocus 现画。搜索栏固定 index 0，项目从 index 1 开始。
- 弹窗开启（对齐 Spotlight）：窗口 alpha 淡入 0.2s easeOut，`show()` 在 `orderFrontRegardless()` 后**同步**执行——刻意不放进 `DispatchQueue.main.async`（async 实测排在 SwiftUI 首帧渲染之后，启动死区 ~40-90ms，且 095b404 曾因 onAppear 竞态丢淡入才移到 show()，orderFront 同步完成后窗口必在屏上，close 无法中途插入）；内容侧 `HistoryPopupContent` 同窗 `scaleEffect` 1.10→1.0，`spring(response: 0.2, dampingFraction: 0.85)`——与淡入同一 ~0.2s 时间窗静定、damping 接近临界无可见过冲（原 0.21/0.62 弹簧尾巴 ~0.5s，淡入完成后还在晃动）；**淡入看门狗**：同步淡入是 CA 事务，若窗口首帧事务未提交时动画被静默丢弃，弹窗会以 alpha 0 常驻屏幕（不可见，实测可稳定复现）——`show()` 在 `fadeInDuration + 0.1s` 后校验 `isVisible && closeGuaranteeTimer == nil && alphaValue < 0.5`，命中则直接 snap 到可见（`closeGuaranteeTimer != nil` 表示关闭淡出进行中，不抢拉 alpha）；焦点延迟 `openDuration + 0.05`（0.25s）。实测完全不透明 ~190-240ms。
- 弹窗关闭：普通失焦/点击外部走 `closeWithAnimation()`（popup 0.12s fade 与 preview 0.1s fade **独立并行**，各自完成即关闭，互不阻塞，另有 `.common` + `.eventTracking` 双模式 Timer 0.4s 保证关闭必然执行——CA completion 在事件跟踪模式下不可靠）；拖拽后自动关闭（开关开启）走**直接 `close()`**，与 Esc 相同，无动画依赖。
- 日期分组：`DayGroup` 枚举按日历日分组条目，`PopupRow` 枚举在扁平列表中渲染分隔符+条目行
- 选中高亮：选中行的 RoundedRectangle 用 `matchedGeometryEffect(id: "itemSelectionHighlight", in: selectionNamespace)`（`@Namespace` 声明在 HistoryPopupContent）在行间滑动，Spotlight 式弹性过渡；hover 为静态填充（`popupRowHover`）。删除模式（按住 ⌃⌫）高亮变红。
- **右键上下文菜单**：`PopupHostingView.rightMouseDown` 只发 `popupContextMenuNotification`（携带 `.global` 坐标系点击点 viewPoint + windowPoint；NSHostingView `isFlipped=true`，`convert(_:from:nil)` 与 `.global` 同坐标系、无需换算）→ `HistoryPopupContent` 收到后置 `contextMenuArmed`，**行 frame 按需一次性快照**（`RowFramePreferenceKey`：仅武装期间行才挂 GeometryReader 上报 `.global` frame，下一布局回合 `.onPreferenceChange` 解析命中行并撤防）——**滚动全程无每行几何上报开销**，右键菜单延迟仅一帧（~16ms）；`resolveContextMenu` 在下一 runloop 回合 `showContextMenu`（`NSMenu.popUp` 不能在 SwiftUI 布局中途开始），并以 `currentIndex(of:)` 防异步间隙内行已被过滤/弹窗已关。菜单项 handler 用 `ContextMenuItemTarget`（`NSMenuItem.target` 是 weak，靠 `representedObject` 强持有存活）；动作一律 `currentIndex(of:)` 按**稳定 entry_id 重新解析行**，不用构建菜单时捕获的索引。菜单 tracking 期间（`NSMenu.didBegin/EndTrackingNotification` → `isMenuTracking`）Esc/←/→/⌘Z 全让位给菜单导航，不得关闭弹窗或移动列表选中。图片行含「另存为…」（NSSavePanel 写 PNG）。
- **激活庆祝时序**（LicenseManager ↔ LicenseGateView ↔ AppDelegate 三方协作）：激活成功且从未许可→有许可时，`LicenseManager.perform` 设置 `celebration` 并调用 `licenseCelebrationDidStart()`，**暂不关窗**；`LicenseGateView` 观察到 celebration 后隐藏表单、在窗口内播 `LicenseCelebrationView`（TimelineView + Canvas 贝塞尔弧线粒子，约 2s）；`.task` 定时结束后调 `finishCelebration()` → `AppDelegate.licenseCelebrationFinished()` **只启动 Rust 后端、不关窗**——门禁回到激活确认视图（`activatedView`，显示"已激活"状态），用户确认后手动关闭（已许可时关闭不退出，App 在菜单栏继续运行）。`startEntitlementTimer` 在 celebration 期间跳过维护续租，避免提前关窗。
- **在线状态轮询（后台操作立即生效，仅限试用/订阅）**：`LicenseManager` 每 120s（`statusCheckInterval`）向轻量端点 `POST /v1/licenses/status`（activation_id+device_id）或 `POST /v1/trials/status`（trial_id+device_id）查询一次当前状态——**无需签名**（低成本轮询，防滥用不依赖此端点）。管理后台的暂停（suspended）/撤销（revoked）/试用到期（expired）写入数据库后，设备在下一个检查点（≤2 分钟）立即切换权限边界并停用 Rust 后端，而不用等 Lease 半程/到期（最长 12h/7 天）。**永久许可证（perpetual）特殊处理：不安排任何周期性检查（在线状态轮询 + Lease 中点续租）**——它没有到期时间，签名 + 设备绑定即权威，`apply()` 时 `nextRefreshAt`/`nextStatusCheckAt` 置 nil，`maintainEntitlement()` 直接返回；后台的暂停/撤销只影响该密钥的新设备激活与座位管理。**关键约定**：只有服务器明确返回非活跃状态才降级；`not_found`（记录被删/数据库重建等歧义）和网络失败一律忽略，离线 Lease 仍然权威，不惩罚用户。`apply()` 时 `nextStatusCheckAt = now`（刚激活/启动立即检查一次）。对应 `EntitlementState` 新增 `.suspended`（门禁显示「许可证已暂停」）。
- **设备身份与重新激活（误删钥匙串后可重新激活）**：设备身份 = Secure Enclave P-256 密钥对（`DeviceIdentity`，存钥匙串 `device-secure-enclave-p256-v1`），`device_id = "sha256:" + base64url(SHA256(公钥))`；物理设备另用 `hardware_anchor`（哈希后的平台 UUID）标识，跨钥匙串删除/重装稳定。误删钥匙串或重装导致 device_id 变化后，同一台 Mac 用同一密钥重新激活时，服务器按 `license_id + hardware_anchor` 识别为同一物理设备并**自动换绑**激活记录到新身份——不再报 `DEVICE_ALREADY_BOUND`，不消耗新座位（同一条 `device_activations` 原地更新 device_id/public_key）。`LicenseManager.mappedError` 的 DEVICE_ALREADY_BOUND 中文文案保留为兜底（当前服务器版本已不返回该错误码）；试用仍按 hardware_anchor 一次性计，误删钥匙串不会重置试用。
- **版本过旧升级引导（`APP_VERSION_TOO_OLD`）**：所有许可证请求（activate/trial/refresh/unbind/status）附带 `app_version`（`LicenseAPIClient.appVersion`，来自 Info.plist `CFBundleShortVersionString`）。服务端判定版本过旧时返回 `APP_VERSION_TOO_OLD`，`LicenseManager` 映射为 `EntitlementState.needsUpdate`，门禁/设置页显示「请升级 CopyAttach」。注意：该错误码未收录进 `docs/licensing-protocol.md`，以代码为准。
- **激活窗口尺寸陷阱**：`LicenseGateView` 必须固定 `.frame(width: 500, height: 470)`，否则庆祝内容替换表单时窗口被 AppKit fitting-size 压缩、错位到屏幕角落（曾出现动画在左下角的 bug）；`showLicenseGate()` 在 `makeKeyAndOrderFront` 后需再次 `setContentSize` + `center()` 保持居中。
- 设置页永久许可证文案只显示「永久权益 · 最多 N 台设备」（刻意不展示「下次联网验证期限」）；菜单栏（CopyAttachApp.swift）在偏好设置下提供「许可证…」入口调 `openLicenseWindow()`。

## FFI 接口

`CopyAttach-Bridging-Header.h` 声明约 60 个 `extern "C"` 函数：生命周期、查询、快照、图片加载、粘贴、权限管理、删除/撤销/收藏、ignore rules 同步等。新 Rust → Swift 接口需在此文件添加声明，并更新 Swift 侧的调用封装。

## Cargo.toml 关键项

- `crate-type = ["cdylib", "rlib"]` — cdylib 供 Swift 动态链接，rlib 供 stress-gen binary 静态链接
- `#![allow(dead_code)]` 全局开启，部分函数仅由 FFI 或 cfg-gated 路径使用，不建议移除。
- `migration` feature（默认开启）：启用 serde/serde_json/base64，提供 history.json → SQLite 迁移。
- `stress-test` feature：启用应力测试面板（`src/stress.rs`）和 `stress-gen` CLI 二进制。不在默认 features 中，release 构建不包含。
- `image` crate features：`png`, `jpeg`, `gif`, `webp`, `bmp`, `tiff` — 支持从 Finder 复制多种格式的图片文件。
- `rand`（dev-dependency）：仅用于 stress-gen 的随机数据生成。

## 构建依赖

- macOS 15.0+（Sequoia）
- Xcode 16+（含 macOS SDK 15.0），`-target arm64-apple-macosx15.0` 硬编码在 build.sh
- Rust 1.75+
- Swift 6+（build.sh 传 `-swift-version 6`）

## 钥匙串弹窗（重要）

钥匙串条目（Lease + 设备密钥，`KeychainStore`，svce=`com.example.copyattach.licensing`）按创建应用的代码签名授权。**必须用正式签名身份构建**（build.sh 自动用 `security find-identity` 找 Apple Development 身份，找不到才回退 ad-hoc）：ad-hoc 签名的 cdhash 每次构建都变，导致每次重新打开 App 都弹「CopyAttach想要使用钥匙串中的机密信息」（启动时读 Lease + 设备密钥两个条目，可能弹两次）。用正式身份后，对旧条目首次启动点一次「始终允许」即可永久免弹，之后任何重建/重装都不再弹。已用签名身份 + 重编译验证：cdhash 变化后读同一钥匙串条目无提示。

### GitHub Actions 分发（同样必须稳定签名）

CI 发布版（`.github/workflows/build.yml`）的签名步骤同样决定用户端钥匙串弹窗。已修复的关键坑：

1. **环境级 secrets 对 job 不可见**：`MACOS_CERTIFICATE`/`MACOS_CERTIFICATE_PWD` 配置在 `src2release-env` 环境里，但签名步骤所在 `build` job 必须声明 `environment: src2release-env` 才能读到——否则 `${{ secrets.* }}` 为空，签名步骤静默跳过，产物为 ad-hoc。
2. **步骤级 `if: env.MACOS_CERTIFICATE != ''` 永远为 false**：`if` 条件看不到步骤自己的 `env:` 映射（含 secrets 赋值）。改为步骤始终运行 + 脚本内 `[ -z "$MACOS_CERTIFICATE" ]` 守卫。
3. **证书配了却找不到身份时显式失败**（`exit 1`）：避免静默发布 ad-hoc 产物。身份提取：`security find-identity -v -p basic` 优先匹配 `Developer ID Application`，也兼容 `Apple Development`（两者都提供跨构建稳定身份）。
4. **公证流程**：先 `build/package_dmg.sh` 打包，再 `notarytool submit` + `stapler staple` 作用于最终上传的 DMG（Apple Development 证书不支持公证，需 Developer ID + `MACOS_NOTARIZATION_ACCOUNT/PWD/APPLE_TEAM_ID` secrets）。

验证方式：下载产物后 `codesign -dv --verbose=4 CopyAttach.app | grep Authority`，必须是身份证书而非 `Signature=adhoc`；`codesign --verify --deep --strict` 通过。

`[profile.release]` 启用 `strip = true`、`lto = true`、`codegen-units = 1`——链接阶段较慢但产出最小二进制。

## 测试覆盖

所有 Rust 测试集中在 `src/tests.rs`（cfg-gated）；`src/bench_tests.rs`（cfg-gated on `test` + `stress-test`）另含少量性能基准测试。覆盖：基本添加与顺序、去重（文本/图片/混合）、图片编解码与缩略图、内容哈希一致性、SourceApp 元数据、label 生成（含多字节安全）、FFI 空指针安全、阈值清理（多个阈值 + 边界 + 百分比 trim + ceil 行为）、阈值变更、ignore rules（app/类型/长度）、db_id 按内容身份赋值（头部竞争/头部正常/无匹配）、FTS 大文本索引上限（不入索引但仍可搜/存量超大行驱逐）、应力测试数据生成。

## .claude 配置

`.claude/settings.local.json` 包含命令白名单权限。新命令需要时在此文件 `permissions.allow` 数组中添加。

`vision-hook.js`：`UserPromptSubmit` hook，当 prompt 中包含本地图片路径时，自动通过 vision API 转译为文本描述，使 Claude 无需直接读取图片文件即可理解其内容。

## 安装的 Skills

`.claude/skills/` 目录包含动画/设计相关的 skill（软链接，实际源在 `.agents/skills/`），可用于 UI 动效分析与改进：
- `apple-design`, `emil-design-eng` — Apple 风格 UI 设计原则
- `animation-vocabulary`, `improve-animations`, `review-animations`, `find-animation-opportunities` — 动画分析与改进
