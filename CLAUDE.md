# CLAUDE.md

CopyAttach 是一个 macOS 剪贴板历史管理器：Rust 后端（cdylib）+ Swift 前端（LSUIElement agent app）+ SQLite 持久化 + 许可证体系。

## 行为约定

### 从第一性原理分析代码
先理解核心数据流和不变量的本质，再逐层验证具体实现是否忠实于这些原理。不依赖既有注释、命名或架构图——它们可能过时。

### 不要搞兜底实现
不写 fallback / 兜底逻辑。兜底会掩盖主流程错误，让 bug 难以发现。主流程失败应该显式暴露（panic、返回错误、日志 + 空结果），由调用方决定如何处理。

### 推导不等于验证（硬约束）
**任何「已修复 / 已确认 / 原因就是 X」的结论，必须在真实路径上有实测证据；否则只能表述为假设。**
- 在隔离环境验证替身（单独构造一个 `NSItemProvider`、手写剪贴板样本、脱离调用链跑一个函数）**不构成验证**——被测的必须是真实调用路径本身。踩过的坑：曾单独验证 provider 能注册 5 种 UTI 就宣布拖拽修好，但 SwiftUI `.onDrag` 这条真实路径根本没测，实际未修好。
- 调试采样点自身也可能错。踩过的坑：读 `NSDragPboard` 得到「拖拽无数据」的假象——现代 macOS 拖拽剪贴板实为 `Apple CFPasteboard drag`，前者恒为空。**先证明观测手段有效（能观测到已知为真的现象），再采信它给出的「没有」。**
- 报「已修复」前必须能回答：改动前失败、改动后成功，两次都在真实场景里观察到。做不到就明说「尚未实测」。
- **并发/竞态类问题单次运行不足以下结论**。踩过的坑：`src/ffi/paste.rs` 与 `src/tests/backend.rs` 各持一份 `Once` + `set_backend` 争抢进程级单例，6 次运行中 3 次失败（105/109），单跑一次全绿就提交了。**这类验证要连跑多次（≥8 次）并观察失败率**，不能以「这一次是绿的」收尾。
- **验证手法本身可能破坏被测前提**。踩过的坑：① 用覆盖的 `HOME` 启动 GUI 测内存，导致钥匙串不可达而弹出无关对话框，差点误导成「沙箱读不到钥匙串」（详见「钥匙串弹窗」节）；② 用每 500ms 新开一个 SQLite 连接轮询 `user_version` 来判定迁移结束——对一个 188MB 的库反复建连，把它自己注入了被测的常驻内存，得出前后矛盾的稳态数字；③ 起第二个 GUI 实例被单实例守卫直接 `exit(0)`，采样到的「进程消失」毫无意义。**观测动作不能改变被测对象；判定结束优先靠日志标记而非副作用式探询。**

## 构建与测试

```bash
# 构建全部（Rust + Swift）
./build.sh

# 压力测试构建（生成 1 万条数据）
STRESS=1 ./build.sh

# 仅 Rust release 构建
cargo build --release

# 测试
cargo test
cargo test test_add_text_item          # 按名称匹配

# 压力测试编排（生成数据 → 部署 DB → 采集指标）
bash stress_test.sh                    # 完整 10000 条
bash stress_test.sh --quick            # 1000 条快速测试

# 调试日志（Swift + Rust 统一落盘）
tail -f /tmp/copyattach_debug.log

# 打开应用
open "CopyAttach.app"
```

**版本号与 CHANGELOG 约定**：
- **版本号**：唯一版本源在 `Cargo.toml` 的 `version` 字段，`build.sh` 自动注入到产物 `CopyAttach.app/Contents/Info.plist` 的 `CFBundleShortVersionString`（保持源码 `SwiftApp/Info.plist` 干净无脏 diff）。开发版本带 `-dev` 后缀（如 `0.93.0-dev`），发布版本去掉后缀。每次功能/修复提交都提升版本号并写入提交信息。
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
- **撤销栈不是内存来源**(0.99.17 时代的笔记已过期)：载荷在删除时即落盘（`$TMPDIR/CopyAttach/Undo/*.bin`），内存只留 `payload_path`/`payload_bytes`，blobs 随即 `mark_pages_reusable`。实测删除一张 4.19MB 大图（撤销栈落盘 4.30MB）后 footprint **55 → 48MB**。
- `malloc_zone_pressure_relief` 不要加：实测它收不回任何东西——进程内 4 次调用、以及「512MB 已释放的 1MB 块仍计入 footprint」的合成场景，全部返回 `0 bytes`。
- **缩略图迁移是一次性内存事件**（0.105.1 起，仅 user_version 3 的库首次启动触发一次）：真库 137 行 release 实测峰值 79MB、稳态回落至与 no-op 相当（~9–18MB vs ~8.7MB），完成后不再发生。它不是常驻泄漏；若在「刚升级后」看到后台内存偏高，先确认 `metadata migration complete` 日志是否已出现。实现细节与三条踩坑（绕过 madvise 契约、每行新建 blob、借用捕获池）见 `docs/engineering-notes.md`。

