# CLAUDE.md

CopyAttach 是一个 macOS 剪贴板历史管理器：Rust 后端（cdylib）+ Swift 前端（LSUIElement agent app）+ SQLite 持久化。

## 行为约定

### 构建后必须重启 APP
每次重新构建 APP 后，关闭旧 APP 并启动新构建的 APP：

```bash
pkill -f 'CopyAttach.app/Contents/MacOS/CopyAttach'; open "CopyAttach.app"
```

### 从第一性原理分析代码
先理解核心数据流和不变量的本质，再逐层验证具体实现是否忠实于这些原理。不依赖既有注释、命名或架构图——它们可能过时。

### 不要搞兜底实现
不写 fallback / 兜底逻辑。兜底会掩盖主流程错误，让 bug 难以发现。主流程失败应该显式暴露（panic、返回错误、日志 + 空结果），由调用方决定如何处理。

### 不写注释
不在代码中写任何注释

### 推导不等于验证（硬约束）
**任何「已修复 / 已确认 / 原因就是 X」的结论，必须在真实路径上有实测证据；否则只能表述为假设。**
- 在隔离环境验证替身（单独构造一个 `NSItemProvider`、手写剪贴板样本、脱离调用链跑一个函数）**不构成验证**——被测的必须是真实调用路径本身。踩过的坑：曾单独验证 provider 能注册 5 种 UTI 就宣布拖拽修好，但 SwiftUI `.onDrag` 这条真实路径根本没测，实际未修好。
- 调试采样点自身也可能错。踩过的坑：读 `NSDragPboard` 得到「拖拽无数据」的假象——现代 macOS 拖拽剪贴板实为 `Apple CFPasteboard drag`，前者恒为空。**先证明观测手段有效（能观测到已知为真的现象），再采信它给出的「没有」。**
- 报「已修复」前必须能回答：改动前失败、改动后成功，两次都在真实场景里观察到。做不到就明说「尚未实测」。
- **并发/竞态类问题单次运行不足以下结论**。踩过的坑：`src/tests/backend.rs` 与 `src/tests/soft_delete_real.rs` 各持一份 `Once` 初始化并争抢进程级 `Backend` 单例，6 次运行中 3 次失败（105/109），单跑一次全绿就提交了。**这类验证要连跑多次（≥8 次）并观察失败率**，不能以「这一次是绿的」收尾。
- **验证手法本身可能破坏被测前提**。踩过的坑：① 早期用覆盖的 `HOME` 启动 GUI 测内存导致环境路径失真；现在数据库隔离统一走 `COPYATTACH_DATA_DIR`（见下文）；② 用每 500ms 新开一个 SQLite 连接轮询 `user_version` 来判定迁移结束——对一个 188MB 的库反复建连，把它自己注入了被测的常驻内存，得出前后矛盾的稳态数字；③ 起第二个 GUI 实例被单实例守卫直接 `exit(0)`，采样到的「进程消失」毫无意义。**观测动作不能改变被测对象；判定结束优先靠日志标记而非副作用式探询。**
- **做任何会写库的实测前，必须先备份真实库**（硬约束）。踩过的坑：测连续删除动画时直接对真实库长按 `⌃⌫`，执行了 765 次删除；撤销上限默认只保留 1 条，`purge_expired_deleted_rows` 会把上一条载荷行硬删，**三个月的历史不可恢复地丢失**。备份命令（`sqlite3 .backup` 走在线备份 API，自动处理 WAL，不需要先 checkpoint）：
  ```bash
  DB="$HOME/Library/Application Support/CopyAttach/history.db"
  BK="$HOME/Library/Application Support/CopyAttach/backups/history_backup_$(date +%Y%m%d_%H%M%S).db"
  sqlite3 "$DB" ".backup '$BK'"
  sqlite3 "$BK" "select count(*) from clipboard_history;"   # 必须与当前库一致才算备份成功
  ```
  **删除、清空、批量导入、迁移这类不可逆操作尤其必须先备份**，并在动手前确认备份行数与当前一致。

## 构建与测试

```bash
# 构建全部（Rust + Swift）
./build.sh

# 压力测试构建（仅编译 stress-test 特性；1 万条数据由 stress_test.sh 或 App 内压力面板生成）
STRESS=1 ./build.sh

# 仅 Rust release 构建
cargo build --release

# 测试
cargo test
cargo test test_add_text_item          # 按名称匹配

# 压力测试编排（生成数据 → 部署 DB → 采集指标；仅解析 --measure-only / --generate-only，条数用 COUNT 控制）
bash stress_test.sh                    # 完整 10000 条
COUNT=1000 bash stress_test.sh         # 1000 条快速测试

# 综合压测与竞态/故障/长跑套件（详见 docs/stress-test-plan.md，使用 COPYATTACH_DATA_DIR 隔离）
bash scripts/stress/rust_suite.sh
bash scripts/stress/ui_suite.sh

# 推送/发版前一致性门禁（11 项检查，含 clippy + test）
bash check_push.sh

# 调试日志（Swift + Rust 统一落盘）
tail -f /tmp/copyattach_debug.log

# 打开应用
open "CopyAttach.app"
```

**版本号与 CHANGELOG 约定**：
- **版本号**：唯一**生效**版本源在 `Cargo.toml` 的 `version` 字段，`build.sh` 自动注入到产物 `CopyAttach.app/Contents/Info.plist` 的 `CFBundleShortVersionString`（源码 `SwiftApp/Info.plist` 里保留一个恒为 `0.0.0` 的死值占位，build.sh 不修改它）。开发版本带 `-dev` 后缀（如 `0.93.0-dev`），发布版本去掉后缀。每次功能/修复提交都提升版本号并写入提交信息。
- **版本号改动范围（硬约束）**：**只允许改动末尾的 patch 数字**（如 `0.102.3` 中的 `3`），**绝不能改动中间的 minor 与前面的 major**（`102` 和 `0` 由人工决定）。需要联动大版本时必须停下等用户指示。
- **CHANGELOG 规范**：内容必须**纯面向用户且简洁凝练**。

### 内存测量

看内存只认 `vmmap -summary` 的 `Writable regions` 行，不要用 `footprint` / 活动监视器的单值：

```bash
vmmap -summary $(pgrep -f 'CopyAttach.app/Contents/MacOS/CopyAttach') | head -16
#   written     = phys_footprint 的来源（脏过的页，含已被压缩换出的）
#   resident    = 真正占用 RAM
#   swapped_out = 已被系统压缩换出
```

