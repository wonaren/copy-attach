# 工程笔记（Engineering Notes）

本文档保存 CLAUDE.md 精简时移出的详细设计原理、实测数据与修复史。改动相关子系统前，先读对应章节。CLAUDE.md 只保留不变量结论，这里保留「为什么」。

---

## 数据库（`src/db/`）

- **禁用 mmap + 4MB LRU page cache**（`cache_size=-4096`，负数按 KiB 计 = 4MB）：FTS5 trigram 索引若被 mmap 会整段计入驻留内存，实测 ~1:1 RSS 膨胀，故全部走有界页缓存。
- **FTS 索引尺寸上限（0.99.16）**：`FTS_MAX_INDEXED_TEXT_LEN`（512K 字符）以上的 text 行不建 trigram 索引——实测索引放大 ~6.4×（10.6MB 文本 → 68MB DB）、2MB 文本同步插入 ~170ms，无上限会让大文本把捕获路径卡数百 ms 且 DB 无界膨胀；不入索引的行在 ≥3 字符查询时由 `db::search_history` 走 LIKE 兜底（只扫罕见的超大行，子串语义不丢，见 `test_fts_cap_skips_huge_text` 绊线）；触发器以 DROP+CREATE 替换旧版无上限触发器（触发器按库持久化，IF NOT EXISTS 不会更新存量），启动时清理存量超大行（幂等，`test_fts_cap_legacy_oversized_rows_evicted` 覆盖）。
- **WAL + `synchronous=NORMAL`**：捕获/粘贴的 insert+dedup+trim 合并为 `persist_entry_to_db` 单事务一次 WAL append（1 次 fsync 而非 3 次），读（搜索/缩略图）不再被写阻塞。
- **text 行持久化 preview/label/text_hash**（`hash` 列复用作 text_hash，算法为稳定 FNV-1a 64——std `DefaultHasher` 文档不保证跨版本稳定，持久化后若漂移会让旧行去重失配）。`ensure_history_table` 以 `PRAGMA user_version` 门控：0=旧库 text 逐行回填、1=0.99.15-dev 的 DefaultHasher text 值全量重算、2=text 已 FNV（同步盖 2）、3=text+image 全 FNV。冷启动 `load_history_from_db` **只读元数据列、绝不读 `text` 列**；无 preview 的 text 行视为未回填损坏，显式跳过并日志（不回读 text 兜底）。
- **图片 hash 同为 FNV-1a（`types::fnv1a`）**，旧 DefaultHasher 值的迁移（user_version 2→3）在 `ffi::init::spawn_image_hash_migration` 后台线程逐行解码重算（`schema::migrate_one_image_row`：一次只锁 DB 一行、解码在锁内逐行进行，捕获只等单行解码而非整库；每行完成后同步镜像进内存条目，同会话重复复制即时去重；完成盖 3，中断幂等重跑，不可解码行显式计数不阻塞盖章；stress-test 构建跳过——其 DB 全部新生成）。
- **dedup/trim 索引化**：`idx_history_type_hash(entry_type, hash)` 使 `delete_matching_entry` 从全表扫描变索引查找（text 仍带 exact-text 谓词兜底防 2⁻⁶⁴ 碰撞误删），`trim_db_history` 改为 `id <= (SELECT id ... OFFSET ?)` 范围删除——只触达被删行，表内 ≤阈值时子查询为 NULL 完全不扫描（原 `NOT IN` 形态每次捕获全表扫描）。
- **`migrate_from_json_to_db` 插入的旧 JSON 行同步盖 `entry_id = rowid`**——ensure 的 entry_id 回填先于迁移执行，迁移行若不盖章则每次加载都换新 ID（收藏按 entry_id 存储，重启即失效）；迁移体参数化目录（`migrate_from_json_to_db_at`，test-only 重导出），回归测试用临时目录。

## 搜索