### 生产构建

默认连接生产 License Server，无需环境变量。本地开发用 `LICENSE_ENV=local`：

```bash
# 默认（生产）
./build.sh

# 本地开发
LICENSE_ENV=local COPYATTACH_LICENSE_PUBLIC_KEY='<dev 公钥>' ./build.sh
```

license-server 服务端代码**不在本仓库**（本机 `~/copy-attach-license/`，生产 `api.abovepast.shop`）。协议细节见 `docs/licensing-protocol.md`。

## 代码库架构

### Rust 后端（`src/`，cdylib → `libcopy_attach.dylib`）

| 模块 | 职责 |
|---|---|
| `ffi/` | 所有 FFI 导出函数（目录模块）：`snapshot.rs` / `search.rs` / `init.rs` / `accessors.rs` / `paste.rs` / `history.rs` / `stress.rs` |
| `db/` | SQLite write-through：`schema.rs`（连接/FTS5/迁移）、`crud.rs`（load/insert/dedup/trim）、`search.rs`（FTS/LIKE）。禁用 mmap，4MB LRU page cache；FTS 索引上限 512K 字符，超限行走 LIKE 兜底；text/image hash 均为稳定 FNV-1a 64 |
| `monitor.rs` | 后台线程每 500ms 轮询剪贴板，changeCount 轻量检测，write-through DB，ignore rules 过滤。图片 Phase 2 单 worker + 单槽有界队列（背压） |
| `ignore.rs` | 捕获时忽略规则：按 app bundle ID、类型、短文本阈值过滤 |
| `image.rs` | PNG/JPEG/GIF/WebP/BMP/TIFF 编解码，CatmullRom 缩略图（等比 fit 进行显示框 920×200px），FNV-1a 内容哈希 |
| `backend.rs` | `OnceLock<Backend>` 单例，entry_id（AtomicU64），HISTORY_REVISION / IMAGE_ENCODING_COUNTER 原子计数器，自写抑制 |
| `macos.rs` | NSPasteboard changeCount + 文件 URL 读写，CGEventPost Cmd+V，AXIsProcessTrusted。cfg-gated，非 macOS 用空桩 |
| `history.rs` | `add_to_history()` — 去重 + 头部插入，纯函数式 |
| `tests/` | 单元测试（cfg-gated），按主题拆分：history / image / search / cleanup / db / backend |
| `stress/` | 应力测试（feature-gated behind `stress-test`）：数据生成 + 基准测试 |

**关键机制**（详细原理见 `docs/engineering-notes.md`）：

- **两阶段图片捕获**：Phase 1 同步 hash + 缩略图 → 内存；Phase 2 异步完整 PNG 编码 → DB（单槽有界队列背压，防内存无界增长）
- **内存治理（0.99.10 起）**：启动不读剪贴板；图片捕获按 PNG→TIFF 顺序读最小表示；Phase 2 编码 scratch 复用；空闲池页标记可回收（`madvise MADV_FREE_REUSABLE`）；预览解码走 Rust 而非 ImageIO；自研 u8 resize 替代 `imageops::resize`（避免 f32 中转）。**改任何大缓冲路径前必读 `docs/engineering-notes.md` 的 madvise / claim 契约章节**
- **db_id 不变量**：内存条目的 `db_id` 必须指向 DB 中该条目的行，且赋值按内容 hash 匹配、绝不按头部位置
- **Suppress re-capture**：select_and_paste 通过 `pending_self_write` 标记自身写入，监控线程跳过匹配的 changeCount
- **undo 删除**：撤销栈 ≤1 条，`MAX_UNDO_BYTES`(48MB) 约束的是**磁盘载荷**——删除时先落盘（`$TMPDIR/CopyAttach/Undo/*.bin`），内存只留 `payload_path`/`payload_bytes` + 元数据，blobs 随即 `mark_pages_reusable`（实测删掉 4.19MB 大图后 footprint 反降 7MB）

### Swift 前端（`SwiftApp/`，LSUIElement agent app）