- `phys_footprint` 把**已压缩换出的页照样算作脏页**：实测长期会话 `resident` 仅 ~20MB，`phys_footprint` 却是 95–104MB（~70MB 在压缩器里）。两者差很大 = 账本问题，不是回收问题。
- 稳定底线 ~36–44MB：干净空闲 19–22MB，首次开弹窗一次性 +~13–25MB（视图图，之后多轮开关零累积）。再往上的两个已实测来源：瞬时大图解码（~20MB 池，页已标记可回收、不计入 footprint）与 `NSWorkspace` 查询把 ~12MB LaunchServices 数据库拉进进程。构成与数据见 `docs/engineering-notes.md` 的「内存基线的真相」。
- **删除/撤销不产生常驻内存**(0.109.2 起)：删除只是在 `clipboard_deleted` 侧表写一行（行号 + 时间戳 + 收藏标记），**载荷行一个字节都不动**——因此既没有落盘临时文件，也不读 blob。实测（34 条 demo 库、含 3 张 ~4MB 截图，`vmmap -summary` 的 `Writable regions`）：删 34 条 `written` **320K → 320K（+0KB）**；撤销 34 条 `written` **+32KB**、`resident` 增长 28MB 但全部落在 `Malloc Large (Reusable)`（已 `mark_pages_reusable`、不计入 footprint）；再连续 3 轮删除/撤销 `written` **零增长**（352K 恒定）。早期「载荷落盘到 `$TMPDIR/CopyAttach/Undo/*.bin`」的 1 步栈已整体删除。
- `malloc_zone_pressure_relief` 不要加：实测它收不回任何东西——进程内 4 次调用、以及「512MB 已释放的 1MB 块仍计入 footprint」的合成场景，全部返回 `0 bytes`。
- **缩略图迁移是一次性内存事件**（0.105.1 起，`METADATA_VERSION = 4`，`user_version < 4` 的库首次启动触发一次；`< 3` 先跑 hash 迁移、`< 4` 跑缩略图迁移）：真库 137 行 release 实测峰值 79MB、稳态回落至与 no-op 相当（~9–18MB vs ~8.7MB），完成后不再发生。它不是常驻泄漏；若在「刚升级后」看到后台内存偏高，先确认 `metadata migration complete` 日志是否已出现。实现细节与三条踩坑（绕过 madvise 契约、每行新建 blob、借用捕获池）见 `docs/engineering-notes.md`。

### 构建与分发

应用自 v0.108.0 起完全免费并开源，无需任何 License Server。直接执行 `./build.sh` 即可完成本地构建与签名：

```bash
./build.sh
```

（历史商业版本的服务端与客户端授权体系已完整归档封存在 `archive/commercial-v0.107` 分支与 `v0.107.10-commercial-final` 标签）。

Homebrew cask 维护在独立仓库 `wonaren/homebrew-tap`（安装命令 `brew install --cask wonaren/tap/copyattach`）。该仓库每小时读取最新 Release，自动更新 `version` 与 `sha256`；本仓库 Release job 发布后会 dispatch 它立即同步，所以无需手动改 cask。

## 代码库架构

### Rust 后端（`src/`，cdylib → `libcopy_attach.dylib`）

| 模块 | 职责 |
|---|---|
| `ffi/` | FFI 导出主目录（8 个子模块，68 个函数）：`snapshot.rs` / `search.rs` / `init.rs` / `accessors.rs` / `paste.rs` / `history.rs` / `backup.rs` / `stress.rs`（另有 3 个在 `backend.rs`、4 个在 `perf.rs`） |
| `db/` | SQLite write-through：`schema.rs`（连接/FTS5/`user_version` 迁移/目录解析 `COPYATTACH_DATA_DIR`）、`migration.rs`（legacy `history.json` → SQLite 导入，feature-gated）、`crud.rs`（load/insert/dedup/trim）、`search.rs`（FTS/LIKE）、`backup.rs`（导出/校验/覆盖/合并）。禁用 mmap，4MB LRU page cache；FTS 索引上限 512K 字符，超限行走 LIKE 兜底；text/image hash 均为稳定 FNV-1a 64 |
| `monitor.rs` | 后台线程每 500ms 轮询剪贴板，changeCount 轻量检测，write-through DB，ignore rules 过滤。图片 Phase 2 单 worker + 单槽有界队列（背压） |
| `ignore.rs` | 捕获时忽略规则：按 app bundle ID、类型、短文本阈值过滤 |
| `image.rs` | 解码 PNG/JPEG/GIF/WebP/BMP/TIFF，**编码只有 PNG**（存储 blob 恒为 PNG），CatmullRom 缩略图（等比 fit 进行显示框 920×200px），FNV-1a 内容哈希 |
| `backend.rs` | `OnceLock<Backend>` 单例，entry_id（AtomicU64），HISTORY_REVISION / IMAGE_ENCODING_COUNTER 原子计数器，自写抑制，变更等待 FFI |
| `perf.rs` | 流畅度仪表（`__CA_PERF__`）及 4 个控制/探针 FFI |
| `types.rs` | 核心领域模型（ClipboardEntry / HistoryItem 等） |
| `macos.rs` | NSPasteboard changeCount + 文件 URL 读写，CGEventPost Cmd+V，AXIsProcessTrusted。cfg-gated，非 macOS 用空桩 |
| `history.rs` | `add_to_history()` — 去重 + 头部插入，纯函数式 |
| `tests/` | 单元测试目录模块（cfg-gated，11 个子模块）：`backend` / `backup` / `cleanup` / `db` / `history` / `image` / `migration` / `quick_slots` / `search` / `soft_delete` / `soft_delete_real` |
| `bench_tests/` | 基准/内存探针测试目录模块（cfg-gated on `test` + `stress-test`，4 个子模块）：`thresholds` / `images` / `memory_probe` / `side_table` |
| `stress/` | 应力测试（feature-gated behind `stress-test`）：数据生成 + 注入 + 基准测试 |
| `demo/` | 演示数据（feature-gated behind `demo-data`）：一套人工挑选的文本 + Unsplash 实拍图（首次生成时下载并缓存到 gitignored 的 `demo-data/images/`），按生产 schema/hash/缩略图辅助函数写入独立 DB。`src/bin/` 下含 `demo_gen.rs`、`stress_gen.rs`、`bench.rs`，`./videos/demo.sh` 负责与个人库换位 |

**关键机制**（详细原理见 `docs/engineering-notes.md`）：

