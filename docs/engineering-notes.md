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
- 元数据字段匹配（label、custom_label、source_name）统一在 Rust/SQLite 侧由 LIKE 子串检索完成（图片条目 label 列恒为 NULL 不落库，不支持按尺寸检索，图片按备注与来源应用匹配），Swift 侧仅需按 matchIds 筛选并辅以动态日期分组（DayGroup 是 UI 派生文本）。FTS 索引同步用 SQLite 触发器（AFTER INSERT/DELETE on `clipboard_history`，触发器 DROP+CREATE 以替换旧版无上限触发器，backfill 只跑一次且含上限条件，启动时清理存量超大行）。
- 行渲染：`ItemRowView` 无 `#` 的文本跳过正则、hex 色票 NSImage 按色值缓存（`swatchCache`，countLimit 64）——不再每帧 lockFocus 现画。搜索栏固定 index 0，项目从 index 1 开始。

## 两阶段图片捕获与内存治理

Phase 1 同步 hash + 缩略图（fit 进显示框 920×200px = 460×100pt @2×）→ 更新内存。Phase 2 异步完整 PNG 编码 → DB write-through → 更新 db_id。

- **缩略图尺寸 = 行显示框（0.105.1 修复扁长图模糊）**：旧规则是「最长边压到 300、短边托底 max_dim/5、长边再 cap 900」，但 Swift 显示端又无条件按最长边 160px 重采样，把托底彻底抹掉。扁图（如 3000×100）被解成 160×5 后按 ~460pt 行宽绘制，放大 ~5.75× ——这就是「越扁越糊」。现改为两端共用同一**矩形框** `THUMB_BOX_W×THUMB_BOX_H`(920×200)：Rust `thumbnail_target_dims` 按框做等比 fit 生成存储 blob，Swift `RowThumbnailBox` 按当前 screen scale 计算框并把 fit 换算成 ImageIO 的唯一 long-edge 参数（`bound(for:)`）。**轴是宽/高，不是长/短边**：按长/短边匹配会让竖图被 920 那一侧兜底而纵向溢出（实测 1362×1774 → 200×260 超出 200 高）。实测（真库副本 137 行）：3000×100 由放大 5.75× → 1.00×，1920×1080 由 2.22× → 1.00×。存储端常量与 Swift 端必须同步修改。

- **缩略图迁移的内存纪律（0.105.1，踩坑记录）**：user_version 3→4 会把历史缩略图按新显示框重编码。首版实现有三个内存错误，均实测定位（真库副本 137 行，release，`/usr/bin/time -l` 峰值 RSS）：
  1. 用普通 `decode_png`（`load_from_memory` + `to_rgba8` 拷贝）解码全分辨率 PNG，绕过了本仓库对大缓冲的 madvise 契约（claim / mark reusable / 池化）——峰值 **323MB**，而该 pass 为 no-op 时仅 19MB。
  2. 每行 `SELECT png_data` 都新建一个 4–7MB `Vec`，137 行不同尺寸的分配让 malloc 产生大量 large 块；释放后因未被标记而滞留（`Malloc Large (Reusable)` 实测 132MB）。
  3. 借用了捕获管线的单槽解码池 `ImageDecodeBuffer`——一个一次性启动 pass 把迁移尺寸的缓冲留在池里整个会话，并且让 `backend::test_image_decode_buffer_pool_lifecycle` 稳定失败（8/8，与 `--test-threads=1` 无关，是跨测试对进程级池的耦合）。
  修法：迁移自带 caller-owned 的可复用 blob/scratch（两者 end 时显式 `mark_pages_reusable`）、编码产物走 `MarkBlobReusableOnDrop`、**按源尺寸降序遍历**（让可复用缓冲一次到达高水位后被复用，而非随行尺寸来回 ratchet；仅此一项就把峰值 156→79MB）。最终：峰值 **79MB**、稳态回落至与 no-op 相当（~9–18MB vs ~8.7MB）。**教训：任何遍历全库大 blob 的 pass 都必须自己持有缓冲并显式归还，且顺序会影响峰值。**

- **有界背压（0.99.25-dev）**：单 worker + 单槽 `sync_channel`（`IMAGE_PHASE2_QUEUE`），编码跟不上时捕获线程在 `send()` 上显式阻塞——原 `thread::spawn` 每张图片一个线程、各自持有全分辨率 RGBA，复制速度快于编码时在途线程无界堆积，清理阈值管不住它，是「后台内存随使用时长增长」的根因之一；单槽上限 = 常驻在途最多 2 张全分辨率图（编码中 1 + 排队 1）。

### 内存治理（0.99.10）

1. 启动不做基线剪贴板读取——monitor 的 changeCount seed 已防止重启重复捕获，删除该读取消除了每次启动解码当前剪贴板图片的 ~65MB 滞留（`clipboard_init` 曾用 arboard 解码，实测空剪贴板启动 15MB vs 截图在板 93MB）。
2. 图片捕获不走 arboard（其 macOS 实现只读 `public.tiff`，22.5MB/张），改由 `macos::pasteboard_image_data()` 按 PNG→TIFF→JPEG→GIF→WebP→BMP 顺序读最小全分辨率表示（截图 PNG 仅 ~1MB）+ `image` crate 解码（CFData 释放后大块滞留 OS 不回收——实测 `malloc_zone_pressure_relief` 对之无效，故无此调用）。
3. rgba 以所有权移入 Phase 2（零拷贝，原 `to_vec()` 16MB/张）。
4. Phase 2 编码输出复用全局 scratch（`backend::ImageEncodeScratchGuard`，跨捕获保留容量，消灭每次 8MB 倍增 realloc 链；RAII drop 时若容量超过 64MB 保留上限则整池归还——一次超大图编码不得把峰值容量钉到进程退出）。

### madvise / claim 契约（0.99.17-dev 起，改任何大缓冲路径前必读）

空闲池页标记为可回收：解码池与编码 scratch 在归还池时 `madvise(MADV_FREE_REUSABLE)`（acquire 时 `MADV_FREE_REUSE` 认领）——macOS 上 freed 大块页不归还 RSS 是硬事实（实测 free/MADV_FREE/MADV_DONTNEED/malloc_zone_pressure_relief 对 `phys_footprint` 全部无效），`FREE_REUSABLE` 是唯一让页停止计入 footprint 的机制（purgeable 内存的底层实现）；两池都是「使用前全量重写」的缓冲，内核回收/清零空闲页无害。安全前提：仅标记页对齐且 ≥1 页的 mmap 大块（malloc large zone 独占页，实测本机 ≥16KB 的 malloc 分配全部页对齐），小对象共享页绝不标记。

**claim 契约（malloc 复用陷阱）**：被标记的块释放后会被 malloc 原样复用给下一次任意分配，复用后的页仍处可回收状态——不计数但可随时被内核回收（实测重写后 footprint 仍不回升），live 缓冲若落在其上会在内存压力下花屏/读零。因此**任何可能复用标记块的大缓冲在写入/读出前必须 `claim_pages`**：池 acquire ✓、`vec_to_raw` 交 Swift 前 ✓、预览 delivered 缓冲分配后 ✓、`resize_rgba` 的 tmp/out 分配后 ✓、rusqlite blob 读取后（预览 png / paste / undo / 迁移）✓、`pasteboard_image_data` 的 to_vec 后 ✓、快照 rows 交 Swift 前 ✓。