**LSUIElement agent app**：`Info.plist` 设 `LSUIElement=true`，无 Dock 图标，只以 MenuBarExtra + 浮动 NSPanel 存在。级联后果：① 它不是合法粘贴目标——`CGEventPostToPid` 的目标 pid 绝不能是自身；② nonactivating panel 上浮期间 agent 收不到 `applicationDidBecomeActive`，预览捏合手势需 `NSApp.activate(ignoringOtherApps:)` 真实激活；③ 唯一有边框的窗口是许可证门禁窗，其余都是无边框 NSPanel。

```
SwiftApp/
  ├── CopyAttachApp.swift              ← @main, MenuBarExtra
  ├── ClipboardBackend.swift           ← Rust FFI 封装，@Observable，快照轮询/缓存
  ├── HotkeyManager.swift              ← Carbon + NSEvent 双注册，录制模式
  ├── ColorTheme.swift                 ← 深色/浅色颜色体系
  ├── Licensing/                       ← 许可证体系（8 文件）
  ├── App/AppDelegate.swift            ← 生命周期, 弹窗管理, entitlement 门控, 启动时 dup2 stderr → 日志
  ├── Settings/InlineSettingsView.swift ← 5 标签页设置面板
  ├── Onboarding/                      ← 核心操作引导（4 文件：引导模型/浮窗卡片/聚光灯遮罩）
  ├── Popup/                           ← 主弹窗（7 文件：内容/窗口/事件/行/拖拽）
  ├── Preview/                         ← 预览窗口（4 文件：窗口/内容/布局/缩放）
  ├── Backend/                         ← ClipboardItem / ImageDecode / AppIcon 缓存
  └── Utility/                         ← DebugLog / VisualWidth
```

**关键 FFI 模式**：

- **Snapshot API**（`clipboard_snapshot_acquire/release`）：Swift 批量读取时一次性加锁构建紧凑快照（`SnapshotRow`：类型/id/时间戳/label/source/图片尺寸 + preview，**不含全文**），后续无锁访问。新功能优先用此 API
- **稳定 ID**：`entry_id`（u64，AtomicU64 单调递增），用于 `select_and_paste_by_id`，避免数组索引竞争
- **图片加载**：缩略图走 `clipboard_get_image_thumb_by_db_id`（仅 SQLite 读），后台用 ImageIO 降采样到**行显示框**（460×100pt，按屏幕 backupScale 换算像素；Rust 端存储 blob 按 2× 上限 920×200 生成，双向镜像同一组常量）后存入 `NSCache`（countLimit 120、8MB，cost 按实际解码尺寸计），弹窗关闭立即清空；大图走 `clipboard_get_image_full_by_db_id`（优先内存，后备 DB）。预览大图由 Rust 降采样解码，预算 = 显示尺寸×scale 与 2048px 的较小值。**显示框是矩形而非「最长边」**：扁图由宽边限制、竖图由高边限制，按长/短边匹配会让竖图纵向溢出（曾实测 1362×1774 → 200×260 超出 200 高）。
- **select_and_paste**：先查 accessibility 权限（未授权直接 return 0 且不动剪贴板）→ 查 history（by entry_id）→ DB 加载（失败显式 return 0，不兜底）→ 写剪贴板（设 pending_self_write）→ DB write-through → move entry to top → sleep 50ms → Cmd+V。**图片粘贴走唯一的文件路径模式**：先写 `$TMPDIR/CopyAttach/Paste/` 临时 PNG，剪贴板放 `public.file-url`（Finder 复制文件同款）再 Cmd+V
- **粘贴目标 pid 不变式**：Cmd+V 投递给 `source_app.pid`（由 `NSWorkspace.didActivateApplicationNotification` 事件驱动更新，不轮询）。该 pid 必须是用户打开弹窗前的 app，绝不能是 CopyAttach 自身
- **粘贴后必须归还前台**：预览会强制 `NSApp.activate`（捏合手势只投给最前台 app），而系统**不会**自动归还 —— 不归还的话 Cmd+V 仍能投进目标 app（内容进去了），但该 app 留在后台，光标回不到输入框。`selectItem` 粘贴后调 `ClipboardBackend.restorePasteTargetFocus()`；它只在 `NSApp.isActive` 为真时才动手，所以从不激活的普通路径是 no-op

**引导（`Onboarding/`）**：