- **两阶段图片捕获**：Phase 1 同步 hash + 缩略图并排队；Phase 2 异步完整 PNG 编码，SQLite 提交后发布到列表（单槽有界队列背压，防内存无界增长）
- **内存治理（0.99.10 起）**：启动不读剪贴板；图片捕获按固定类型优先级 PNG→TIFF→JPEG→GIF→WebP→BMP 取第一个存在的表示（**只按类型优先级，不比较各表示的体积**）；Phase 2 编码 scratch 复用；空闲池页标记可回收（`madvise MADV_FREE_REUSABLE`）；预览解码走 Rust 而非 ImageIO；自研 u8 resize 替代 `imageops::resize`（避免 f32 中转）。**改任何大缓冲路径前必读 `docs/engineering-notes.md` 的 madvise / claim 契约章节**
- **收藏落库（0.108.5 起）**：`clipboard_favorites(entry_id)` 表是唯一权威。自动清理阈值按所有活行计算，收藏和快捷槽位条目受保护。`load_history_from_db` 先为受保护条目保留名额，再按剩余名额加载最新普通条目。受保护条目本身超过阈值时仍全部保留。打包快照（v3）每行 `flags` 同时编码 `favorite`（bit 0）与 `quick_slot` 1~9（bits 1~4）。Swift 的 `favoriteIds` 只是快照的镜像，**不要**再写回 UserDefaults，也不要在列表发布时剪枝
- **检查更新（`Update/UpdateChecker.swift`）**：GitHub `releases/latest` HEAD（实测 0.2–0.5s，权威且零字节）与 healthz（实测 3.9–10s，仅为 GitHub DNS 不可达时兜底）**并行竞速**，取最快成功者；结果持久化缓存 15 分钟，About 首屏直接渲染缓存、过期才后台复检。旧实现串行「healthz 6s 超时 → GitHub」，把每次检查都拖到 5s 以上
- **弹窗内更新按钮（`Update/UpdateBadge.swift`）**：filter 行右侧，仅**真实升级**时出现（`UpdateChecker.isUpgrade`：`current` 带 `-dev` 后缀时一律算有更新——开发版不是发布产物；正式版按数值比较）。点击后同一位置变「下载中 N%」→「安装中…」，进度用 `monospacedDigit` + `fixedSize` 防止 chip 行抖动。检查时机是启动读缓存 + 每次开弹窗若缓存超 15 分钟则后台刷新（`UpdateBadge.refreshIfStale`，另有 `lastAttempt` 节流）。设置页「关于」标签的红点由 `hasUnseenUpdate` 驱动，看过一次写入 `SeenUpdateVersion` 后消失。
- **更新完成小窗（`Update/UpdateCompleteWindow.swift`）**：`UpdateDownloader.install()` 在替换 bundle 后写 `PendingUpdateVersion`，并在下载开始时抓取 GitHub Release `body` 存 `PendingUpdateNotes`；下次启动 `AppDelegate.showPendingUpdateCompletion()` 剥离 `-dev` 后缀按 `currentBase == pending` 精确比对才弹窗（版本不匹配就丢弃，避免手工改 defaults 造成误报）。日志从本地读、不依赖网络，取不到就明示「更新日志暂不可用」。Esc 与关闭按钮都关窗，不自动消失。
- **db_id 不变量**：内存条目的 `db_id` 必须指向 DB 中该条目的行，且赋值使用该条目的写库结果、绝不按头部位置
- **Suppress re-capture**：select_and_paste 通过 `pending_self_write` 标记自身写入，监控线程跳过匹配的 changeCount
- **复制/粘贴提示音（`SwiftApp/Utility/SoundFeedback.swift`）**：播放一律走 `AudioServicesPlaySystemSound`（系统声音服务异步执行，调用开销 ~0.2ms）——`NSSound.play()` 实测每次阻塞调用线程 15–35ms（冷启动 110ms），在 `.onChange` 里同步调用必掉帧，禁用。音效列表动态扫描 `/System/Library/Sounds/*.aiff`，UserDefaults 存文件名。后台复制捕获音靠 Rust 侧 `clipboard_set_capture_callback`（`src/backend.rs` 静态槽，`monitor.rs` 落库释放锁后触发，关闭时置 nil 零开销）；粘贴音在 Swift 各送达路径播。右键复制用 `suppressMonitorCopyUntil` 抑制紧随的同一次 monitor 重捕，避免双响。
- **undo 删除（软删除，0.109.2 起）**：删除 = 在 `clipboard_deleted` 侧表插一行 `(row_id, entry_id, deleted_at 微秒, was_favorite, was_slot)` + 删掉该条的 `clipboard_favorites` 与 `clipboard_quick_slots` 行；载荷行留在 `clipboard_history` 原地不动。撤销栈因此**由数据库派生**，没有内存栈、没有临时文件——深度只受保留期（`UNDO_RETENTION_SECS` 7 天）与**可配置上限**约束。上限编码在 `clipboard_meta.undo_budget_bytes` 单个 i64（键名沿用）：`>0` = 字节预算、`<0` = 条数上限（`-N`，即保留 N 条）、`0` = 不限制；**默认 `DEFAULT_UNDO_LIMIT` = -1（1 条）**，设置页可选「1 条 / 16MB / 64MB / 256MB / 不限制」；超限按 `deleted_at` 升序丢最老的删除。**淘汰前必须先问用户**（`UndoEvictionWarningDisabled` 默认 **true**，即默认不提醒）：`clipboard_undo_eviction_preview` 在删除**之前**算出会挤掉几条（删除后就没得报了），Swift 侧据此弹「继续删除/取消 + 不再提醒」。撤销 = 读回该行载荷 → 走 `insert_entry_to_db` + `delete_matching_entry`（dedup）→ 删掉旧行 → 按 `was_favorite` 与 `was_slot` 恢复收藏和快捷槽位（目标槽位未被他人占用时），因此「删 A → 再复制 A → 删 A → ⌘Z×2」只留一行，重启也不重复（旧实现不去重，会留两行）。**侧表而非列**是实测决定的：`UPDATE clipboard_history SET deleted_at=?` 会整行重写，图片行的多 MB blob 被读出来再写回，34 次删除实测 +24MB 滞留 RSS（`shrink_memory` 不回落）；换成侧表后同样的 34 次删除是 **+0KB `written`**。所有活行查询用 `id NOT IN (SELECT row_id FROM clipboard_deleted)`（`load_history_from_db` / `trim_db_history` / `search_history` 的 FTS+LIKE+metadata 三路 / `set_favorite` / `update_entry_custom_label` / `clipboard_get_storage_breakdown` / 备份导出与合并）。`clipboard_clear_history` 与备份覆盖恢复都硬删（**含 `clipboard_deleted` 侧表行**，两者的确认框都承诺「无法撤销」）——侧表按 `row_id == clipboard_history.id` 寻址，恢复会按归档自己的 id 重写该表，残留侧表行会把一条刚恢复的条目变成「已删除」。

### Swift 前端（`SwiftApp/`，LSUIElement agent app）

**LSUIElement agent app**：`Info.plist` 设 `LSUIElement=true`，无 Dock 图标，只以 MenuBarExtra + 浮动 NSPanel 存在。级联后果：① 它不是合法粘贴目标——`CGEventPostToPid` 的目标 pid 绝不能是自身；② nonactivating panel 上浮期间 agent 收不到 `applicationDidBecomeActive`，预览捏合手势需 `NSApp.activate(ignoringOtherApps:)` 真实激活；③ 主弹窗与设置窗用 `.titled + .fullSizeContentView` 隐藏标题栏以拿到系统圆角（其余面板仍为无边框 NSPanel）。