- searchText → CJK 感知 debounce（CJK 150ms / ASCII 80ms）→ 离线线程过滤 → cached searchResults。
- 全文搜索走 SQLite FTS5 trigram 索引（`db::search_history`：≥3 字符用 `MATCH` 子串匹配 + 对超出索引上限的超大文本行做 LIKE 兜底；<3 字符退回 LIKE 全表扫描，`clipboard_search_ids` 返回匹配 entry_id）。全文只存在 DB，内存历史 Vec 不持正文（Text 条目只带 preview/label/text_hash，粘贴/预览/拖拽按 `db_id` 从 DB 按需载入，与图片同约定）。
- **LIKE 回退是有意保留的语义承诺**：1-2 字符查询必须命中长文中段（曾提议改扫内存 preview 换取无磁盘读，因静默丢失长文中段匹配被否——`test_search_short_query_matches_full_text_middle` 是语义绊线）；已知代价是首两次击键的全表扫描与 LIKE 仅 ASCII 大小写折叠。
- 标签/来源名匹配在 Swift 侧并集（`$0.label`/`$0.sourceName`，图片靠 label "Image (WxH)" 可搜），日期 label 亦在 Swift（DayGroup 是 UI 派生文本）。FTS 索引同步用 SQLite 触发器（AFTER INSERT/DELETE on `clipboard_history`，触发器 DROP+CREATE 以替换旧版无上限触发器，backfill 只跑一次且含上限条件，启动时清理存量超大行）。
- 行渲染：`ItemRowView` 无 `#` 的文本跳过正则、hex 色票 NSImage 按色值缓存（`swatchCache`，countLimit 64）——不再每帧 lockFocus 现画。搜索栏固定 index 0，项目从 index 1 开始。

## 两阶段图片捕获与内存治理

Phase 1 同步 hash + 缩略图（最长边 300px）→ 更新内存。Phase 2 异步完整 PNG 编码 → DB write-through → 更新 db_id。

- **有界背压（0.99.25-dev）**：单 worker + 单槽 `sync_channel`（`IMAGE_PHASE2_QUEUE`），编码跟不上时捕获线程在 `send()` 上显式阻塞——原 `thread::spawn` 每张图片一个线程、各自持有全分辨率 RGBA，复制速度快于编码时在途线程无界堆积，清理阈值管不住它，是「后台内存随使用时长增长」的根因之一；单槽上限 = 常驻在途最多 2 张全分辨率图（编码中 1 + 排队 1）。

### 内存治理（0.99.10）

1. 启动不做基线剪贴板读取——monitor 的 changeCount seed 已防止重启重复捕获，删除该读取消除了每次启动解码当前剪贴板图片的 ~65MB 滞留（`clipboard_init` 曾用 arboard 解码，实测空剪贴板启动 15MB vs 截图在板 93MB）。
2. 图片捕获不走 arboard（其 macOS 实现只读 `public.tiff`，22.5MB/张），改由 `macos::pasteboard_image_data()` 按 PNG→TIFF→JPEG→GIF→WebP→BMP 顺序读最小全分辨率表示（截图 PNG 仅 ~1MB）+ `image` crate 解码（CFData 释放后大块滞留 OS 不回收——实测 `malloc_zone_pressure_relief` 对之无效，故无此调用）。
3. rgba 以所有权移入 Phase 2（零拷贝，原 `to_vec()` 16MB/张）。
4. Phase 2 编码输出复用全局 scratch（`backend::ImageEncodeScratchGuard`，跨捕获保留容量，消灭每次 8MB 倍增 realloc 链；RAII drop 时若容量超过 64MB 保留上限则整池归还——一次超大图编码不得把峰值容量钉到进程退出）。

### madvise / claim 契约（0.99.17-dev 起，改任何大缓冲路径前必读）

空闲池页标记为可回收：解码池与编码 scratch 在归还池时 `madvise(MADV_FREE_REUSABLE)`（acquire 时 `MADV_FREE_REUSE` 认领）——macOS 上 freed 大块页不归还 RSS 是硬事实（实测 free/MADV_FREE/MADV_DONTNEED/malloc_zone_pressure_relief 对 `phys_footprint` 全部无效），`FREE_REUSABLE` 是唯一让页停止计入 footprint 的机制（purgeable 内存的底层实现）；两池都是「使用前全量重写」的缓冲，内核回收/清零空闲页无害。安全前提：仅标记页对齐且 ≥1 页的 mmap 大块（malloc large zone 独占页，实测本机 ≥16KB 的 malloc 分配全部页对齐），小对象共享页绝不标记。

**claim 契约（malloc 复用陷阱）**：被标记的块释放后会被 malloc 原样复用给下一次任意分配，复用后的页仍处可回收状态——不计数但可随时被内核回收（实测重写后 footprint 仍不回升），live 缓冲若落在其上会在内存压力下花屏/读零。因此**任何可能复用标记块的大缓冲在写入/读出前必须 `claim_pages`**：池 acquire ✓、`vec_to_raw` 交 Swift 前 ✓、预览 delivered 缓冲分配后 ✓、`resize_rgba` 的 tmp/out 分配后 ✓、rusqlite blob 读取后（预览 png / paste / undo / 迁移）✓、`pasteboard_image_data` 的 to_vec 后 ✓、快照 rows 交 Swift 前 ✓。