- **非激活浮窗**（`canBecomeKey=false`）：取 key 会让弹窗失焦并被自动关闭；首击可达靠 `acceptsFirstMouse`
- **单窗口双形态**：欢迎卡片（居中 380×272）与进度卡片（右下角 320×244）是**同一个窗口**，`beginTour()` 时窗口 frame 补间与内容交叉淡入同时进行（一镜到底）。两个尺寸是显式常量而非 measured —— 形变目标必须提前可知，固定卡片高度也顺带消除了步骤间的高度跳动
- **聚光灯遮罩**（`ignoresMouseEvents=true`）：**必须点击穿透**，否则用户无法操作被高亮的控件。洞 = 目标控件，非整个弹窗
- **步骤推进**：`OnboardingGuide.record(_:)` 由真实操作事件驱动（严格顺序，不匹配则忽略）
- **光斑几何按需上报**：`SpotlightFramePreferenceKey`，仅引导期间挂 GeometryReader；行被 LazyVStack 回收时靠 `hasSelectedRow` + `lastRowRect` 区分「滚出视野」与「未选中」
- **窗口层级**：弹窗 `.floating` → 遮罩 `+1` → 引导卡片 `+2`。预览窗与弹窗同层，故在遮罩之下，需一并纳入光斑

**SwiftUI 关键机制**（详细行为见 `docs/engineering-notes.md`）：

- **弹窗开启**：窗口 alpha 淡入 0.2s easeOut，内容 `scaleEffect` 1.10→1.0（`spring(0.2, 0.85)` 接近临界无可见过冲）。淡入看门狗：若首帧事务未提交动画被静默丢弃，`show()` 在 0.3s 后校验并 snap 到可见
- **弹窗关闭**：失焦走 `closeWithAnimation()`（popup 0.12s fade 与 preview 0.1s fade 独立并行，0.4s Timer 保证关闭必然执行）；关闭前必须 `makeFirstResponder(nil)`，停止 macOS 15+ 文本插入光标的 120Hz `CADisplayLink`；关闭时置空 `contentView` 和 `popupHostingView`，令整棵 SwiftUI 视图图及图片引用按会话释放。拖拽后自动关闭走直接 `close()`
- **触控板双指滑动切换标签页**：`.scrollWheel` local monitor 在 ScrollView 前拦截，只认手指手势，水平 ≥50pt 且 h:v ≥ 1.5:1；切换请求在下一轮 run loop 合并，快速往返只提交最新状态；**切换 = 先滚到顶、再切 filter**（单一主流程，解决 scrollPosition 与 LazyVStack 行高估算竞速导致的滚动丢失），列表不再逐行做淡入淡出，仅底栏数量使用 `.numericText()`
- **右键上下文菜单**：行 frame 按需一次性快照（`RowFramePreferenceKey`：仅武装期间行才挂 GeometryReader）——滚动全程无每行几何上报开销，菜单延迟仅一帧
- **搜索**：全文搜索走 SQLite FTS5 trigram 索引（≥3 字符 `MATCH` + 超限行 LIKE 兜底；<3 字符 LIKE 全表扫描）。LIKE 回退是有意保留的语义承诺：1-2 字符查询必须命中长文中段（`test_search_short_query_matches_full_text_middle` 是语义绊线）
- FocusState 双管理：isSearchFocused（selectedIndex=0）和 isContainerFocused（selectedIndex>0）。Escape 三层拦截：SwiftUI `.onKeyPress` → PopupHostingView local monitor → Notification。优先关预览，否则关弹窗
- 选中高亮：`matchedGeometryEffect` 在行间滑动；hover 静态填充；删除模式（⌃⌫）高亮变红

**许可证体系**（`SwiftApp/Licensing/`，8 文件）：

- **激活庆祝时序**：激活成功 → `celebration` → 窗口内播 ~2s 动画 → 回到确认视图，用户手动关闭（已许可时关闭不退出）
- **在线状态轮询（仅试用/订阅）**：每 120s 查询 `/v1/licenses/status` 或 `/v1/trials/status`（无需签名），≤2 分钟内生效。**永久许可证不安排任何周期性检查**——签名 + 设备绑定即权威。关键约定：只有服务器明确返回非活跃状态才降级，`not_found` 和网络失败忽略
- **设备身份**：Secure Enclave P-256 密钥对，`device_id = "sha256:" + base64url(SHA256(公钥))`；物理设备用 `hardware_anchor`（平台 UUID）标识。误删钥匙串后重新激活时服务器按 `license_id + hardware_anchor` 自动换绑，不消耗新座位
- **激活窗口尺寸陷阱**：`LicenseGateView` 必须固定 `.frame(width: 500, height: 470)`，否则庆祝内容替换表单时窗口被 AppKit fitting-size 压缩错位