```
SwiftApp/（共 68 个 .swift 文件）
  ├── CopyAttachApp.swift              ← @main, MenuBarExtra, 单实例守卫
  ├── ClipboardBackend.swift           ← Rust FFI 封装，@Observable，快照/历史变更等待器
  ├── HotkeyManager.swift              ← Carbon + NSEvent 双注册，录制模式
  ├── ColorTheme.swift                 ← 深色/浅色颜色体系
  ├── App/AppDelegate.swift            ← 生命周期, 弹窗/设置窗(窗口 520×712、内容 520×680)管理, 启动时 dup2 stderr → 日志
  ├── Hotkey/                          ← 快捷键配置与全局槽位拦截（2 文件：HotkeyConfig / QuickSlotEventTap）
  ├── Settings/                        ← InlineSettingsView（10 文件：6 标签页 通用/功能/快捷键/存储/忽略/关于 + JustifiedParagraph / QuickSlotSettings / SheetDismissHelper）
  ├── Onboarding/                      ← 核心操作引导（5 文件：引导模型/浮窗卡片/聚光灯遮罩）
  ├── Queue/                           ← 粘贴队列（6 文件：状态管理/HUD窗口/HUD视图/CGEventTap拦截器/批量派发/批量HUD）
  ├── Popup/                           ← 主弹窗（18 文件：内容/窗口/事件/SwiftUI列表行/日期分组/行内备注/长文本/拖拽/批量拖拽/右键菜单/标签过滤/预览/动作/快捷槽位拨盘）
  ├── Preview/                         ← 预览窗口（5 文件：窗口/内容/底栏/布局/缩放）
  ├── Backend/                         ← 数据模型与缓存（6 文件：ClipboardItem / ImageDecode / AppIcon缓存 / PackedSnapshot / PasteDeliveryMode / PreviewDecodeGate）
  ├── Stress/                          ← 压力测试面板与视图模型（2 文件，依赖 STRESS=1 构建）
  ├── Update/                          ← 更新检查（并行竞速 + 缓存）、弹窗更新按钮、更新完成小窗与下载（4 文件，GitHub 优先，蓝奏云兜底）
  └── Utility/                         ← 工具与埋点（5 文件：AppleMotion / DebugLog / VisualWidth / PerfTrace / PerfSelfCheck）
```

**关键 FFI 模式**：