**释放侧对称（0.99.26-dev）**：claim 过的大缓冲释放前必须 `mark_pages_reusable`，否则脏页滞留 footprint——paste/undo 的 DB blob、`pasteboard_image_data` 原始字节、大文本 String（`load_text_by_db_id` 源头统一 claim）分别由 `MarkEntryBlobsReusableOnDrop`/`MarkBlobReusableOnDrop`/`MarkStringReusableOnDrop`（backend.rs）守卫覆盖全部返回路径。实测 A/B：捕获 2880×1800 截图后旧构建后台 79.6MB 永久钉住，新构建峰值 48.4MB → 空闲 28–32MB 稳定、连续捕获零累积。

**init 失败分级（0.100.12-dev）**：`clipboard_init` 返回 1/0/-1——`-1` 仅在 `SQLITE_CORRUPT`/`SQLITE_NOTADB` 时返回，表示永久性失败；Swift 侧收到 -1 置 `databaseCorrupt`、停止 5s 重试循环，弹 NSAlert「备份并重建 / 退出」，热键按下也会重弹该对话框而非显示空列表。`clipboard_recover_corrupt_db` 把 `history.db{,-wal,-shm}` 整组改名为 `history.db.corrupt-<secs>{,-wal,-shm}`——WAL/SHM 必须一起移走，否则旧 WAL 会回放到新库上再次损坏。仅在 init 返回 -1 后调用（此时无 backend 持有连接）。

**单实例检查时机（0.100.12-dev）**：SwiftUI 在任何 `NSApplicationDelegate` 回调之前就求值 `MenuBarExtra` body，`HotkeyManager.shared` 随之注册 Carbon 热键；因此单实例检查放在 `applicationDidFinishLaunching`/`WillFinishLaunching` 都太晚——重复实例会先注册热键，导致主实例（或自身）报 `-9878 eventHotKeyExistsErr`。现放在 `App.init()`（`AppDelegate.terminateIfDuplicateInstance`），实测重复实例在 `HotkeyManager init started` 之前退出。Carbon 注册遇 -9878 退避重试 5 次（0.5s 递增），耗尽后若 `AXIsProcessTrusted()` 为 false（NSEvent 兜底同样失效）才弹提示。

**池缓冲禁止 realloc 增长 + 失败不入池（0.100.11-dev）**：实测（244 次 EINVAL 日志 + 现场复现）libmalloc 就地扩展大块时会把旧映射与新页拼接为多 vm_map entry，拼出的映射对 `MADV_FREE_REUSABLE/REUSE` 报 `Invalid argument`；旧实现忽略返回值并把该块原样收回池，导致一次偶发失败后**整个进程生命周期内解码/编码池的 madvise 全部失效**（40MB 脏页常驻，「大图后内存不回落」的根因）。契约：① `decode_png_rgba8_into` / `encode_png_into` 在容量不足时整块 `Vec::with_capacity` 新分配（首次分配永远是单一映射）而非 `resize`/Cursor 倍增；② `mark_pages_reusable`/`claim_pages` 回传 `bool`，标记失败的缓冲不入池、认领失败的缓冲弃用不写入。验证：1.9MB→48MB→192MB 三级增长零失败，峰值 232MB → 空闲 42MB。

`claim_pages/mark_pages_reusable SKIP unaligned` 日志（rusqlite 读出的 18-25KB 缩略图 blob 从小区块原地增长、基址非页对齐）为良性：小 zone 共享页从未被标记，跳过即正确行为。

### 预览解码（0.99.17-dev）

预览解码走 Rust 而非 ImageIO：ImageIO 的缩略图解码把全分辨率解码 + 缩放结果留在 malloc 区永不归还（实测 8 个已释放的预览解码缓冲以 `MALLOC_LARGE (empty)` 形态滞留 ~47MB——正是「预览关闭后内存不回落」的根因）。`clipboard_decode_preview_by_db_id` 用与捕获管线相同的编解码路径（RGBA8 PNG 快路径 + 通用回退）解码并降采样到 ≤max_dim，所有中间缓冲归还时标记可回收；交付给 Swift 的是**恰好 w×h×4 的独立缓冲**，分配后即 claim。Swift 侧 `ImageDecode.previewImage` 用 `CGDataProvider(dataInfo:data:size:releaseData:)` 包成 CGImage，`PreviewBufferBox` 经 `Unmanaged.passRetained` 挂 dataInfo——CGImage 消亡（预览关闭）时回调触发 box deinit → `clipboard_preview_buffer_release`（标记可回收 + dealloc）。**交付缓冲只能经 `clipboard_preview_buffer_release` 释放，绝不能用 `clipboard_free_bytes`（两者 Layout 不同）。**