## FFI 接口

`CopyAttach-Bridging-Header.h` 声明约 60 个 `extern "C"` 函数：生命周期、查询、快照、图片加载、粘贴、权限、删除/撤销/收藏、ignore rules 同步。新接口需在此文件添加声明，并更新 Swift 侧调用封装。

## 钥匙串弹窗

钥匙串条目（Lease + 设备密钥，svce=`com.example.copyattach.licensing`）按创建应用的代码签名授权。**必须用正式签名身份构建**：ad-hoc 签名的 cdhash 每次构建都变，导致每次重开 App 都弹钥匙串授权。build.sh 自动用 `security find-identity` 找 Apple Development 身份，找不到才回退 ad-hoc。

### 严禁用覆盖的 HOME 启动 GUI（踩过的坑）

**不要用 `HOME=/tmp/xxx` 启动 CopyAttach.app 做验证。** 覆盖 HOME 后 `~/Library/Keychains` 不存在，Secure Enclave 的设备密钥（`device-secure-enclave-p256-v1`）查找失败，会弹出「找不到用于储存 … 的钥匙串」对话框，并把测试者引向「沙箱读不到钥匙串」的错误结论。它不是沙箱限制，是测试手法破坏了前置条件。

- 需要隔离数据做验证时，**只有 Rust 测试二进制**（`cargo test` 产物，如直接跑 `target/release/deps/copy_attach-*`）可以用覆盖的 HOME——它不碰钥匙串。GUI 一律用真实 HOME。
- 想验证 GUI 的真实启动/迁移路径又不想动用户数据：可让 Rust 测试二进制跑真实 `clipboard_init`（它读的就是 `$HOME/Library/Application Support/CopyAttach/history.db`），GUI 本身不必启动。
- 另注：启动第二个 GUI 实例会被单实例守卫直接 `exit(0)` 并激活已有实例（日志会出现 `Another CopyAttach instance … is running`），所以「用覆盖 HOME 起一个并行实例」这条路本身也不通。

### GitHub Actions 分发

CI（`.github/workflows/build.yml`）签名步骤关键：`build` job 必须声明 `environment: src2release-env` 才能读到环境级 secrets；证书配了却找不到身份时显式失败（`exit 1`）；公证流程先 `build/package_dmg.sh` 打包，再 `notarytool submit` + `stapler staple` 作用于最终 DMG。

验证方式：`codesign -dv --verbose=4 CopyAttach.app | grep Authority` 必须是身份证书而非 `Signature=adhoc`。

## 构建依赖

- macOS 15.0+（Sequoia）
- Xcode 16+（含 macOS SDK 15.0）
- Rust 1.75+
- Swift 6+

## 测试覆盖

`src/tests.rs`（cfg-gated）+ `src/bench_tests.rs`（cfg-gated on `test` + `stress-test`）。覆盖：去重、图片编解码、FFI 安全、阈值清理、ignore rules、db_id 按内容身份赋值、FTS 大文本上限、应力测试数据生成。

## 详细设计原理

改动以下子系统前，先读 `docs/engineering-notes.md` 对应章节（保存 CLAUDE.md 精简时移出的实测数据、修复史、内存治理细节、UI 行为原理）：

- 数据库（索引上限、FTS 兜底、hash 迁移）
- 两阶段图片捕获与内存治理（**madvise / claim 契约——改任何大缓冲路径前必读**）
- 预览解码（ImageIO 陷阱、imageops::resize 陷阱、关闭路径强制释放）
- 内存基线的真相（勿再追查）
- 捕获正确性（db_id 不变量、幽灵条目根修、suppress re-capture）
- 粘贴（权限检查、文件路径模式、pid 不变式）
- 原生拖拽（智能停车、松手检测）
- 弹窗 UI（开启/关闭、选中高亮、Escape 拦截、触控板滑动切换标签页、右键菜单）
- 许可证体系（激活庆祝、在线轮询、设备身份、尺寸陷阱）
- 签名与分发（钥匙串弹窗、GitHub Actions 修复史）

## .claude 配置

`.claude/settings.local.json` 包含命令白名单权限。新命令需要时在 `permissions.allow` 数组中添加。

## 安装的 Skills

`.claude/skills/`（软链接，实际源在 `.agents/skills/`）：`apple-design` / `emil-design-eng`（Apple 风格 UI 设计原则）；`animation-vocabulary` / `improve-animations` / `review-animations` / `find-animation-opportunities`（动画分析与改进）。