- **Snapshot API**（`clipboard_snapshot_acquire/release`）：Swift 批量读取时一次性加锁构建紧凑快照（`SnapshotRow`：类型/id/时间戳/label/source/图片尺寸 + preview，**不含全文**），后续无锁访问。新功能优先用此 API
- **稳定 ID**：`entry_id`（u64，AtomicU64 单调递增），用于 `select_and_paste_by_id`，避免数组索引竞争
- **图片加载**：缩略图走 `clipboard_get_image_thumb_by_db_id`（仅 SQLite 读），后台用 ImageIO 降采样到**行显示框**（460×46pt，按屏幕 backupScale 换算像素；Rust 端存储 blob 仍按 2× 上限 920×200 生成，无需迁移）后存入 `NSCache`（countLimit 120、8MB，cost 按实际解码尺寸计），**弹窗关闭不清空**（跨会话保温：清空会让每次打开都冷启动，首屏行先渲染占位符；实测命中率 0%→92%、占位闪烁 2 行→0，内存无变化——缓存本身仍有界且随内存压力驱逐）。只有真正使行失效的路径才清空：清空历史、撤销删除、恢复备份。**预览缓存（0.111.16 起）**独立于列表缩略图，2 项预算，只在本次历史弹窗会话内复用；弹窗与设置「快捷键」页共享引用计数的会话，最后一个宿主关闭时才清空，反向打开关闭动画沿用原会话。缓存与会话标识在 MainActor 管理，每次 await 后检查取消和会话身份，旧解码结果不能重新入缓存。**预览像素直接解码进 IOSurface（0.113.4 起）**：`clipboard_preview_dims` 算出目标尺寸 → Swift 创建 `IOSurface`（BGRA）→ `clipboard_decode_preview_into` 流式解码写入其内存（含行 stride）→ `layer.contents = surface`。**不要改回 CGImage/NSImage 路径**：实测同一张 2214×1440 预览图，CGImage 会被 CoreAnimation 额外复制两份（进程 footprint 46MB），IOSurface 只有表面本身（21MB），且这些复制页永不归还，是「越用内存越高」的根源。预览解码不用 ImageIO；预算是 `min(源最长边, max(显示尺寸×scale, 2048px))` —— **2048px 是缩放下限（floor），不是上限**，实测交付缓冲的 `max_dim` 常见 2066–2348。`clipboard_get_image_full_by_db_id` 是另一条路（**仅 SQLite 读，没有任何内存层**），只用于 GIF 预览兜底与右键「复制图片」，不是预览主路径。**显示框是矩形而非「最长边」**：扁图由宽边限制、竖图由高边限制，按长/短边匹配会让竖图纵向溢出（曾实测 1362×1774 → 200×260 超出 200 高）。
- **记录侧边悬浮预览（0.110.6 起，0.112.1-dev 扩展）**：图片行压缩到约两行文本高度（只保留 46pt 缩略图，不附尺寸文字）。侧边预览支持两条入口：**鼠标悬停**（180ms 延迟，横向移入气泡有 220ms 宽限期）、**键盘 `↑ / ↓` 切换选中行**（180ms 延迟，已打开时立即跟随；初始打开默认选中首行不触发）；通过 `HoverPreviewSource`（`.mouse` / `.keyboard`）隔离双轨，防止滚动或鼠标扫过中间行劫持/关闭键盘气泡。任意来源的气泡在 3 秒后自动淡出关闭（`0.32s`、缩放 `0.94`、模糊 `10pt`），鼠标移入气泡暂停计时、移出后重新计时。设置 → 功能提供「侧边悬浮预览」两个总开关（`TextSidePreviewEnabled` 默认关、`ImageSidePreviewEnabled` 默认开），关闭后两条入口均禁用。图片气泡读 `thumb` / `previewImageAsync(300pt×屏幕 scale)`（`miniMaxWidth = 300pt`）；文本气泡直接渲染快照里的 `preview`（≤256 标量，**零 DB 读取**），320pt 宽、最多 6 行、尾部省略。**悬停气泡时左上/右下浮现直角裁剪标记**（纯图形提示，无文字；由 `PreviewHostingView` 的 NSTrackingArea 驱动 `PreviewHoverState`；mini 的图片是 `SurfaceImageView`（`layer.contents = IOSurface`），实测 SwiftUI 覆盖层仍渲染在其上（0.113.4 验证））。点按气泡或对选中气泡按 `Space` 把同一个 NSPanel 形变为中央 `.large` 大预览（动画期间保留气泡内容，0.24s `.easeInEaseOut` 放大，`completion` 里才安装大预览并 `NSApp.activate`）。大预览关闭动画与 popup 同款（窗口 alpha 0.15s easeOut + 内容 scale 1.04 / blur 16pt / opacity→0，由 `PreviewDismissState` 驱动）。**大预览单击退出规则统一**：`Space` 直接打开（`openPreview`）与侧边展开（`expandHoverPreview`）均传入 `onDismiss`——图片未缩放时单击画面关闭；文本预览 `onTap` 非空（置 `isSelectable=false`）并在 mouseUp 关闭。`hoverPreviewSuppressed` 在 dismiss / 编辑备注 / 大预览 / 引导激活 / 模态面板 / 拖拽 / 弹窗非打开态时抑制，不抑制粘贴队列。**键盘轨的气泡更新滞后一帧**：`scheduleKeyboardPreview` 在 `selectedIndex` 赋值后同步执行，此时 `selectedRowAnchor` 仍是上一行的锚点，所以「气泡已存在但锚点不匹配」的分支直接 `return`、保留旧气泡；随后 SwiftUI 重渲染令 `anchorRowArmed`（`isSelectedRow && (keyboardPreviewTargetId != nil || hoverPreviewSource == .keyboard)`）为真，preference 带新锚点回调 `handleSelectedRowAnchorUpdate`，守卫 `keyboardPreviewTargetId == entryId` + `selectedItemId == entryId` + `hoverPreviewShowTask == nil` 全过后才换内容。实测连按 ↓ 时锚点每次落后一行、下一帧追上；选中行滚出 LazyVStack 视野时锚点短暂变 nil（`selected=150` → `id=-1` → `id=150`）由 `scrollTarget` 滚回。**不要在这个分支里加 `closeHoverPreview()`**——锚点滞后是常态，加了会让每次按方向键都关掉再重开气泡。
- **两阶段粘贴（prepare_paste_by_id + send_paste）**：`delivery_mode` 0 = 光标处插入、1 = 仅写剪贴板（`PasteDeliveryMode`，设置里可切）。先按 entry_id 查 history（未命中直接 return 0）→ 仅 mode 0 查 accessibility 权限（未授权直接 return 0；mode 1 无需授权）→ DB 加载正文/图片 blob（失败显式 return 0，不兜底）→ 写剪贴板（设 pending_self_write）→ DB write-through → move entry to top → mode 1 返回 1（Swift 不调 send_paste，`.copied`），mode 0 返回目标 pid（无目标 pid 返回 -1：内容已在剪贴板，只跳过击键）；Swift 侧先关闭并失焦弹窗（dismiss）避免 panel 保持 key window 截断击键 → 调 send_paste(pid) 发送 Cmd+V。**权限检查必须早于任何剪贴板写入**——写入会替换用户剪贴板，未授权时的写入等于毁掉用户内容却永远粘贴不成。**图片粘贴走唯一的文件路径模式**：先写 `$TMPDIR/CopyAttach/Paste/` 临时 PNG，剪贴板放 `public.file-url`（Finder 复制文件同款）再 Cmd+V
- **粘贴目标 pid 不变式**：Cmd+V 投递给 `source_app.pid`（由 `NSWorkspace.didActivateApplicationNotification` 事件驱动更新，不轮询）。该 pid 必须是用户打开弹窗前的 app，绝不能是 CopyAttach 自身
- **粘贴后必须归还前台**：预览会强制 `NSApp.activate`（捏合手势只投给最前台 app），而系统**不会**自动归还 —— 不归还的话 Cmd+V 仍能投进目标 app（内容进去了），但该 app 留在后台，光标回不到输入框。`selectItem` 粘贴后调 `ClipboardBackend.restorePasteTargetFocus()`；它只在 `NSApp.isActive` 为真时才动手，所以从不激活的普通路径是 no-op
- **全局快捷槽位（`Hotkey/QuickSlotEventTap.swift` + `Popup/QuickSlotDialWindow.swift`）**：弹窗内按 `右 ⌘` 弹出 100×100 九宫格环形拨盘（`QuickSlotDialView`），按 `1~9` 绑定/解除槽位；弹窗关闭时 `QuickSlotEventTap` 在独立 `.userInteractive` 线程跑 `.defaultTap` + `CFRunLoopSource`（持 `ProcessInfo` activity assertion），结合 `UCKeyTranslate` 与 `kTISNotifySelectedKeyboardInputSourceChanged` 正确识别 Shift 数字键，并在 `.tapDisabledByUserInput` 后轮询 `IsSecureEventInputEnabled()` 待安全输入结束后恢复。设置 → 快捷键的「全局快捷键」卡片内含 9 格单行槽位（只显示数字，绑定为蓝底实线、空位为虚线）：拖拽交换、拖到垃圾桶解除、点击用原生 `.popover` 复用 `PreviewContent`（`embedded: true` 去掉自绘 14pt 圆角与 3pt 内边距，改铺不透明 `popupBackground`，否则会透出 popover 材质下的文字）预览内容；交换成功后两格的内容标签会相向滑动（0.26s，减少动态效果时只淡出）提示内容已互换。**`ImageDecode` 的预览 session 必须挂在 `QuickSlotSettings` 上**（`.onAppear`/`.onDisappear`），不能挂在单个 popover 上——挂 popover 会让每次开关都作废缓存、重复解码（实测 20 次开关触发 20 次 Rust `preview_decode`；改挂组件后 20 次只解码 1 次）。
- **粘贴队列（`Queue/`）**：在列表按 `⌘C` 只维护一个有序数组（序号徽标在视图侧由 `orderMap` 派生，不再存第二份顺序），不写剪贴板、不触发 `monitor.rs` 重新捕获置顶；回车启动顺序取用：先按当前快照剔除已失效条目（`pruneStaleEntries`，对空快照不做剔除）→ 再启动 `QueueEventTap`，成功才允许 dismiss 弹窗展开胶囊 HUD；取用阶段通过 `ClipboardBackend.pasteEntryById` 走规范两阶段粘贴，返回 `PasteOutcome`：`.pasted` 前进、`.keystrokeNotDelivered` 前进并提示（内容已在剪贴板，重试会重复粘贴）、`.entryUnavailable` 跳过并提示；`QueueEventTap` 吞掉物理 ⌘V（修饰键精确匹配，`⌥⌘V` 等组合一律放行；`⇧⌘V` 触发 `skipCurrent()` 跳过当前条目），合成事件按**事件来源**（`eventSourceUnixProcessID`）识别而**不是时间窗**——实测 `CGEventPostToPid` 事件根本不进 session tap，Esc 单次一律放行给目标应用、**连按两次**才退出队列；闲置看门狗 3 分钟；`clear()` / `cancel()` 强行保证同时拆除 Tap 与 HUD。
- **批量拖拽（`Popup/BatchDrag.swift` + `Queue/BatchDispenseRunner.swift`）**：队列 ≥1 项时，拖动队列中任一行 = 走派发器（按徽标顺序）。1 项也走这条路，是为了给「落点根本不收文本 drop」的应用（VS Code 终端只认 `Files`/`ResourceURLs`，没有 `text/plain` 分支）留一条送达方式——把该项加入队列后拖它即可。**拖拽载荷是空占位，一条内容都不走 drop**——实测接收方会选中 drop 刚插入的内容（文本：AX selection `loc=0 len=9`；图片：TextEdit 附件数 1 而非 2），紧随其后的 ⌘V 会把首条**替换**掉。所有条目统一由派发器经 `prepare → send_paste(落点 pid)` 送出（settle 250 ms、间隔 150 ms）。落点判定 = 弹窗外 `AXUIElementCopyElementAtPosition` 命中的顶层元素（返回该元素 owner pid；菜单栏/非 regular app/AX 无元素一律明示拒绝）。**旧的「前台应用 + 窗口几何」已废弃**：实测前台是 Finder、TextEdit 可见窗口在 (1200,300) 时，旧判定只查 Finder 的窗口（161..1081）→ 直接 no drop target，用户拖到可见的 TextEdit 什么都不会发生。落点应用不是前台时显式 `activate()` 并轮询确认 frontmost（最多 ~500ms）后再派发——空载荷常被 drop 拒绝，目标不会自己激活。派发前必须关闭弹窗（panel 为 key 时微信丢短粘贴）；已发送条目在整批结束时出队（不是逐条）；失败保留剩余项（`pendingBatchRetry`，下次打开历史保留一次可重试），主动打开历史取消则清空。**HUD 只说「已发送」**：`CGEventPostToPid` 成功只证明事件已投递，不证明目标消费了 ⌘V。
- **弹窗开闭打断状态机**：弹窗通过 `LifecycleState`（`closed`/`opening`/`open`/`closing`）管理生命周期，快速连续敲击快捷键在 `closing` 阶段触发 `reverseToOpen()`，直接将当前半空 alpha 平滑插值拉回 1.0 并恢复焦点，免除冷启动与视图重建闪烁。
- **弹窗背景材质与不透明度（0.112.3-dev 起）**：主弹窗与设置窗都铺了 `NSVisualEffectView`（弹窗 `.popover`、设置窗 `.underWindowBackground`，均 `blendingMode = .behindWindow`），窗口本身 `isOpaque = false` + `backgroundColor = NSColor(white: 0, alpha: 0.001)`。**不能用 `.clear`**：`.clear` 会让 AppKit 走「无背景」分支、丢掉系统圆角（实测半径 14pt 的普通 continuous 圆角，而系统是 16pt 超椭圆 squircle）；`alpha = 0.001` 保持窗口不透明性判定为「有背景」从而拿到系统圆角，视觉上仍是全透明。圆角本身**不要自己画**：去掉 `contentView` 上的 `cornerRadius`/`masksToBounds` 与 SwiftUI 根视图的 `clipShape`，全部交给窗口。`NSHostingView` 在 `.titled` 窗口上会拿到 32pt 顶部安全区，必须 `hosting.safeAreaRegions = []` 否则内容整体下移。`.titled` 窗口还让 AppKit 认为标题栏区域可拖动——`PopupHostingView` 需 `mouseDownCanMoveWindow = false`，否则在搜索框里划选文字会拖走整个窗口。**主题里因此有两个背景 token**：`popupBackground` 恒为不透明纯色，只给**有材质垫底**的表面用（主弹窗）；`popupBackgroundSolid` 保留原本的半透明值，给**没有材质**的独立面板用——大预览、更新完成窗、引导卡、快捷槽位拨盘。改动 `ColorTheme` 的 popup 背景时两边都要动，否则这些面板会突然变成纯色。**无边框的预览窗（大预览 / 侧边预览）拿不到系统圆角**：它们必须保持 `.borderless`（改成 `.titled` 会让弹窗 resign key 而关闭），因此由 `SquircleMaskView` 用 `CAShapeLayer` 自行裁剪。形状统一走 `PreviewShellGeometry`（`Preview/PreviewWindow.swift`）：**macOS 26+ 用 `ConcentricRectangle(.fixed(r))`，回落 `RoundedRectangle(.continuous)`**——两者实测逐像素等价（80pt 角框 / 8x 采样 diff = 0），所以不需要两套参数。半径常量 `PreviewShellGeometry.cornerRadius = 20`：**这是在本机 macOS 27.2.1 实测出来的**（起一个纯白 `.titled` 窗口、无阴影，2x 截图量角，系统窗口角 dx0 = 22.5pt；对 `.continuous` 扫 r=17…24，r≈21 的 rmse 最小 0.86pt，r=20 为 0.95pt，取 20 与旧值连续）。旧的 `squirclePath(radius: 19, exponent: 2.4)` 手写路径已删除：它量出来的 dx0 = 16.5pt、rmse 1.80pt，比系统小 6pt，与图片下沿的 `.continuous` 也不是同一形状（同一角框 diff 1.37%、最大错位 5.12pt，就是之前那圈「不齐的边」）。**改这个半径前先重测系统窗口**，不要凭手感调；`PreviewShellGeometry.cornerRadius` 是窗口遮罩与图片下沿的**唯一来源**，两处必须同形。快捷槽位预览走原生 `.popover`，圆角由系统提供，不要自绘。不透明度由 `@AppStorage("PopupBackgroundOpacity")` 控制（默认 `0.7`，范围 `0.30...1.0`，步进 0.1），只作用于主弹窗的 `theme.popupBackground.opacity(...)`；`accessibilityReduceTransparency` 或 `colorSchemeContrast == .increased` 时强制 1.0 并禁用滑杆（设置页的预览条与百分比标签走同一个 `effectivePopupBackgroundOpacity`，不要直接用原始值）。
- **减弱动态效果（Reduce Motion）**：所有动画统一走 `Utility/AppleMotion.swift` 的 `ReduceMotion`，**不要在调用点各写一遍判断**。`AppleMotion.snappy/smooth/tactilePress` 在开关开启时自身返回 `nil`，调用点写法不变；位移/形变/淡入淡出类走 `ReduceMotion.duration(_:)`（窗口 frame、展开动画、alpha 淡入淡出）与 `ReduceMotion.transition(_:)`（`scale`/`move` 过渡降级为 `.opacity`），缩放/模糊走 `ReduceMotion.scale(_:)` / `ReduceMotion.blur(_:)`，`symbolEffect` 走 `.reduceMotionSymbol(_:value:)`（`SymbolEffectOptions` 没有 `disable`，只能整体不施加）。**alpha 淡入淡出也要归零**——第一版按「交叉淡化替代位移」保留了 0.2s 弹窗淡入，用户开了开关仍能看到动画。**取值必须读 `CFPreferencesCopyAppValue("reduceMotion", "com.apple.universalaccess")`**：`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` 与 `@Environment(\.accessibilityReduceMotion)` **两者都在进程内缓存到退出**（实测翻转偏好后轮询 8s 恒为旧值；后者连新建的 `NSHostingView` 视图树也读到旧值），必须重启 App 才生效。**也不能只靠 `accessibilityDisplayOptionsDidChangeNotification` 刷新**——实测用户从系统设置打开开关后通知未送达、弹窗依旧带动画；现用 250ms TTL 缓存（`ReduceMotionState.current()`，`NSLock` 保护，命中 37+16ns / 未命中 314–499ns），完全不依赖通知。**窗口 frame 动画不能只把时长设 0**（0 时长仍走动画事务，completion 会晚一拍），要直接 `setFrame` 并同步调 completion；**`CABasicAnimation` 时长设 0 会被当成默认 0.25s**，须移除动画直接落终态。详见 `docs/engineering-notes.md` 的「减弱动态效果」。
- **来源应用图标预解析**：`prewarmAppIcons` 在首次快照发布时同步跑一次（22 个来源 ≈ 68ms 主线程，代价全在 `icon(forFile:)` 解码与 36×36 重绘；`urlForApplication` 本身只要 4ms）。**没有负缓存**：未命中时完整查询（扫 117 个运行中应用 + `urlForApplication`）仅 0.32ms，而真库 22 个来源全部能解析、负缓存一次都不会命中——它只对「应用已卸载」生效，却会把结果永久固化，用户重装后仍显示占位符。缓存只管命中，不管未命中。