**关闭路径强制释放（0.99.25-dev）**：`PreviewWindow.close()` 先 `hostingView.rootView = AnyView(EmptyView())` + `hostingView = nil` 再 `contentView = nil`——contentView 不是唯一持有者，窗口自身强持有 hostingView，其 rootView 上的 `PreviewContent.image` 不拆会随窗口存活到下次打开；配套 `onDisappear { image = nil }` 兜住任务取消间隙。

**imageops::resize 陷阱**：`image` crate 的 `resize`（CatmullRom/Lanczos3）内部经 `Rgba32FImage`（width×height×16 字节）中转——2940×1846→2048 预览一次分配 60.5MB f32 缓冲且释放后永不归还（malloc_history 定位）；预览路径与捕获 Phase 1 缩略图（0.99.26-dev，`create_thumbnail_fast`）均改用自研两遍 CatmullRom u8 resize（`image::resize_rgba`，水平过渡带标记可回收，直通 alpha 不预乘），缩略图尺寸逻辑（`thumbnail_target_dims`）不变。GIF blob（`out_is_gif`）仍走 `NSImage(data:)` 保动画（历史存量，现行存储一律 PNG）。

### 内存基线的真相（勿再追查）

干净进程空闲 19MB → 弹窗开 +20MB → 关闭后一次性保留 ~17MB 不再回落，**绝非泄漏**——heap 证实无 `MALLOC_LARGE` 残留、连续多会话零累积（37→42→39→38MB 噪声内恒定）。构成 = 框架一次性热缓存 ~7MB（字体/字形位图/类元数据/SwiftUI+AttributeGraph 表/CoreSVG）+ malloc 小 zone 游离脏页高水位 ~6-10MB。实测 macOS 无任何机制回收小 zone 这部分（`malloc_zone_pressure_relief` 两种时点、空页延迟自回收全部无效）——~36-40MB 是此 SwiftUI app 的稳定底线。另有两点按设计钉内存：撤销栈 ≤1 条载荷（单条 ≤48MB）、缩略图 NSCache 10MB。PopupHostingView 刻意跨会话复用（3000 行 LazyVStack 每次重建 35.8MB vs 复用 15.8MB，复用是设计而非泄漏）。

用户实测（0.99.17-dev 仪器化会话）：基线 39MB → 预览 2880×1800 大图 71MB（峰值 113MB 瞬时解码）→ Esc 关预览 46MB（立即回落 25MB）→ 关弹窗 44MB → 稳定 44MB。诊断日志覆盖每条路径：`preview_decode done` / `preview_buffer_release` / `decode_scratch drop … mark_reusable` / `undo_push … total_payload_bytes`。长会话 125MB 进程 = 44MB 稳态 + 撤销栈持有被删大图载荷（按设计）+ 多会话滚动 churn——无预览链残留。

## 捕获正确性