**释放侧对称（0.99.26-dev）**：claim 过的大缓冲释放前必须 `mark_pages_reusable`，否则脏页滞留 footprint——paste/undo 的 DB blob、`pasteboard_image_data` 原始字节、大文本 String（`load_text_by_db_id` 源头统一 claim）分别由 `MarkImageBlobsReusableOnDrop`/`MarkBlobReusableOnDrop`/`MarkStringReusableOnDrop`（backend.rs）守卫覆盖全部返回路径（原文此处写作 `MarkEntryBlobsReusableOnDrop`，该类型不存在，已按实际守卫名修正）。实测 A/B：捕获 2880×1800 截图后旧构建后台 79.6MB 永久钉住，新构建峰值 48.4MB → 空闲 28–32MB 稳定、连续捕获零累积。

**init 失败分级（0.100.12-dev；0.105.4-dev 扩展为 1/0/-1/-2，详见「init 失败分级（0.105.4-dev）」）**：`clipboard_init` 返回 1/0/-1——`-1` 仅在 `SQLITE_CORRUPT`/`SQLITE_NOTADB` 时返回，表示永久性失败；Swift 侧收到 -1 置 `databaseCorrupt`、停止 5s 重试循环，弹 NSAlert「备份并重建 / 退出」，热键按下也会重弹该对话框而非显示空列表。`clipboard_recover_corrupt_db` 把 `history.db{,-wal,-shm}` 整组改名为 `history.db.corrupt-<secs>{,-wal,-shm}`——WAL/SHM 必须一起移走，否则旧 WAL 会回放到新库上再次损坏。仅在 init 返回 -1 后调用（此时无 backend 持有连接）。

**单实例检查时机（0.100.12-dev）**：SwiftUI 在任何 `NSApplicationDelegate` 回调之前就求值 `MenuBarExtra` body，`HotkeyManager.shared` 随之注册 Carbon 热键；因此单实例检查放在 `applicationDidFinishLaunching`/`WillFinishLaunching` 都太晚——重复实例会先注册热键，导致主实例（或自身）报 `-9878 eventHotKeyExistsErr`。现放在 `App.init()`（`AppDelegate.terminateIfDuplicateInstance`），实测重复实例在 `HotkeyManager init started` 之前退出。Carbon 注册遇 -9878 退避重试 5 次（0.5s 递增），耗尽后若 `AXIsProcessTrusted()` 为 false（NSEvent 兜底同样失效）才弹提示。

**池缓冲禁止 realloc 增长 + 失败不入池（0.100.11-dev）**：实测（244 次 EINVAL 日志 + 现场复现）libmalloc 就地扩展大块时会把旧映射与新页拼接为多 vm_map entry，拼出的映射对 `MADV_FREE_REUSABLE/REUSE` 报 `Invalid argument`；旧实现忽略返回值并把该块原样收回池，导致一次偶发失败后**整个进程生命周期内解码/编码池的 madvise 全部失效**（40MB 脏页常驻，「大图后内存不回落」的根因）。契约：① `decode_png_rgba8_into` / `encode_png_into` 在容量不足时整块 `Vec::with_capacity` 新分配（首次分配永远是单一映射）而非 `resize`/Cursor 倍增；② `mark_pages_reusable`/`claim_pages` 回传 `bool`，标记失败的缓冲不入池、认领失败的缓冲弃用不写入。验证：1.9MB→48MB→192MB 三级增长零失败，峰值 232MB → 空闲 42MB。

`claim_pages/mark_pages_reusable SKIP unaligned` 日志（rusqlite 读出的 18-25KB 缩略图 blob 从小区块原地增长、基址非页对齐）为良性：小 zone 共享页从未被标记，跳过即正确行为。

### 预览解码（0.99.17-dev）

预览解码走 Rust 而非 ImageIO：ImageIO 的缩略图解码把全分辨率解码 + 缩放结果留在 malloc 区永不归还（实测 8 个已释放的预览解码缓冲以 `MALLOC_LARGE (empty)` 形态滞留 ~47MB——正是「预览关闭后内存不回落」的根因）。`clipboard_decode_preview_by_db_id` 用与捕获管线相同的编解码路径（RGBA8 PNG 快路径 + 通用回退）解码并降采样到 ≤max_dim，所有中间缓冲归还时标记可回收；交付给 Swift 的是**恰好 w×h×4 的独立缓冲**，分配后即 claim。Swift 侧 `ImageDecode.previewImage` 用 `CGDataProvider(dataInfo:data:size:releaseData:)` 包成 CGImage，`PreviewBufferBox` 经 `Unmanaged.passRetained` 挂 dataInfo——CGImage 消亡（预览关闭）时回调触发 box deinit → `clipboard_preview_buffer_release`（标记可回收 + dealloc）。**交付缓冲只能经 `clipboard_preview_buffer_release` 释放，绝不能用 `clipboard_free_bytes`（两者 Layout 不同）。**

**关闭路径强制释放（0.99.25-dev）**：`PreviewWindow.close()` 先 `hostingView.rootView = AnyView(EmptyView())` + `hostingView = nil` 再 `contentView = nil`——contentView 不是唯一持有者，窗口自身强持有 hostingView，其 rootView 上的 `PreviewContent.image` 不拆会随窗口存活到下次打开；配套 `onDisappear { image = nil }` 兜住任务取消间隙。

**imageops::resize 陷阱**：`image` crate 的 `resize`（CatmullRom/Lanczos3）内部经 `Rgba32FImage`（width×height×16 字节）中转——2940×1846→2048 预览一次分配 60.5MB f32 缓冲且释放后永不归还（malloc_history 定位）；预览路径与捕获 Phase 1 缩略图（0.99.26-dev，`create_thumbnail_fast`）均改用自研两遍 CatmullRom u8 resize（`image::resize_rgba`，水平过渡带标记可回收，直通 alpha 不预乘），缩略图尺寸逻辑（`thumbnail_target_dims`）不变。GIF blob（`out_is_gif`）仍走 `NSImage(data:)` 保动画（历史存量，现行存储一律 PNG）。

### 内存基线的真相（勿再追查）

干净进程空闲 19MB → 弹窗开 +20MB → 关闭后一次性保留 ~17MB 不再回落，**绝非泄漏**——heap 证实无 `MALLOC_LARGE` 残留、连续多会话零累积（37→42→39→38MB 噪声内恒定）。构成 = 框架一次性热缓存 ~7MB（字体/字形位图/类元数据/SwiftUI+AttributeGraph 表/CoreSVG）+ malloc 小 zone 游离脏页高水位 ~6-10MB。实测 macOS 无任何机制回收小 zone 这部分（`malloc_zone_pressure_relief` 两种时点、空页延迟自回收全部无效）——~36-40MB 是此 SwiftUI app 的稳定底线。另有两点上限：撤销栈（≤1 条，**载荷落盘**、内存只留路径——实测删掉 4.19MB 大图后 footprint 反降 7MB，此条取代早期"按设计钉内存"的说法）、缩略图 NSCache（countLimit 120 / 8MB；0.105.2 修越扁越糊后 cost 改按真实解码尺寸，4MB 曾把容量从 ~40 张压到 ~13 张、比单屏密集区还小，导致方向键滚动时反复解码闪烁，实测一次全遍历 5416 次解码 → 8MB 时 141 次）。**该缓存弹窗关闭时不再清空（0.106.2-dev）**：清空让每次打开都冷启动，首屏行先渲染占位符再换图。实测（同一真库、12 次真实开合、perf 仪表全门禁 VALID）：命中率 0%→92%、解码 24 次→2 次、每次打开首 250ms 的占位闪烁 2 行→0 行；内存不变（M1 弹窗打开 37.2MB→37.2MB、M4 33.0MB→34.3MB，均在噪声内，见 `/tmp/mem_before.txt` 与 `/tmp/mem_after.txt` 的对照）。缓存本身仍有界，且 NSCache 会在系统内存压力下自动驱逐——保温只避免丢弃用户已经付过成本的工作，不抬高上限。清空只保留在真正使行失效的路径：清空历史、撤销删除、恢复备份（后者原先漏清，会按 db_id 画出恢复前的图，已一并修掉）。PopupHostingView 按会话生命周期重建，并在弹窗关闭时置空 contentView 与 popupHostingView，使整个 SwiftUI 视图图和图片引用按会话严格释放（0.105.7 彻底移除过时的跨会话复用分支）。