**引导（`Onboarding/`）**：

- **非激活浮窗**（`canBecomeKey=false`）：取 key 会让弹窗失焦并被自动关闭；首击可达靠 `acceptsFirstMouse`
- **单窗口双形态**：欢迎卡片（居中 380×272）与进度卡片（右下角 320×244）是**同一个窗口**，`beginTour()` 时窗口 frame 补间与内容交叉淡入同时进行（一镜到底）。两个尺寸是显式常量而非 measured —— 形变目标必须提前可知，固定卡片高度也顺带消除了步骤间的高度跳动
- **聚光灯遮罩**（`ignoresMouseEvents=true`）：**必须点击穿透**，否则用户无法操作被高亮的控件。洞 = 目标控件，非整个弹窗
- **步骤推进**：`OnboardingGuide.record(_:)` 由真实操作事件驱动（严格顺序，不匹配则忽略）
- **光斑几何按需上报**：`SpotlightFramePreferenceKey`，仅引导期间挂 GeometryReader；行被 LazyVStack 回收时靠 `hasSelectedRow` + `lastRowRect` 区分「滚出视野」与「未选中」
- **窗口层级**：弹窗 `.floating` → 遮罩 `+1` → 引导卡片 `+2`。预览窗与弹窗同层，故在遮罩之下，需一并纳入光斑