- **db_id 不变量（幽灵条目根修，0.99.13）**：内存条目的 `db_id` 必须指向 DB 中该条目的行，且赋值必须按内容身份匹配、绝不按头部位置——文本捕获曾用 `hist.get_mut(0)` 无条件写头部条目：并发 select-and-paste/undo 在锁间隙把别的条目移到头部时，本次捕获条目 db_id 保持 0（列表可见但无法预览/粘贴/删除被拒），头部条目被指向他人行，后续删除会误删该条目的行（symptom：DB 主表+FTS 双查无此文本、entry_id 连续缺失）。修复：`history::assign_db_id_by_text_hash` 按 hash 匹配赋值（与图片 Phase 2 对称），3 个回归测试覆盖头部竞争/头部正常/无匹配 no-op。配套：Rust eprintln 此前被 launchd 丢弃——AppDelegate 启动 `dup2` stderr → `/tmp/copyattach_debug.log`，Rust 侧失败从此可见。
- **db_id 写穿的锁契约（0.101.8-dev）**：任何「写 DB 行 → 把行号写进内存条目」的路径必须**持 DB 锁跨过内存写**。粘贴路径曾是唯一例外（`persist_entry_to_db` 提交后释放 DB 锁、再单独 `add_to_history`）：同内容并发写者（monitor 捕获 / 图片 Phase 2——两者都被粘贴的 DB 锁挡住，粘贴一释放就立刻拿到锁）可在两步之间 INSERT 新行、去重掉粘贴刚写的行，其按 hash 的赋值先写进内存，随后又被粘贴迟到的内存写穿用**已删除**的行号覆盖 → 内存条目指向不存在的行（列表可见、预览/粘贴/删除全失败，DB 侧留一行孤儿）。窗口极窄（仅当粘贴线程在 DB 解锁与 history 加锁之间被抢占时才成立），故表现为「偶发一次、长期不复现」；8/30 的 db_id=1153 幽灵条目即此。四类写者（文本捕获、图片 Phase 2、undo、粘贴）现全部满足该契约。
- **Suppress re-capture**：select_and_paste 先通过 `pasteboard_event_lock` + `pending_self_write` 标记自身的粘贴板写入，监控线程发现匹配的 changeCount 时跳过。不依赖内容比对。
- **HISTORY_REVISION**：去重时条目数不变但顺序变了——UI 通过此计数器感知「需要刷新列表」而不仅仅是 count 变化。
- **undo 删除**：通过 `clipboard_last_restored_id()` 精确定位恢复项，避免监控线程插入竞争。撤销栈 `push_deleted` 双上限：最多 `DELETE_STACK_LIMIT`(1) 条 + 总字节 `MAX_UNDO_BYTES`(48MB，文本正文与图片 png+thumb blob 统一计入——撤销栈是唯一能累积完整载荷的地方，图片不计数曾可无界钉住数百 MB）。`clipboard_delete_by_id` 入栈为移动语义（原 `entry.clone()` 每次删除多一次全 PNG memcpy，峰值翻倍）。

## 粘贴

- **select_and_paste 流程**：先查 accessibility 权限（`macos::check_permission`），未授权直接 return 0 且不动剪贴板——Cmd+V 无权限必然失败，先覆盖用户剪贴板只会毁掉其内容（临时 PNG 60s 后被 TTL 清理成死路径），且旧逻辑 fall-through 返回 1 被 Swift 误判为粘贴成功并关闭弹窗 → 查 history（by entry_id）→ DB 加载 png_data（加载失败显式 return 0 + 日志，不用内存副本兜底）→ 写系统剪贴板（设 pending_self_write）→ DB write-through → move entry to top → sleep 50ms → Cmd+V。
- **图片粘贴走唯一的文件路径模式**：图片一律先写入 `$TMPDIR/CopyAttach/Paste/` 临时 PNG，剪贴板只放 `public.file-url`（Finder「复制文件」同款约定，`macos::set_pasteboard_file_url`）再 Cmd+V——终端将其翻译为路径文本，TUI Agent 直接消费，聊天/笔记类 app 粘贴为文件；不区分终端与非终端，无开关。
- **粘贴目标 pid 不变式**：Cmd+V 用 `CGEventPostToPid` 投递给 `source_app.pid`（`clipboard_set_source_app` 由 Swift 事件驱动更新：`NSWorkspace.didActivateApplicationNotification` + 启动时种子值——0.99.11 起不再 0.3s 轮询，每次 `NSRunningApplication` 属性访问都触发 LaunchServices 同步 XPC，实测 10 小时轮询在 LS 客户端累积 ~115MB）。该 pid 必须是用户打开弹窗前的 app，绝不能是 CopyAttach 自身。预览窗口通过 `NSApp.activate(ignoringOtherApps:)` 真实激活才能收到捏合手势（LSUIElement agent 在 nonactivating panel 上浮期间从不收到 applicationDidBecomeActive，`NSApp.isActive` 误报 true），这会让 agent 成为前台应用——`updateSourceApp()` 检测到自 pid 时直接跳过覆盖，保留上一应用为粘贴目标。

## 原生拖拽

- 文本→`NSItemProvider(object:)`，图片→临时 PNG 文件 (`public.file-url`)。窗口拖动区限制为 PopupHostingView 外 3pt 边框，避免行拖拽误触窗口移动。
- 拖拽结束检测用 `NSEvent.pressedMouseButtons` 轮询（40ms Timer，注册 `.common` + `.eventTracking` 双 run loop 模式）——拖拽期间 run loop 处于 `NSEventTrackingRunLoopMode`，global/local monitor 收不到 mouse-up（官方文档确认），Timer 是可靠信号。
- **拖拽在途弹窗智能停车**（`tickDragParking`，与松手检测共用 40ms tick）：按屏幕 45%:10%:45% 分区，鼠标在右侧 45% 时弹窗停靠左边缘、左侧 45% 时停靠右边缘，中间 10% 为死区不动；同侧小幅晃动不触发横跳。`park(at:)` 用 `animator().setFrame`（无边框 NSPanel 上 `setFrameOrigin` 静默不动画）；`tickParkingSlide` 侦测 CA 事务停顿（事件跟踪模式下帧动画可能卡死，3 tick 无位移即 `setFrameOrigin` 直接落位）。拖拽结束时开关关闭走 `restoreFromParking()` 滑回居中；`show()`/`close()`/`completeItemDrag` 均 `resetDragParking()`。
- 开关「拖拽后自动关闭弹窗」（`ClosePopupAfterDrag`，默认开）开启时，拖拽结束直接 `close()`——与 Esc 相同路径，无动画、无 completion 依赖。

## 弹窗 UI

- **开启（对齐 Spotlight）**：窗口 alpha 淡入 0.2s easeOut，`show()` 在 `orderFrontRegardless()` 后同步执行——刻意不放进 `DispatchQueue.main.async`（async 实测排在 SwiftUI 首帧渲染之后，启动死区 ~40-90ms）；内容侧 `scaleEffect` 1.10→1.0，`spring(response: 0.2, dampingFraction: 0.85)`。**淡入看门狗**：若窗口首帧事务未提交时动画被静默丢弃，弹窗会以 alpha 0 常驻屏幕（可稳定复现）——`show()` 在 `fadeInDuration + 0.1s` 后校验 `isVisible && closeGuaranteeTimer == nil && alphaValue < 0.5`，命中则 snap 到可见；焦点延迟 `openDuration + 0.05`。
- **关闭**：普通失焦/点击外部走 `closeWithAnimation()`（popup 0.12s fade 与 preview 0.1s fade 独立并行，另有 `.common` + `.eventTracking` 双模式 Timer 0.4s 保证关闭必然执行——CA completion 在事件跟踪模式下不可靠）；拖拽后自动关闭走直接 `close()`。
- **选中高亮**：`matchedGeometryEffect(id: "itemSelectionHighlight")` 在行间滑动；hover 静态填充；删除模式（⌃⌫）高亮变红。
- **行文本 = 有界 preview 的 head……tail**：Rust `bounded_preview` 已把长文本折成 `前 180 标量……后 74 标量`（`PREVIEW_SCALARS=256`），Swift `ClipboardItem.formatDisplayPreview` 再按视觉宽度切成 `25……25`。**折叠必须遍历整段 preview**：0.100.8 为省分配加的 `collapsed.count >= 60 { break }` 会在切分之前砍掉尾部窗口，导致行尾显示的其实是头部中段（"首尾字符"退化成"首部中段"）。行内分配本身有界（preview ≤256 标量，且每次快照解码只算一次），所以提前退出换不来任何可测收益；空白分隔符延迟到下一个可见字符才落地（`pendingSeparator`），否则复制来的源文件几乎都以换行结尾，尾窗口会被一个 `⏎` 吃掉 2 个视觉宽度；预览面板传全文的那次调用已改为沿用列表的 displayPreview（面板只渲染 `item.preview` 全文，从不读该字段）。
- **Escape 三层拦截**：SwiftUI `.onKeyPress(.escape)` → PopupHostingView NSEvent local monitor（NSTextView 第一响应者时）→ Notification 转发。优先关预览，否则关弹窗。
- FocusState 双管理：isSearchFocused（selectedIndex=0）和 isContainerFocused（selectedIndex>0），解决 TextField focus 接管后 onKeyPress 失效。

### 触控板双指滑动切换标签页

PopupHostingView 的 `.scrollWheel` local monitor 在 ScrollView 消费事件之前拦截——只认手指手势（`event.phase != []`），鼠标滚轮/惯性动量忽略；水平位移累积 ≥50pt 且水平:垂直 ≥ 1.5:1 即在手势中途提交切换（不等松手），累积前按 `isDirectionInvertedFromDevice` 还原手指实际方向；监视器只认弹窗自身窗口的事件（`event.window === self.window`）；事件只在提交切换后才吞掉，提交前全部透传——未达阈值的横滑不产生冻结死区；`.stationary` 保留累积进度不重置（`.began` 每个手势只来一次）；`menuTracking` 期间让位。手势中途反向重定向：当前事件横向位移与已累积方向相反、且达到已累积量的 0.5 时丢弃旧 run 重新累积。

**切换动画为同源数据重过滤**（不做翻页滑动）：行按 `entry_id` 保持稳定身份，被过滤掉的行就地溶解（透明度 + 0.96 缩放）、新行就地浮现、幸存行无过渡原地不动，仅随列表坍缩上移（`filterSwitchAnimation(removed:added:)` 自适应时长：基础 `easeOut(0.15s)`，按变更行数线性加时至 0.28s；标签胶囊 `.easeOut(0.08s)` 即时响应）。

**切换 = 先滚到顶、再切 filter**（单一主流程）：先把 `scrollTarget` 指向列表顶部锚点（`listTopAnchorID`，LazyVStack 上方恒 0 高普通视图——始终被布局，不依赖未物化行的行高估算），再在下一个 runloop turn 切换 `filterMode`。原因：滚动与内容变化同事务时，scrollPosition 与 LazyVStack 行高估算和 ScrollView 偏移保持竞速——实测滚动完全丢失或反复振荡（offset 1261→0→541→0→289），按住 ↓ 深滚后立刻切换可稳定复现。切标签后 `onChange(of: filterMode)`：关预览；`selectedIndex != 0` 时重置为新列表第一条，空列表落回搜索栏；搜索框聚焦时不预滚。滚动靠 `.scrollPosition(id: $scrollTarget)`，无 ScrollViewReader/`scrollTo`。

### 右键上下文菜单

`PopupHostingView.rightMouseDown` 只发 `popupContextMenuNotification`（`.global` 坐标；NSHostingView `isFlipped=true`，`convert(_:from:nil)` 与 `.global` 同坐标系）→ 置 `contextMenuArmed`，行 frame 按需一次性快照（`RowFramePreferenceKey`：仅武装期间行才挂 GeometryReader）——滚动全程无每行几何上报开销，菜单延迟仅一帧；`resolveContextMenu` 在下一 runloop 回合 `showContextMenu`（`NSMenu.popUp` 不能在 SwiftUI 布局中途开始）。菜单项 handler 用 `ContextMenuItemTarget`（`NSMenuItem.target` 是 weak，靠 `representedObject` 强持有）；动作一律 `currentIndex(of:)` 按稳定 entry_id 重新解析行。菜单 tracking 期间（`isMenuTracking`）Esc/←/→/⌘Z 全让位。图片行含「另存为…」（NSSavePanel 写 PNG）：保存面板是本应用的模态窗口，必然从非激活弹窗夺走 key——弹窗靠 `isPresentingModalPanel` 屏蔽这次 resign-key 的关闭（弹窗留在面板后方继续显示），`runModal()` 返回后 `makeKey()` 交还 key 状态。**不得在调起面板前 `close()`/`onClose()` 收起弹窗**（0.100.10 曾如此，实为把弹窗在保存过程中异步销毁）。

## 许可证体系

- **激活庆祝时序**（三方协作）：激活成功且从未许可→有许可时，`LicenseManager.perform` 设置 `celebration` 并调 `licenseCelebrationDidStart()`，暂不关窗；`LicenseGateView` 观察到 celebration 后隐藏表单、窗口内播 `LicenseCelebrationView`（约 2s）；结束后 `finishCelebration()` → `AppDelegate.licenseCelebrationFinished()` 只启动 Rust 后端、不关窗——门禁回到激活确认视图，用户手动关闭（已许可时关闭不退出）。`startEntitlementTimer` 在 celebration 期间跳过维护续租。
- **在线状态轮询（仅试用/订阅）**：每 120s 向 `POST /v1/licenses/status` 或 `POST /v1/trials/status` 查询（无需签名）。后台暂停/撤销/到期在 ≤2 分钟内生效。**永久许可证不安排任何周期性检查**——签名 + 设备绑定即权威，`apply()` 时 `nextRefreshAt`/`nextStatusCheckAt` 置 nil。**关键约定**：只有服务器明确返回非活跃状态才降级；`not_found` 和网络失败一律忽略，离线 Lease 仍权威，不惩罚用户。
- **设备身份与重新激活**：设备身份 = Secure Enclave P-256 密钥对（`DeviceIdentity`），`device_id = "sha256:" + base64url(SHA256(公钥))`；物理设备另用 `hardware_anchor`（哈希后的平台 UUID）标识。误删钥匙串后同一台 Mac 重新激活时，服务器按 `license_id + hardware_anchor` 自动换绑、不消耗新座位；试用仍按 hardware_anchor 一次性计。
- **版本过旧引导**：所有许可证请求附带 `app_version`；服务端返回 `APP_VERSION_TOO_OLD` 时映射为 `EntitlementState.needsUpdate`（该错误码未收录进 `docs/licensing-protocol.md`，以代码为准）。
- **激活窗口尺寸陷阱**：`LicenseGateView` 必须固定 `.frame(width: 500, height: 470)`，否则庆祝内容替换表单时窗口被 AppKit fitting-size 压缩、错位到屏幕角落；`showLicenseGate()` 在 `makeKeyAndOrderFront` 后需再次 `setContentSize` + `center()`。
- 设置页永久许可证只显示「永久权益 · 最多 N 台设备」（刻意不展示联网验证期限）。

### 生产构建配置

生产配置内置为默认值，直接 `./build.sh` 即连接生产服务器。license-server 服务端代码不在本仓库（本机开发部署在 `~/copy-attach-license/`，生产在 `api.abovepast.shop`）。

```bash
# 本地开发
LICENSE_ENV=local COPYATTACH_LICENSE_PUBLIC_KEY='<dev 公钥>' ./build.sh

# 显式覆盖生产参数
COPYATTACH_LICENSE_SERVER_URL='https://api.abovepast.shop' \
COPYATTACH_LICENSE_KEY_ID='production-2026-08' \
COPYATTACH_LICENSE_PUBLIC_KEY='efsKYx9a7urNlr-UXR7b0-Fl9w0mJNKe3RME-OeseOs' \
./build.sh
```

参数写入 App bundle 的 `Info.plist`（`CopyAttachLicenseServerURL/KeyID/PublicKey`），源码里的 `Info.plist` 不保留（构建后回删）；`LicenseConfiguration`（`LicenseLeaseVerifier.swift`）保留同一套生产值作为回退。协议细节见 `docs/licensing-protocol.md`。

## 签名与分发

### 钥匙串弹窗

钥匙串条目（Lease + 设备密钥，svce=`com.example.copyattach.licensing`）按创建应用的代码签名授权。**必须用正式签名身份构建**：ad-hoc 签名的 cdhash 每次构建都变，导致每次重开 App 都弹钥匙串授权（可能弹两次）。用正式身份后首次启动点一次「始终允许」即永久免弹。build.sh 自动用 `security find-identity` 找 Apple Development 身份，找不到才回退 ad-hoc。

### GitHub Actions 分发

CI（`.github/workflows/build.yml`）已修复的关键坑：

1. **环境级 secrets 对 job 不可见**：签名步骤所在 `build` job 必须声明 `environment: src2release-env` 才能读到 `MACOS_CERTIFICATE` 等 secrets，否则静默跳过、产物为 ad-hoc。
2. **步骤级 `if: env.MACOS_CERTIFICATE != ''` 永远为 false**：`if` 条件看不到步骤自己的 `env:` 映射。改为步骤始终运行 + 脚本内 `[ -z ]` 守卫。
3. **证书配了却找不到身份时显式失败**（`exit 1`）：避免静默发布 ad-hoc 产物。
4. **公证流程**：先 `build/package_dmg.sh` 打包，再 `notarytool submit` + `stapler staple` 作用于最终 DMG（需 Developer ID + `MACOS_NOTARIZATION_ACCOUNT/PWD/APPLE_TEAM_ID` secrets）。

验证：`codesign -dv --verbose=4 CopyAttach.app | grep Authority` 必须是身份证书而非 `Signature=adhoc`；`codesign --verify --deep --strict` 通过。

## 其他前端细节

- Swift 解码一律离主线程（0.99.16）：列表行缩略图经 `ClipboardBackend.loadThumbnail`（Task.detached 内 FFI 读 + PNG 解码 → 10MB NSCache），行 body 只做同步 NSCache 命中检查；预览大图经 `ImageDecode.previewImage`（预算 = 显示尺寸×scale 与 2048px 的较小值）。
- `AppIcon+Ext.swift`：bundleId → 36pt 单尺寸图标缓存（NSWorkspace 图标多尺寸全量可达数百 KB/张，18pt 行只用 36px，缓存前降采样）。
- 日期分组：`DayGroup` 按日历日分组，`PopupRow` 在扁平列表中渲染分隔符+条目行。底栏计数用 `.contentTransition(.numericText())`。
- swiftc 必须 `-O -whole-module-optimization`——缺省 `-Onone` 会让 SwiftUI 前端全速跑在未优化代码上（build.sh 已处理）。