用户实测（0.99.17-dev 仪器化会话）：基线 39MB → 预览 2880×1800 大图 71MB（峰值 113MB 瞬时解码）→ Esc 关预览 46MB（立即回落 25MB）→ 关弹窗 44MB → 稳定 44MB。诊断日志覆盖每条路径：`preview_decode done` / `preview_buffer_release` / `decode_scratch drop … mark_reusable` / `undo_push … total_payload_bytes`。长会话 125MB 进程 = 44MB 稳态 + 大图解码峰值残留与框架侧会话增长 + 多会话滚动 churn——无预览链残留（撤销栈已排除：载荷删时即落盘）。且该数中大部分页已被系统压缩出 RAM，footprint 仍把压缩页计为脏页，故不等于占用。

## 捕获正确性

- **db_id 不变量（幽灵条目根修，0.99.13）**：内存条目的 `db_id` 必须指向 DB 中该条目的行，且赋值必须按内容身份匹配、绝不按头部位置——文本捕获曾用 `hist.get_mut(0)` 无条件写头部条目：并发 select-and-paste/undo 在锁间隙把别的条目移到头部时，本次捕获条目 db_id 保持 0（列表可见但无法预览/粘贴/删除被拒），头部条目被指向他人行，后续删除会误删该条目的行（symptom：DB 主表+FTS 双查无此文本、entry_id 连续缺失）。修复：`history::assign_db_id_by_text_hash` 按 hash 匹配赋值（与图片 Phase 2 对称），3 个回归测试覆盖头部竞争/头部正常/无匹配 no-op。配套：Rust eprintln 此前被 launchd 丢弃——AppDelegate 启动 `dup2` stderr → `/tmp/copyattach_debug.log`，Rust 侧失败从此可见。
- **db_id 写穿的锁契约（0.101.8-dev）**：任何「写 DB 行 → 把行号写进内存条目」的路径必须**持 DB 锁跨过内存写**。粘贴路径曾是唯一例外（`persist_entry_to_db` 提交后释放 DB 锁、再单独 `add_to_history`）：同内容并发写者（monitor 捕获 / 图片 Phase 2——两者都被粘贴的 DB 锁挡住，粘贴一释放就立刻拿到锁）可在两步之间 INSERT 新行、去重掉粘贴刚写的行，其按 hash 的赋值先写进内存，随后又被粘贴迟到的内存写穿用**已删除**的行号覆盖 → 内存条目指向不存在的行（列表可见、预览/粘贴/删除全失败，DB 侧留一行孤儿）。窗口极窄（仅当粘贴线程在 DB 解锁与 history 加锁之间被抢占时才成立），故表现为「偶发一次、长期不复现」；8/30 的 db_id=1153 幽灵条目即此。四类写者（文本捕获、图片 Phase 2、undo、粘贴）现全部满足该契约。
- **删除路径的身份移除（0.101.9-dev）**：`clipboard_delete_by_id` 的「DB 删行 → 内存移除」两步之间不持锁，而 `add_to_history` 会保留重捕获条目的 entry_id——期间同内容被再次复制时，新捕获条目继承了被删条目的 entry_id，step 5 按 entry_id 的 retain 会把它一并删掉（列表里刚复制的内容消失、DB 留一行孤儿，重启后才回来）。修复：移除条件改为 (entry_id, db_id) 双重匹配（`history::remove_deleted_entry`）——被删的行号才是「被删条目」的身份，重捕获已指向另一行；3 个回归测试覆盖并发重捕获/正常删除/无匹配 no-op。刻意不做「先移出内存再删 DB」的重排：失败路径会让条目在列表里闪现后回来。
- **Suppress re-capture**：select_and_paste 先通过 `pasteboard_event_lock` + `pending_self_write` 标记自身的粘贴板写入，监控线程发现匹配的 changeCount 时跳过。不依赖内容比对。
- **HISTORY_REVISION**：去重时条目数不变但顺序变了——UI 通过此计数器感知「需要刷新列表」而不仅仅是 count 变化。
- **undo 删除**：通过 `clipboard_last_restored_id()` 精确定位恢复项，避免监控线程插入竞争。撤销栈 `push_deleted` 双上限：最多 `DELETE_STACK_LIMIT`(1) 条 + 总字节 `MAX_UNDO_BYTES`(48MB，文本正文与图片 png+thumb blob 统一计入——撤销栈是唯一能累积完整载荷的地方，图片不计数曾可无界钉住数百 MB）。`clipboard_delete_by_id` 入栈为移动语义（原 `entry.clone()` 每次删除多一次全 PNG memcpy，峰值翻倍）。

## 粘贴

- **select_and_paste 流程**：先查 accessibility 权限（`macos::check_permission`），未授权直接 return 0 且不动剪贴板——Cmd+V 无权限必然失败，先覆盖用户剪贴板只会毁掉其内容（临时 PNG 60s 后被 TTL 清理成死路径），且旧逻辑 fall-through 返回 1 被 Swift 误判为粘贴成功并关闭弹窗 → 查 history（by entry_id）→ DB 加载 png_data（加载失败显式 return 0 + 日志，不用内存副本兜底）→ 写系统剪贴板（设 pending_self_write）→ DB write-through → move entry to top → sleep 50ms → Cmd+V。
- **图片粘贴走唯一的文件路径模式**：图片一律先写入 `$TMPDIR/CopyAttach/Paste/` 临时 PNG，剪贴板只放 `public.file-url`（Finder「复制文件」同款约定，`macos::set_pasteboard_file_url`）再 Cmd+V——终端将其翻译为路径文本，TUI Agent 直接消费，聊天/笔记类 app 粘贴为文件；不区分终端与非终端，无开关。
- **⌘V 必须在弹窗让出 key window 之后发出**（0.103.3 修复）：粘贴拆成两阶段 FFI——`clipboard_prepare_paste_by_id` 只写剪贴板并返回目标 pid，`clipboard_send_paste(pid)` 只发 ⌘V；Swift 侧在两者**中间**关闭弹窗。原因是弹窗是 `canBecomeKey=true` 的 nonactivating panel，**不需要本应用在前台就能持有键盘焦点**，而它只在 `close()` 里 `makeFirstResponder(nil)`。此前单阶段流程先发 ⌘V、之后才走 `close()`，实测 7/7 次都是「⌘V 已发出而 `popupKey` 仍为 true」；微信一类应用会用自己当时的 key window 解析这次粘贴，于是**短文本**（用户操作快、50ms 焦点交接余量被吃掉）间歇性丢粘贴。修复后实测 8/8 次 `popupKey=false`，微信恢复正常。改这条路径时注意：`appActive=true` 是这类 agent app 的正常状态（预览会 `NSApp.activate`），**判据是 `popupKey` 而不是 `appActive`**。
- **粘贴目标 pid 不变式**：Cmd+V 用 `CGEventPostToPid` 投递给 `source_app.pid`（`clipboard_set_source_app` 由 Swift 事件驱动更新：`NSWorkspace.didActivateApplicationNotification` + 启动时种子值——0.99.11 起不再 0.3s 轮询，每次 `NSRunningApplication` 属性访问都触发 LaunchServices 同步 XPC，实测 10 小时轮询在 LS 客户端累积 ~115MB）。该 pid 必须是用户打开弹窗前的 app，绝不能是 CopyAttach 自身。预览窗口通过 `NSApp.activate(ignoringOtherApps:)` 真实激活才能收到捏合手势（LSUIElement agent 在 nonactivating panel 上浮期间从不收到 applicationDidBecomeActive，`NSApp.isActive` 误报 true），这会让 agent 成为前台应用——`updateSourceApp()` 检测到自 pid 时直接跳过覆盖，保留上一应用为粘贴目标。

## 原生拖拽

- **文本只广播纯文本 UTI**（0.103.2 起）：此前文本走 `NSItemProvider(object: NSString)`，实测注册类型只有 `public.utf8-plain-text` 一个，落点的**并集**也只有 `public.utf8-plain-text` + `NSStringPboardType`。接收方各自按不同 UTI 过滤：思源笔记一类匹配 `public.plain-text`，因此旧实现下直接拒绝这次 drop，表现为「松手毫无反应」;而微信/QQ/Typora/VSCode 恰好匹配 `public.utf8-plain-text` 所以一直正常。现在注册 `utf8PlainText / plainText / text`，全部用**构建期已备好的 `Data`**（避免接收方在 `draggingEntered:` 期间等异步 provider 回调）。写入真实拖拽剪贴板 `Apple CFPasteboard drag` 后实测，系统会把它们**自动展开成完整的原生表示集**（含 `NSStringPboardType`、`public.utf16-external-plain-text` 等）。图片仍走临时 PNG 文件 (`public.file-url`)。
- **富文本 UTI（`public.html` / `public.rtf`）与 VS Code 聊天框互斥**（0.104.2 → 0.104.4）：只要拖拽板上出现 `public.html` **或 `public.rtf`**，Chromium 就会把它变成 web 侧的 `text/html`——它会把 RTF 转成 HTML 再填进 `drop_data.html`，源码注释即「Get HTML. If there's no HTML, try RTF.」（`content/browser/web_contents/web_drag_dest_mac.mm`；剪贴板路径同规则见 `ui/base/clipboard/clipboard_mac.mm` 的 `GetAllAvailableFormats`）。而 VS Code Copilot 聊天输入框把**任何**带 `text/html` 的拖拽判定成 URL 附件（overlay 文案「将 URL 附为上下文」；源码 `chatDragAndDrop.ts` 的 `guessDropType` 只认 `text/html`，`getDropTypeName(HTML)` 返回 `'URL'`；松手时只从 `text/uri-list` 提取图片 URL，普通文本拿不到附件，同时 `DragAndDropObserver` 在 dragover 已 `preventDefault`，于是文本也不落）。**实测教训**：0.104.2 只删了 `.html`、保留 `.rtf`，真实拖拽仍显示「将 URL 附为上下文」——证明 RTF 同样会触发 `text/html`；0.104.3 把 `.rtf` 一并删掉，VS Code 恢复，但思源笔记 / Typora 又收不了（它们只认 `text/html`）。反向排查线索：落点若显示「Attach URL as Context」，即说明这次拖拽带了 `text/html`。
- **拖拽板类型在同一拖拽内不可切换**：类型在拖拽开始即固定，且 Chromium 只在 `draggingEntered:` 读一次并缓存（`draggingUpdated:` 复用 `_dropDataUnfiltered`，不重读）。所以「拖到 VS Code 时临时摘掉 html」这类动态方案不成立——必须在拖拽开始前决定风味。
- **按「唤起弹窗时的前台 App」选拖拽风味**（0.104.4）：因为上面两条，同一份拖拽表示无法同时满足「VS Code 聊天框（不能有 text/html）」与「思源/Typora（必须有 text/html）」。零默认即纯文本（`utf8PlainText / plainText / text`）；`ClipboardBackend.richTextDragAppBundleIDs`（UserDefaults `RichTextDragAppBundleIDs`，默认 `org.b3log.siyuan` / `abnerworks.Typora`）里的应用加挂 `html / rtf`。判定用 `sourceAppBundleID`——即 `updateSourceApp` 记录的前台 App；弹窗是非激活面板，所以它保持为「用户唤起弹窗之前所在的应用」，不会被本应用覆盖（本应用自己会被显式跳过）。设置「通用 → 拖拽富文本」可增删该列表。
- **调试拖拽时的剪贴板名陷阱**：拖拽进行中的剪贴板叫 `Apple CFPasteboard drag`，遗留名 `NSDragPboard` 在现代 macOS 上**始终为空**——用后者去读会得到「拖拽没数据」的假象，实测踩过这个坑。
- **已知不修**：`chat.deepseek.com` 的输入框拒绝所有外部文本拖入（同页面其他站点的输入框正常，访达原生拖拽同样进不去），属于该网站的落点行为，不在本应用职责内。
- 窗口拖动区限制为 PopupHostingView 外 3pt 边框，避免行拖拽误触窗口移动。
- 拖拽结束检测用 `NSEvent.pressedMouseButtons` 轮询（40ms Timer，注册 `.common` + `.eventTracking` 双 run loop 模式）——拖拽期间 run loop 处于 `NSEventTrackingRunLoopMode`，global/local monitor 收不到 mouse-up（官方文档确认），Timer 是可靠信号。
- **拖拽在途弹窗智能停车**（`tickDragParking`，与松手检测共用 40ms tick）：按屏幕 45%:10%:45% 分区，鼠标在右侧 45% 时弹窗停靠左边缘、左侧 45% 时停靠右边缘，中间 10% 为死区不动；同侧小幅晃动不触发横跳。`park(at:)` 用 `animator().setFrame`（无边框 NSPanel 上 `setFrameOrigin` 静默不动画）；`tickParkingSlide` 侦测 CA 事务停顿（事件跟踪模式下帧动画可能卡死，3 tick 无位移即 `setFrameOrigin` 直接落位）。拖拽结束时开关关闭走 `restoreFromParking()` 滑回居中；`show()`/`close()`/`completeItemDrag` 均 `resetDragParking()`。
- 开关「连续拖拽」（`ContinuousDrag`，默认关）：关闭时拖拽结束直接 `close()`——与 Esc 相同路径，无动画、无 completion 依赖；开启时保持弹窗、必要时 `restoreFromParking()` 滑回居中，等下一次外部点击再关闭。

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

### 商业版本构建配置（归档说明）

历史商业版本（<= v0.107.10，封存于 `archive/commercial-v0.107` 分支）曾依赖 License Server：

```bash
# 本地开发示例
LICENSE_ENV=local COPYATTACH_LICENSE_PUBLIC_KEY='<dev 公钥>' ./build.sh

# 生产参数示例
COPYATTACH_LICENSE_SERVER_URL='https://license.example.com' \
COPYATTACH_LICENSE_KEY_ID='production-key-id' \
COPYATTACH_LICENSE_PUBLIC_KEY='<production Ed25519 public key>' \
./build.sh
```

参数原写入 App bundle 的 `Info.plist`（`CopyAttachLicenseServerURL/KeyID/PublicKey`）；自 v0.108.0 起软件完全免费开源，客户端已不再需要此类配置。历史协议细节见 `docs/licensing-protocol.md`。

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

- Swift 解码一律离主线程（0.99.16）：列表行缩略图经 `ClipboardBackend.loadThumbnail`（Task.detached 内 FFI 读 + PNG 解码 → 8MB NSCache，countLimit 120），行 body 只做同步 NSCache 命中检查；预览大图经 `ImageDecode.previewImage`（预算 = min(源最长边, max(显示尺寸×scale, 2048px))，2048px 是下限 floor 而非上限）。
- `AppIcon+Ext.swift`：bundleId → 36pt 单尺寸图标缓存（NSWorkspace 图标多尺寸全量可达数百 KB/张，18pt 行只用 36px，缓存前降采样）。
- 日期分组：`DayGroup` 按日历日分组，`PopupRow` 在扁平列表中渲染分隔符+条目行。底栏计数用 `.contentTransition(.numericText())`。
- swiftc 必须 `-O -whole-module-optimization`——缺省 `-Onone` 会让 SwiftUI 前端全速跑在未优化代码上（build.sh 已处理）。
## init 失败分级（0.105.4-dev）

**问题**：`open_db()` 返回 `Option<Connection>`，把「文件只读 / 权限拒绝 / 磁盘满 / 路径打不开」与「busy / locked 瞬态」
一律压成 `None` → `clipboard_init` 统一返回 0 → Swift 无限 5s 重试，用户看不到任何原因。
P0 崩溃（FFI 未初始化 panic）正发生在这个「重试中但弹窗可开」的状态里。

**修复**：`src/db/schema.rs` 新增 `DbFailure { Transient, PermanentEnvironment, Corrupt }` 与
`classify_db_error(&rusqlite::Error)`，按 SQLite 错误码分类：

| 错误码 | 分类 | 语义 |
|---|---|---|
| `DatabaseCorrupt` / `NotADatabase` | Corrupt | 文件不可用，只有替换能修 |
| `ReadOnly` / `CannotOpen` / `PermissionDenied` / `DiskFull` | PermanentEnvironment | 文件是好的，环境不行；重试无用 |
| `DatabaseBusy` / `DatabaseLocked` / `SystemIoFailure` / 其他 | Transient | 重试可能成功 |

`clipboard_init` 返回码（与 Swift `StartResult` 一一对应）：`1` started ／ `0` retryable（冷却重试）／
`-1` corrupt（备份重建对话框）／ **`-2` permanentEnvironment**（新，弹「无法读写 + 重试/退出」，**不提供重建** ——
数据库完好，重建会毁掉好数据去掩盖一个可修的环境问题）。

**实测**（对产物 dylib 直接调用，隔离 `HOME`，仅用 Rust 二进制以避免钥匙串）：

| 场景 | 返回 |
|---|---|
| 干净目录（新建） | `1` |
| 垃圾文件冒充 DB | `-1` |
| 有效 DB 置为只读（0444） | `-2` |

**回归测试**：`src/tests/db.rs::db_failure_classification` 用**真实** SQLite 错误（真写只读文件、真读非 DB 文件）断言分类，而非手工构造错误值。

**注意**：`presentDatabaseUnusableDialog` 的「重试」分支最初同步调用 `startBackendIfNeeded()`，此时
`databaseUnusableDialogShowing` 尚未被 `defer` 清除 → 若环境仍未修好，嵌套对话框被守卫静默吞掉，
用户点「重试」后没有任何反馈。改为 `DispatchQueue.main.async` 让本次调用先展开。


## 启动重试：二进制指数退避（0.105.5-dev）

**背景**：旧实现是固定 5s 冷却，且 `permanentEnvironment`（只读/权限/磁盘满）会停止重试循环——
用户即使修好了环境也不会自动恢复，必须重开应用。

**机制**（`AppDelegate`）：

- `delay_n = min(60s, 2s × 2^(n-1)) × jitter(0.75–1.25)`，`n` = 连续失败次数。
- 失败递增 `startFailures`；**成功时清零**（并记录「backoff reset」日志，供分析器/支持使用）。
- `scheduleMaintenanceTick` 用 `currentStartRetryDelay()` 计算下一次重试时刻（**不是**硬编码 5s——
  否则会静默抵消退避）。
- `permanentEnvironment` **不再停止重试**：环境类故障正是「用户在带外修好、应用需自愈」的场景。
  对话框改为用户主动触发（按热键时）的说明面板，且其「重试」按钮会清零退避以立即重试。
- 抖动用于打散与许可维护、剪贴板轮询等周期工作的相位，避免重试总是与无关工作同一瞬间触发。

**实测（真实 GUI + 真实启动路径，隔离数据目录；`COPYATTACH_DATA_DIR` 覆盖，HOME 保持真实以保留钥匙串）**：

```text
Rust backend refused to start: database unusable in this environment (attempt 1); ... next in 1.7s
Rust backend refused to start: database unusable in this environment (attempt 2); ... next in 4.2s
Rust backend refused to start: database unusable in this environment (attempt 3); ... next in 7.9s
# 用户修好写权限（chmod 644），无任何 UI 交互：
Rust backend started after 3 failed attempt(s); backoff reset
db.write after recovery: 1        <- 恢复后捕获写入正常
```

- 退避实测：1.7s → 4.2s → 7.9s（2s×2^k × jitter，符合预期）。
- **自愈实测**：恢复写权限后 **6s 内**自动重新启动后端并恢复采集，无需重开应用或点击任何按钮。
- 真实库 `REAL_DB_BEFORE == REAL_DB_AFTER`（size/mtime/perms 均未变），测试全程未触碰用户数据。

**测试钩子**：`COPYATTACH_DATA_DIR`（仅测试用，正常未设置时无任何影响）——
因为对真实库做 `chmod`/符号链接会被文件沙箱拒绝（`Operation not permitted`），
无法在不破坏用户数据的前提下注入只读故障；该钩子让真实启动路径可被完整验证。

## 鲁棒性审查（2026-09-16，第一性 + 实测）

审查方法：代码取证 + 真实路径复现。凡未实测者标注为「假设」。

### P0：FFI 无初始化时 panic 直接 abort 进程（已修复，已实测）

- **代码事实**：`backend()` 在 `OnceLock` 未初始化时 `expect` panic；它被 ~30 个 `extern "C"` 入口调用。
  Rust panic 跨 `extern "C"` 无法 unwind，运行时报 `panic in a function that cannot unwind` → **abort（SIGABRT）**。
- **可达性（代码 + 运行证据）**：`clipboard_init` 受 entitlement 门控，失败返回 0 时 Swift 进入 `retryable`
  重试循环，而 `togglePopup()` 只在 `databaseCorrupt` 时拦截——`retryable` 状态下弹窗仍可打开，
  `setPopupVisible(true) → refresh() → clipboard_get_count()` 即命中 panic。实测日志中确有 
  `failed to create table: attempt to write a readonly database` → `will retry` → 之后仍收到 `HistoryPopupWindow.show()`。
- **实测复现**：对一个**未调用 `clipboard_init`** 的进程直接调用 FFI（C 程序链接产物 dylib）：
  `clipboard_get_count` / `clipboard_get_item_type` / `clipboard_get_image_thumb_by_db_id` 均 `EXIT=134`（SIGABRT）。
- **修复**：删除 panicking `backend()`（编译期强制所有调用点处理未初始化），全部改为 `try_backend()` + 文档化哨兵值。
  **实测**：同一 C harness 修复后 `EXIT=0`，分别返回 `0` / `-1` / `NULL`。
- **回归防线**：`test_recoverable_backend_accessor_is_the_only_accessor`；真正的端到端证明是 C harness（见上）。

### P1：拖拽图片的 fatalError（已修复）

- **代码事实**：`ClipboardDragProvider` 图片分支在 `item.imageData == nil`（仍在编码、行被裁剪、DB 读取失败）时 `fatalError`；
  写临时文件失败同样 `fatalError`。文本分支则是 log + 空拖拽——**同一策略两种实现，不一致**。
- **触发场景**：图片 Phase 2 尚未落库时（`dbId=0` 但列表已显示占位行）用户直接拖拽，或磁盘/权限异常。
- **修复**：图片分支改为与文本一致——`debugLog`/`errorLog` + 返回空 `NSItemProvider`，拒绝拖拽而非崩溃进程。

### P1：`pasteboard_change_count()` 的 `.expect()`（已修复）

- **代码事实**：`pasteboard_change_count()` 返回 `Option<i64>`（pasteboard 不可用时为 `None`），调用点却 `.expect()`。
- **修复**：改为显式失败——返回 0 中止粘贴。注释说明代价：此时已写入剪贴板但**不发 ⌘V**，
  用户不会粘贴到内容，也避免了「无法识别自写入」导致监控把自身粘贴重新捕获为一条新记录。

### P2：整条单阶段粘贴路径是死代码 + 有一致性缺陷（已删除）

- **代码事实**：`select_and_paste_impl` 在写完剪贴板后 `thread::sleep(50ms)`，仅有的三个调用者
  （`clipboard_select_and_paste{,_by_id,_as_path_by_id}`）在 Swift 侧**无任何调用者**；
  `ClipboardBackend.selectAndPaste(at:)` 也无调用者（弹窗走两阶段 API）。
- **为何危险**：该实现正是仓库文档记录的「⌘V 可能在弹窗仍为 key 时发出」缺陷形态（实测 7/7，微信丢短文本），
  且阻塞调用线程。保留它等于留一个随时会被误用的陷阱。
- **修复**：删除该函数与三个导出、Swift 包装、桥接头声明；更新引用它的测试为两阶段 API 的等价断言。

### 已核查但判定为「非问题」（附证据，避免重复排查）

- **`DayGroup.preconditionFailure` / `separatorID` 溢出**：Calendar 对任意 `UInt64` 时间戳都返回非 nil 组件，
  key 恒为正（实测 0 / 1 / 负值 / 1970 / 2100 / 1e15 均安全）。不可达。
- **`LargeTextView` 的 `textContainer!`**：`NSTextView` 构造后 textContainer 必非 nil，不可达。
- **`imageops`、madvise、claim 契约**：既有的 `docs/engineering-notes.md` 已覆盖，未发现新问题。
- **`stress-test` 下 2 个 `memory_probe` 失败**：是沙箱禁止 `ps`（`Operation not permitted`），
  与本仓库代码无关；CI 跑的是默认 feature 的 `cargo test`（117 passed）。

### 仍存在、本次未改（列为待办，需产品决策或独立验证）

1. **`lock().unwrap()` × 60**：任一持锁线程 panic 会污染 mutex，其余线程随后全部 panic。
   当前已达成的安全边界是「FFI 入口不再因未初始化 panic」，但 DB/monitor 内部的 panic 仍会级联。
   按仓库「不搞兜底」原则，不建议统一吞掉 poison；更合适的是消除可 panic 的持锁区（见第 2 点）。
2. ~~**`open_db()` 吞掉具体错误**~~ —— **已修复（0.105.4-dev）**，见上文「init 失败分级」。
   旧行为：只读/权限/磁盘满与瞬态失败无法区分 → init 统一返回 0 → 无限 5s 重试
   （该状态下弹窗仍可打开，正是上面 P0 崩溃的温床）。
3. **`monitor.rs` 的 `unreachable!`（text capture 得到非 text 条目）**：属不变量断言，当前调用链不可达，暂留。


## 事件驱动刷新（0.105.6-dev，capture → UI 实测 p95 522ms → 0.46ms）

- **问题**：`ClipboardBackend` 在弹窗打开期间用 0.5s Timer 轮询三个计数器；实测一次捕获
  从落到 DB（`db.write` p95 0.9ms）到 UI 察觉 p50 135ms / p95 522ms——延迟全部来自轮询周期。
- **机制**：Rust `HISTORY_EVENT`（`Mutex<u64>` + `Condvar`）+ FFI `clipboard_wait_for_history_change`；
  Swift 在后台 Task 阻塞等待，唤醒后回主线程刷新。超时 3s 仅作丢通知兜底，正常路径不触发。
- **释放语义**：`mark_history_changed()` **必须在持有 history 锁时**调用（先递增 `HISTORY_REVISION`，
  再在同一临界区写 pending + `notify_all`）——这是「不会漏唤醒」和「多次变化合并为一次重载」的共同前提。
  现有通知点：捕获（文本/图片 Phase1）、图片 Phase2 db_id 回填、粘贴 move-to-top、删除、撤销、清空、
  百分比裁剪、`reload_history_from_db`、迁移内存镜像。
- **踩坑：非原子追加会互相覆盖**。Rust `perf::emit` 曾分两次 `write_all`、`backend::write_log_line` 曾分四次写、
  Swift 曾用 `FileHandle.seekToEnd()+write`。并发下实测丢过一条 `capture.text` 记录，并出现
  `...data=text__CA_PERF__ v=1 ...` 粘连行。三处现均为「整行拼好 → 单次 write → O_APPEND」；
  分析器 G5 门禁拒绝 torn 行而非误解析。
- **踩坑：时钟字段语义**。`t`(单调) 与 `wall`(墙钟) 必须同一瞬间取值；曾在 span 结束时取 `wall`、
  开始时取 `t`，长 span 上二者相差一个 span 时长，被 G4 门禁捕获（R² 0.9899、~3000ms 残差台阶）。
- **可观测性**：`reload.wait`（等待时长）+ `reload.event_wake`（事件唤醒标记）+ `list.published`；
  链 `capture->ui_observed`（后端→UI 察觉）与 `capture->list_published`（含重建+发布）。

### 发布契约审计：按「是否真的会被看见」定级（0.105.6-dev）

事件驱动刷新的本质是一条唯一通路：waiter 不轮询脏标记，只阻塞在 condvar 上，被唤醒后重载。
因此「内存变更 → UI 可见」几乎完全依赖 `mark_history_changed()`。据此逐个核对全部变更点后，
共发现 5 处「变更未发布」。但**是否构成真实缺陷，取决于该变更有没有消费者、消费者当时是否活着**——
第一版审计把 5 处并列、暗示同级危害，是过度声称。按可观察后果重排如下：

**1. 真实缺陷（已修，根因在 Swift 侧）——`clipboard_set_cleanup_threshold`（`ffi/accessors.rs`）**
裁剪在锁内 `hist.pop()` 后从不发布。消费方是设置页「存储统计」：`InlineSettingsView+StorageTab.swift`
直接渲染 `backend.items.count`（`textCount`/`imageCount` 也来自 `backend.items`）。关键事实：
**弹窗（唯一持有 waiter 的地方）在设置窗打开时必然是关闭的，所以那一刻根本没有 waiter 在等**
——即使 Rust 发布了也无人接收。真正治病的是 Swift 侧：`ClipboardBackend.setCleanupThreshold`
此前只调用 FFI、不刷新，现补一次 `refresh()`（它按 count 变化门控，所以提高阈值仍是 no-op）。
Rust 侧的发布照旧保留：让该变更在有 waiter 时（例如将来设置页与弹窗并存）也正确，且与契约一致。

**2. 结构性隐患（已修，当前近乎不可达）——`monitor.rs` 三处回滚**（Phase2 编码失败 `hist.retain`、
文本写库 `Err`、DB 锁 poisoned）：都先经头插并发布给 UI，失败后又把该条从内存移除，却不再发布。
后果是 UI 可能短暂显示一个从未落库、随即消失的条目（点它会静默粘贴失败）。但回滚发生在同一后台
串行流程的毫秒窗口内，且 3s lifeline 会自愈；现实中要撞上需要极精确的时序。修（成本为零）但不夸大。

**3. 无收益、已回退——`clipboard_set_custom_label` 的发布点置于锁外**。这是一处**顺序**违规
（契约要求持锁发布），但 `ClipboardBackend.setCustomLabel` 已在 Swift 侧同步更新 `items[idx]`，
UI 走本地状态即正确；label 又是覆盖式幂等写，懒重载的旧值快照无损。没有可观察收益，故回退，
不在测试中断言它。

**未改（判定为正确遗漏）**：`history::assign_db_id_by_text_hash` 不发布——文本行的 `db_id` 不进快照
线格式（`PackedSnapshot.swift` 文本分支不读 `dbId`），UI 看不到，无需发布。

**验证**：`test_history_mutations_publish_a_revision`（`src/tests/backend.rs`）断言「裁剪使
`HISTORY_REVISION` 前进」与「no-op 阈值变更不得发布」。反向对照：删掉 `if hist.len() != before`
守卫，测试如期以 `(1 -> 1)` 失败，恢复后通过——证明测试确在检测该缺陷。
`cargo test` 120 passed（原 119），`clippy --all-targets -D warnings` 干净。

**教训（写给自己）**：这一轮先把 5 处并列、用「变更必发布」的契约去证明「用户可见」，
是把**机制正确性**当成了**用户可见性**，又一次踩到「推导≠验证」。正确的判据是：该变更有没有
消费者、消费者在那一刻是否活着。缺了这一步，「已修复/有危害」都只是假设。

**同时消除的测试隐患**：`src/tests/backend.rs` 的 4 个用例共享进程级 Backend 的同一 `Vec`，
却并行运行；新增的裁剪用例会与 `test_clipboard_delete_by_id_returns_zero_on_failure`（断言小 id 不存在）
等相互踩踏。已加 `SHARED_STATE_LOCK` 串行化，连跑 8 次稳定全绿。

## 内存与释放语义审计（0.105.7-dev，含真实 GUI 路径验证）

起点是一个纯静态问题：「频繁随机操作后，内存管理有没有不合理的地方」。结论是**账本健康、契约不一致**：
活进程 13 小时后 `Writable written=75.9MB`、`resident=40.9MB`、`Malloc Large (Reusable) 25.1MB 且 resident=0K`
——madvise 契约在真实路径上确实生效；问题集中在「同一份契约在不同调用点被不同对待」。
共修 7 项，按危害排序，全部带实测或编译期证据。

### ① `clipboard_trim_oldest_percent` 吞掉 DB 失败后照旧删内存（真 bug）

原实现两处错，第二处比第一处更深：

1. DB `DELETE` 失败只记日志，随后**无条件**从内存移除，且返回 >0 → 调用方（设置页百分比裁剪）判定「成功删了 N 条」。
   后果：DB 行还在、内存条目没了，重启后这批「已删除」条目**全部复活**。这是全仓唯一违反「DB 失败则不动内存」契约的路径
   （`delete_by_id` / `clear_history` / `select_and_paste` 都是 DB 优先）。
2. 内存移除用的是**尾部位置**（`split_off`），而 DB 删除按 `rowid` 顺序——两者不是同一个集合。只要列表顺序与 rowid 顺序出现分歧
   （异步捕获 / Phase 2 回填 / 撤销），删掉的内存条目就可能与 DB 删掉的行**对不上**。这与 `db_id 不变量` 是同一类错误。

修法：先 `SELECT id ... ORDER BY id ASC LIMIT n` 取确切 id 集 → 按该集合删 DB → **仅当 DELETE 成功**，按 `db_id` 从内存 `retain` 掉同一集合。
返回「DB 实际删除的行数」，而不是请求数。`trim_db_history` 改为返回 `Result<(), ()>`——clippy 随即抓出 3 处未处理的调用点，
说明返回类型本身就是比注释更强的约束（`persist_entry_to_db` 里它现在参与事务，失败即整体回滚）。

**验证**：`test_trim_oldest_percent_leaves_memory_intact_when_db_delete_fails`，用真实 `PRAGMA query_only` 制造写失败（非 mock）。
反向对照：还原旧语义后该用例以 `left: 4, right: 0` 失败，恢复后通过——证明用例确在检测该缺陷。

### ② `entry_id` 会被复用 → 收藏错乱（正确性，非内存）

`favoriteIds` 无裁剪只是表象。实测确认了真正的机制：`entry_id` **可以重复发放**。
`NEXT_ENTRY_ID` 唯一的初始化点是 `clipboard_init` 的 `prime_entry_id(max_loaded + 1)`，而 `max_loaded` 只来自**本次加载到的行**；
清空历史后重启 → 表为空 → `max_loaded = 0` → 新 id 从 1 重新走 → 穿过 `favoriteIds` 里记录的 1228/1286/1477/1483/2141，
于是**无关的新内容被标成收藏**（实测该 5 个 id 与 `COUNT(*)=1093`、`MIN=304`、`MAX=2395` 的库状态相符）。schema 里 `entry_id` 无 UNIQUE 约束，DB 层不报错。

修法（两层，缺一不可）：

- **持久化高水位**：新增 `clipboard_meta(key,value)` 存 `entry_id_watermark`；`insert_entry_to_db` 成功即 `MAX(value, entry_id)` 抬升
  （放在插入点而非退出时：崩溃或「收藏后立刻清空再退出」都不能丢记录）；init 取 `max(max_loaded, watermark) + 1`，
  并把 `prime_entry_id` 从 `store` 改成 `fetch_max`（单调不回退）。
- **Swift 侧收敛点**：`pruneFavorites(against:)` 挂在**唯一的列表发布点**（`reloadItems` 的 main-async 段），
  一次覆盖删除/撤销/两种裁剪/清空，且幂等、无变化时不写 UserDefaults。

**验证**：`test_entry_id_never_reused_after_clear_and_restart`。反向对照：去掉插入时的抬升，用例以 `left: 0, right: 5` 失败；恢复后通过。

### ③ `claim_pages` 的返回值在 29 处被忽略（编译期强制，非运行时验证）

契约文档写明「返回 false 时调用方必须视该缓冲为不可用」，但只有池路径遵守；池外 29 处读取侧调用点全部忽略返回值。
加 `#[must_use]` 后编译器一次性列全 29 处（`cargo clippy --all-targets -- -D warnings`），逐点表态。

统一规则：**认领被拒 = 该操作显式失败**（`vec_to_raw`/`to_ffi_cstring`/快照 rows/搜索 id 返回 null，预览解码返回 null，
paste/undo/文本读取返回失败，迁移行跳过并在下次启动重试），并在错误路径补上释放侧对称（认领过就 `mark_pages_reusable` 后释放）。
这一条是**编译期强制**，不是运行时验证：日志里 `madvise ... failed` 实测 0 次，这些分支从未被触发过。

### ④ 死代码：9 个零调用 accessor 与一段不可达分支

`clipboard_get_item_{type,timestamp,source_name,source_bundle_id,label,text}`、`clipboard_get_image_{thumb,full}`（index 版）、
`clipboard_get_image_size` 在 Swift + Rust + header 之外**零引用**（`_by_db_id` 是不同函数，仍在用），合计 218 行 = `accessors.rs` 的 36%
（601 → 412 行，另有 9 条头文件声明）。同时删掉 `HistoryPopupWindow.show()` 里恒不可达的复用分支——`close()` 无条件把 `popupHostingView` 置 nil，
自 0.101.0 起该分支永不成立。`clipboard_get_image_full` 的注释写「先查内存缓存」，实现里**没有任何缓存检查**，一并改正。

**踩坑**：第一次删除用「逐函数找边界」的脚本，因相邻函数 doc 注释重叠而切坏了文件（`unexpected closing delimiter`）。
已从 git 还原，改用「函数头 → 第一个列 0 的 `}`」大括号配对重做。删除类脚本必须校验骨架，不能只信行号推算。

产物验证：`nm -gU` 确认新符号 `clipboard_purge_stale_drag_images` 存在、上述 9 个 accessor 已从二进制消失。

### ⑤ 三个临时目录三套清理策略，其中一套的触发条件可能永不发生

`Undo/`（启动清 + 逐次删）与 `Paste/`（60s TTL + 启动清）都有界，`Drag/` 只在**下一次图片拖拽开始时删光整个目录**。
实测后果：一个 2026-09-16 23:31 写入的 207,388 B PNG，到 09-17 23:11 仍在磁盘上，跨了多次进程重启。

修法：抽出 `purge_age_out(dir, ttl)`，`Paste`/`Drag` 共用；Drag 加 60s TTL（与 Paste 同源：拖放目标可能在手势结束后仍在读文件），
Swift 侧从「删光目录」改为「写完新文件后扫过期」；启动时两个目录各清一次。新增 FFI `clipboard_purge_stale_drag_images`。

**验证（真实 `$TMPDIR`，判别性）**：放入 2 小时前的 `stale-probe.png` 与刚写的 `fresh-probe.png`，重启后 `stale present: NO` / `fresh present: YES`。
那条 09-16 的 207KB 残留也在真实路径上消失了。反向对照：把判据改成「凡到访即删」后，单测 `test_temp_purge_removes_only_aged_out_files` 如期失败。

### ⑥ 预览解码没有并发上限（缩略图有 4 槽）

`thumbnailDecodeSlots = DispatchSemaphore(value: 4)` 只约束了列表行；预览解码经由 `Task.detached` 无闸门，
而它是更重的一条：交付缓冲最大 `maxPixel²×4`（实测 2293×1440 源 → 13,207,680 B），且活到预览关闭。
Rust 侧的「单槽」`IMAGE_DECODE_SCRATCH` 是**复用机会**而非并发上限（第二个调用者 `.take()` 拿到 `None` 就走全新分配），兜不住。

实现细节：Swift 6 禁止在 async 上下文用 `DispatchSemaphore.wait`（会占据协作线程），故写成 actor `PreviewDecodeGate`（挂起而非阻塞，
排队中被取消的任务不会占槽）。**第一版记账有漏**：被取消的等待者苏醒后不计数，会永久漏掉一个槽位；改为「waiters 不占 permit，
苏醒必然意味着某次 release 已把 permit 交给你」的记账后可由构造证明守恒。

**验证（真实 FFI + 真实仪表）**：合成按键无法进入 key window（见下），故直接驱动真实解码路径
（`clipboard_init` + `clipboard_decode_preview_by_db_id`，跑在真实库副本上），用应用自己的 `rust.preview.decode` span 度量。
10 轮：**gate ON 峰值恒为 2**；gate OFF（修复前）为 4–9（均值 6.1）。
因果用**上限扫描**确认：limit=1→恒 1、limit=2→恒 2、limit=4→恒 4。旁证：OFF 的 p50 也更高（75–91ms vs 71ms），即不受限时互相拖慢。

**踩坑（本轮最重要的教训）**：第一版并发度量写成 `spans.filter { 与区间 i 相交 }.count`，数的是「相交数、且含自身」，
不是「同时在场数」。它让 gate=2 的构建报出峰值 3–4，与设计矛盾，我一度准备当 bug 深挖。改成扫描线求最大深度后峰值精确等于上限。
**采样点自身也会错**——最终结论只能来自手工核验过原始区间的那一次。

### ⑦ 日志无轮转且跨构建混装（会直接误导基线）

`/tmp/copyattach_debug.log` 是 append-only，三个写入方（Swift `dup2` 的 stderr、Rust 逐记录 `emit`、Rust error log）都不轮转。
这不只是磁盘卫生：分析器读整个文件，旧构建的 span 与新构建无法区分。实测症状——全局 `popup.show` 报 **p95 561ms / max 733ms**，
而按 pid 过滤到当前构建只有 **p50 53ms / max 118ms**；更糟的是 `popup.build_hosting`（源码里已不存在，`grep` 返回空）仍出现在统计里。

修法：① 启动时按 4MiB 轮转为 `.1`，位置在 `dup2` **之前**（否则 stderr fd 会指向被移走的 inode）；Rust 逐记录路径**不**轮转，只加注释说明原因。
② 分析器把**全部聚合**（不只验证记录）按 dominant pid 切分，并在报告头声明被排除的记录数。

**验证（真实 GUI 路径，完整）**：把日志填到 4.92MB → 重启 → 归档为 `.1`；新日志里**有 `[ClipboardManager]` stderr 行**
（证明 `dup2` 指向新 inode）；新日志 `Malformed: 0`、门禁 PASS；归档日志输出「覆盖 pid 80167，排除 17297 条其他进程记录」。

### 本轮方法论教训（两条都是我自己的工具出错，不是产品问题）

**a. 验证手法破坏了被测前提。** 起初用 `perf/collect.sh launch` 带 `COPYATTACH_PERF=1` 直接启动二进制，
结果 app **继承了调用者的沙箱**，连真实 DB 都写不了（日志刷 `attempt to write a readonly database`、后端起不来、
弹窗永远打不开，我因此误以为「`open` 不触发 toggle」）。正确做法是 `open -a`（由 launchd 拉起、不继承沙箱）
＋ `defaults write com.example.copyattach PerfTracing -bool true`（`open` 不继承 shell 环境变量）。
这与 CLAUDE.md 里「覆盖 HOME 启动 GUI」是同一类错误：**测试手法必须先确认不改变被测对象**。

**b. 合成按键无法进入 key window（已实测，非推断）。** 三种方式全部失败：`CGEvent.post(tap:.cghidEventTap)`（0 条记录）、
`postToPid`（120 次方向键 0 次生效）、AppleScript System Events（TCC `-10004`）；`AXIsProcessTrusted=false`。
判别实验：弹窗**确认打开**、`isActive=true`、最前台为本应用的前提下，投递 Escape **也不产生 `popup.close`**
（而此前它确实成功记录过 2 次 `popup.close`）。

**由此遗留：本轮未验证的那一部分。** 「弹窗内连按方向键」这一层的端到端**仍未实测**；已验证的是其下层真实 FFI 解码路径 + 门闸
（10/10 峰值 2）以及上限扫描的因果。这条缺口只能用真实键盘补。
同理，③的 29 个「认领被拒」分支从未被触发过（`madvise failed` 实测 0 次），属未验证的风险面而非已修缺陷。

### 最终校验

`cargo clippy --all-targets -- -D warnings` 干净；`cargo test --lib` **123 passed / 0 failed**；Swift 全量 `-typecheck` 通过；
版本 `0.105.7-dev`（只动 patch 位）。新增文件 1 个（`SwiftApp/Backend/PreviewDecodeGate.swift`）。