**SwiftUI 关键机制**（详细行为见 `docs/engineering-notes.md`）：

- **弹窗开启**：窗口 alpha 淡入 0.2s easeOut，内容初始缩放 1.06→1.0（`CASpringAnimation` 接近临界无可见过冲，不走 SwiftUI `scaleEffect`）。淡入看门狗：若首帧事务未提交动画被静默丢弃，`show()` 在 0.3s 后校验并 snap 到可见
- **窗口层级不变式**：弹窗与 `.mini` / `.large` 预览窗同为 `.floating` 层；预览必须在 `NSApp.activate` 之后显式 `orderFrontRegardless()`，否则激活会把 key 窗口（弹窗）抬到同层预览之上，预览被主窗口完全遮住（鼠标点击 → 3 秒气泡自动收起 → `Space` 打开新预览时会稳定复现）。onboarding 遮罩在弹窗 `+1` 层，预览低于遮罩，层级不受影响
- **弹窗关闭**：失焦走 `closeWithAnimation()`（`fadeOutDuration = 0.15s` 与 preview `0.15s` 独立并行，0.4s Timer 保证关闭必然执行）；关闭前必须 `makeFirstResponder(nil)`，停止 macOS 15+ 文本插入光标的 120Hz `CADisplayLink`；关闭时置空 `contentView` 和 `popupHostingView`，令整棵 SwiftUI 视图图及图片引用按会话释放。拖拽后自动关闭走直接 `close()`
- **触控板双指滑动与标签页（`FilterMode` 共 6 项：`收藏 / 备注 / 全部 / 图片 / 文本 / 槽位`；默认顺序与显隐均可调，顺序/隐藏集合分别存 `FilterTabOrder` / `FilterTabHiddenTabs`，见 engineering-notes）**：`.scrollWheel` local monitor 在 ScrollView 前拦截，只认手指手势，水平 ≥50pt 且 h:v ≥ 1.5:1；切换请求在下一轮 run loop 合并，快速往返只提交最新状态；**切换 = 先滚到顶、再切 filter**（单一主流程，解决 scrollPosition 与 LazyVStack 行高估算竞速导致的滚动丢失）；**底栏数量的 `.contentTransition(.numericText())` 必须包在 `.drawingGroup()` 里**——不隔离时每次值变化会让整窗重放 display list 并滞留约 1.4MB 字形位图，隔离后原生逐位动画保留且 20 次切 Tab 零增长（详见 engineering-notes）
- **右键上下文菜单**：`PopupHostingView` 发出右键通知，SwiftUI 列表按需读取行 frame；菜单项按稳定 entry_id 重新解析行。图片行含「另存为…」，保存面板期间用 `isPresentingModalPanel` 屏蔽 resign-key 关闭
- **搜索**：统一在 Rust/SQLite 侧完成检索。正文搜索走 SQLite FTS5 trigram 索引（≥3 字符 `MATCH` + 超限行 LIKE 兜底；<3 字符 LIKE 全表扫描；LIKE 回退是有意保留的语义承诺：1-2 字符查询必须命中长文中段）。元数据字段（label、custom_label、source_name）走 LIKE 子串匹配，Swift 侧仅需按 matchIds 筛选并辅以动态日期分组（DayGroup），彻底杜绝前端多字段遍历过滤开销。**图片条目的 `label` 列恒为空**（不落库）：界面上的「Image (W×H)」是读取时由 `width`/`height` 合成的（`types.rs`），因此历史记录**不支持按尺寸搜索图片**，图片只能按 `custom_label`（备注）与 `source_name`（来源应用）命中——这是有意的产品边界，不要对外宣称按尺寸检索。
- FocusState 双管理：isSearchFocused（selectedIndex=0）和 isContainerFocused（selectedIndex>0）。Escape 三层拦截：SwiftUI `.onKeyPress` → PopupHostingView local monitor → Notification。**大预览（`.large`）仍要两步：第一次 Esc 关预览，第二次关主弹窗；只有侧边气泡（`.mini`）时 Esc 一步关闭主弹窗，气泡随弹窗一起消失**；编辑备注或粘贴队列非空时先取消该状态
- **历史列表（0.111.15 起）**：SwiftUI `ScrollView + LazyVStack`，按天使用吸顶 section header，`ItemRowView` 以稳定 entry_id 保留行身份和过渡。拖拽用 `.onDrag` 与 `NSItemProvider`，备注编辑复用行内 `InlineRemarkField`。0.111.4 的原生列表性能记录见 `docs/engineering-notes.md`
- 选中高亮：`matchedGeometryEffect` 驱动圆角高亮在行间滑动；hover 静态填充；删除模式（⌃⌫）高亮变红。**选中填充必须用 `NSColor.selectedContentBackgroundColor`（白字 5.4/6.3:1），不能用 `controlAccentColor`（白字仅 4.07:1，低于 AA）；删除红需向黑混合 22% 才够 5:1。选中行不画来源胶囊**——浅色主题的 `popupTagBackground` 是近白块，压在蓝底上很跳

**商业许可证体系已移除**（<= v0.107.10 商业版已整体移除并封存至 `archive/commercial-v0.107` 分支，当前活跃代码不含 `LicenseGateView`、在线轮询、Keychain Lease 或 Secure Enclave 设备密钥；仅 `docs/licensing-protocol.md` 与 `docs/engineering-notes.md` 保留历史归档参考）。

## FFI 接口

`SwiftApp/CopyAttach-Bridging-Header.h` 声明 **75 个** `extern "C"` 函数（与 Rust 导出 1:1 匹配：68 个在 `src/ffi/` 8 个子模块，3 个在 `src/backend.rs`，4 个在 `src/perf.rs`），涵盖生命周期、查询、快照、图片加载/预览解码、粘贴、快捷槽位、权限、删除/撤销/收藏/备注、ignore rules、备份/恢复、存储统计、历史变更事件与性能仪表。新接口需同步 `src/ffi/`（或所属 Rust 模块）、Bridging Header 与 `ClipboardBackend.swift`。

## 代码签名与数据隔离

**必须用正式签名身份构建**：ad-hoc 签名的 cdhash 每次构建都变，会影响 TCC/辅助功能授权稳定性与分发校验。`build.sh` 自动用 `security find-identity -v -p codesigning` 并按 **`Developer ID Application|Apple Development` 过滤**取第一个匹配身份（与 CI 同一套规则；过滤是必要的——不再"取第一个 codesigning 身份"，否则会静默选中无关的自签名/他人证书），找不到可用身份时仅可新建或替换 ad-hoc 产物，已有正式签名包会保留。构建在临时目录完成签名验证后原子替换旧包。构建结束会回显 `codesign -dv` 的 `Authority`/`Signature` 行供确认。

### 测试数据隔离与单实例守卫

- **数据隔离统一走 `COPYATTACH_DATA_DIR`**（`src/db/schema.rs` `get_persist_dir` 优先读取该环境变量，未设置才回退 `$HOME/Library/Application Support/CopyAttach`；仅 `src/stress/inject.rs` 默认路径仍读取 `HOME`）。压测脚本 `scripts/stress/` 与真实路径测试 `src/tests/soft_delete_real.rs` 均用 `COPYATTACH_DATA_DIR=/tmp/...` 隔离数据库，无需覆盖 `HOME`。
- **环境变量一览**：`COPYATTACH_DATA_DIR`（数据目录覆盖）、`COPYATTACH_PERF`（启用 `__CA_PERF__` 性能埋点）、`COPYATTACH_SUPPORT_DIR`（`videos/demo.sh` 隔离演示库换位路径）。
- **初始化 FFI** 为 `clipboard_init_with_threshold_and_favorites`（`src/ffi/init.rs`，不存在 `clipboard_init`）。
- **单实例守卫**：启动第二个 GUI 实例会被直接 `exit(0)` 并激活已有实例（日志出现 `Another CopyAttach instance … is running`），测试隔离实例前需先退出已有进程或只跑 Rust 测试二进制。

### GitHub Actions 分发

CI（`.github/workflows/build.yml`）签名步骤关键：`build` job 必须声明 `environment: src2release-env` 才能读到环境级 secrets；证书配了却找不到身份时显式失败（`exit 1`）；公证流程先 `build/package_dmg.sh` 打包，再 `notarytool submit` + `stapler staple` 作用于最终 DMG。

**发布仓库即源码仓库**：`release` job 直接向 `wonaren/copy-attach` 发布 Release（`GITHUB_TOKEN` + `contents: write` 即可），不再有独立公共发布仓库、跨仓库 PAT 或 README 同步 workflow。应用内更新检查/下载与 README 中的所有 Release 链接必须指向该仓库；GitHub 回退资产路径是 `releases/download/v<version>/CopyAttach-<version>-macos-<arch>.dmg`。

验证方式：`codesign -dv --verbose=4 CopyAttach.app | grep Authority` 必须是身份证书而非 `Signature=adhoc`。

## 构建依赖

- macOS 15.0+（Sequoia）
- Xcode 16+（含 macOS SDK 15.0）
- Rust 1.75+
- Swift 6+

## 测试覆盖

- Rust 单元测试：`src/tests/` 目录模块（11 个子模块：backend / backup / cleanup / db / history / image / migration / quick_slots / search / soft_delete / soft_delete_real）+ `src/bench_tests/`（cfg-gated on `test` + `stress-test`，4 个子模块：thresholds / images / memory_probe / side_table）+ 非测试模块内联 `#[test]`（29 个）。默认特性 `cargo test` 共 194 个用例（191 运行 + 3 `#[ignore]`）；启用 `--features stress-test,demo-data` 共 200 个（196 + 4 `#[ignore]`）。
- 综合压测与竞态/故障注入套件：`docs/stress-test-plan.md` 与 `scripts/stress/`（12 个脚本：`common.sh` / `prepare.sh` / `rust_suite.sh` / `data_suite.sh` / `ui_suite.sh` / `race_suite.sh` / `fault_suite.sh` / `soak_suite.sh` / `popup_cycles.sh` / `thumb_probe.sh` / `invariants.py` / `crash_scan.sh`）。

## 详细设计原理

改动以下子系统前，先读对应文档：

- `docs/engineering-notes.md`：数据库（索引上限、FTS 兜底、hash 迁移）、两阶段图片捕获与内存治理（**madvise / claim 契约——改任何大缓冲路径前必读**）、预览解码（ImageIO / `imageops::resize` 陷阱与释放）、内存基线的真相、捕获正确性（`db_id` 不变量、幽灵条目根修、自写抑制）、粘贴、原生拖拽（智能停车、松手检测）、弹窗 UI、签名与分发、以及后续 `init 失败分级` / `二进制指数退避` / `鲁棒性审查` / `事件驱动刷新` / `内存与释放语义审计`（其中许可证体系节为 <= v0.107.10 归档记录）
- `docs/design-batch-drag.md`：批量拖拽设计（v0.108.4 实装，§12/§13 修订了早期 §4.3/§6）
- `docs/stress-test-plan.md`：全链路压测、竞态、故障注入与 8 小时长跑验收门槛

### 性能测量（流畅度仪表）

改动任何热路径前后，用仪表实测而非推测。详见 `docs/perf-instrumentation.md`（格式、门禁、基线）与 `perf/BASELINE.md`（已实测基线）。

- 开启：`defaults write cc.wonaren.copyattach PerfTracing -bool true` 后 `open "CopyAttach.app"`（`open` 不继承 shell 环境变量，故用偏好而非 env）。
- 采集：`bash perf/collect.sh launch` / `smoke N` / `analyze <start_ms>`；或 `python3 perf/analyze.py /tmp/copyattach_debug.log --session-start <ms>`。
- 记录写在既有 `/tmp/copyattach_debug.log`，以 `__CA_PERF__` 开头；Rust 用 `mach_absolute_time`、Swift 用 `DispatchTime.uptimeNanoseconds`，同一单调时钟（有 G6 门禁证明）。
- 分析器先跑 9 条门禁（自检/通道/时钟对齐/开销/关闭态惰性），任一失败即判 INVALID 且返回码 2；数字不可信之前不会给出结论。

## .claude 配置

`.claude/settings.local.json` 包含命令白名单权限。新命令需要时在 `permissions.allow` 数组中添加。

## 安装的 Skills

`.claude/skills/`（软链接，实际源在 `.agents/skills/`，共 5 个）：`emil-design-eng`（UI 设计原则）；`animation-vocabulary` / `improve-animations` / `review-animations` / `find-animation-opportunities`（动画分析与改进）
