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

# 调试日志
tail -f /tmp/copyattach_debug.log

# 打开应用
open "CopyAttach.app"
```

build.sh 流程：读取 `Cargo.toml` 版本号 → 通过 PlistBuddy 同步到 `Info.plist`（只需在 Cargo.toml 中改版本） → `cargo build --release` → sips + iconutil 生成图标 → 拷贝 dylib + 设置 install_name → `swiftc` 编译 SwiftApp 下所有 `.swift`（带 FFI 桥接头） → codesign（优先用已安装的 Apple Development 身份，无身份时回退 ad-hoc）。

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
| `ffi.rs` | 所有 `#[no_mangle] extern "C"` 导出函数，Snapshot API（`clipboard_snapshot_acquire/release`），select_and_paste，删除/撤销，存储管理，ignore rules 同步 |
| `tests.rs` | 单元测试（cfg-gated），覆盖：去重/顺序/图片编解码/FFI 安全/阈值清理/边界值/ignore rules |
| `db.rs` | SQLite write-through（rusqlite bundled），mmap 32MB + 512KB page cache，从 DB 加载/写入，legacy JSON 迁移 |
| `monitor.rs` | 后台线程每 300ms 轮询 arboard，先 `changeCount` 轻量检测再读内容，write-through DB，ignore rules 过滤，Finder 文件复制支持 |
| `ignore.rs` | 捕获时忽略规则：按 app bundle ID、文本/图片类型、短文本阈值（Unicode scalar count）过滤。规则在插入前求值 |
| `stress.rs` | 应力测试数据生成与基准测试，feature-gated behind `stress-test`（不在 release 构建中发布）。生成 1 万条混合文本/图片数据 |
| `types.rs` | `ClipboardEntry` 枚举（Text/Image），`SourceApp` 元数据，label 生成 |
| `image.rs` | PNG/JPEG/GIF/WebP/BMP/TIFF 编解码，CatmullRom 缩略图（最长边 300px），`DefaultHasher` 内容哈希 |
| `backend.rs` | `OnceLock<Backend>` 单例，entry_id（`AtomicU64`），常量（3000 阈值、300ms 轮询间隔），`HISTORY_REVISION`/`IMAGE_ENCODING_COUNTER` 原子计数器，`PendingSelfWrite` 自写抑制，`reload_history_from_db` |
| `macos.rs` | NSPasteboard `changeCount`，CGEventPost Cmd+V / Ctrl+V，AXIsProcessTrusted，文件复制检测。cfg-gated，非 macOS 用空桩 |
| `history.rs` | `add_to_history()` — 去重 + 头部插入，纯函数式（返回新 Vec） |
| `bench_tests.rs` | 性能基准测试（cfg-gated on `test` + `stress-test`），覆盖：历史阈值扩展性、图片捕获/编码/缩略图性能、DB 存储规模测试 |
| `lib.rs` | 仅模块声明，`#![allow(dead_code)]` 全局开启 |

**`src/bin/stress_gen.rs`**：独立的 CLI 二进制，通过 Rust FFI 生成应力测试数据并写入 SQLite。需要 `stress-test` feature。

**`src/bin/bench.rs`**：独立的性能基准 CLI，测试快照克隆、计数、图片编解码、CJK 搜索过滤。需要 `stress-test` feature。

**关键机制**：
- **两阶段图片捕获**：Phase 1 同步 hash + CatmullRom 缩略图（最长边 300px）→ 更新内存。Phase 2 异步完整 PNG 编码 → DB write-through → 更新 db_id。避免 4K 截图阻塞监控线程。
- **Suppress re-capture**：select_and_paste 先通过 `pasteboard_event_lock` + `pending_self_write` 标记自身的粘贴板写入，监控线程发现匹配的 changeCount 时跳过。不再依赖内容比对。
- **HISTORY_REVISION**：去重时条目数不变但顺序变了——UI 通过此计数器感知"需要刷新列表"而不仅仅是 count 变化。
- **Ignore rules**：捕获时求值，在条目分配/插入/持久化之前过滤。App 匹配使用 bundle identifier（显示名可变，不可靠）。
- **undo 删除**：通过 `clipboard_last_restored_id()` 精确定位恢复项，避免监控线程插入竞争。
- **原生拖拽**：历史条目支持拖到其他应用。文本→`NSItemProvider(object:)`，图片→临时 PNG 文件 (`public.file-url`)。窗口拖动区限制为 PopupHostingView 外 3pt 边框，避免行拖拽误触窗口移动。拖拽结束检测用 **`NSEvent.pressedMouseButtons` 轮询**（40ms Timer，注册 `.common` + `.eventTracking` 双 run loop 模式）——拖拽期间 run loop 处于 `NSEventTrackingRunLoopMode`，global/local monitor 收不到 mouse-up（官方文档确认该模式限制事件投递），Timer 是可靠信号。开关「拖拽后自动关闭弹窗」（`ClosePopupAfterDrag`，默认开，`object(forKey:) as? Bool ?? true`）开启时，拖拽结束（松手或弹窗失 key）**直接 `close()`——与按 Esc 相同的关闭路径**，无动画、无 completion 依赖；关闭时保持弹窗开启可连续拖拽，下一次外部点击（global click monitor）正常关闭。
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
  ├── App/AppDelegate.swift            ← 生命周期, 弹窗/设置窗口管理, entitlement 门控, 庆祝时序
  │
  ├── Settings/
  │   └── InlineSettingsView.swift     ← 5 标签页设置面板（通用/快捷键/存储/忽略/关于）
  │
  ├── Popup/
  │   ├── HistoryPopupContent.swift    ← 主内容：搜索/列表/预览/Undo，日期分组
  │   ├── HistoryPopupWindow.swift     ← NSPanel 浮动弹窗，拖拽生命周期管理
  │   ├── PopupHostingView.swift       ← 键盘事件拦截（箭头/⌘Z/⌃⌫/⌥P/IME/Esc）
  │   ├── ItemRowView.swift            ← 条目行：文本截断/十六进制色票/图片缩略图
  │   ├── DateSeparatorView.swift      ← 按日历日分组的分隔符视图
  │   ├── LargeTextView.swift          ← NSTextView 大文本渲染
  │   └── ClipboardDragProvider.swift  ← 原生拖拽：文本→NSString，图片→tmp PNG→fileURL
  │
  ├── Preview/
  │   ├── PreviewWindow.swift          ← 非 key 预览 NSPanel，自适应大小
  │   ├── PreviewContent.swift         ← 预览内容（文本/图片异步加载）
  │   ├── PreviewTextLayout.swift      ← 等宽字体 14pt + 行间距 5pt，高度测量
  │   └── ZoomableImageView.swift      ← 捏合缩放/平移/双击重置
  │
  ├── Backend/
  │   ├── ClipboardItem.swift          ← 条目枚举（text/image, Identifiable）
  │   └── AppIcon+Ext.swift            ← NSImage 扩展 + bundleId → NSImage 缓存
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
      ├── DebugLog.swift               ← stderr + /tmp/copyattach_debug.log
      └── VisualWidth.swift            ← CJK=2/ASCII=1 视觉宽度，prefix/suffix 截断
```

**关键 FFI 模式**：
- **Snapshot API**（`clipboard_snapshot_acquire/release`）：Swift 批量读取时一次性加锁构建**紧凑快照**（`SnapshotRow`：类型/id/时间戳/label/source/图片尺寸 + preview，**不含全文**），后续 `snapshot_` 函数无锁访问。避免深克隆 Vec（含全文）造成的刷新瞬态峰值。新功能优先用此 API。
- **稳定 ID**：`entry_id`（u64，AtomicU64 单调递增），用于 `select_and_paste_by_id`，避免数组索引竞争。
- **所有权规则**：`*_free_string` 释放 Rust 分配的 `*mut c_char`；`*_free_bytes` 释放 `*mut u8` 缓冲区（含长度）。
- **图片加载**：缩略图走 `clipboard_get_image_thumb_by_db_id`（仅 SQLite 读，不碰 history 锁）；大图走 `clipboard_get_image_full_by_db_id`（优先内存缓存，后备 DB）。
- **select_and_paste 流程**：查 history（by entry_id）→ DB 加载 png_data → 写系统剪贴板（设 pending_self_write）→ DB write-through（insert/delete/trim，更新 db_id）→ move entry to top → sleep 50ms → Cmd+V（图片可配置 Ctrl+V）。
- **粘贴目标 pid 不变式**：Cmd+V 用 `CGEventPostToPid` 投递给 `source_app.pid`（`clipboard_set_source_app` 每 0.3s 由 Swift 轮询更新）。该 pid 必须是用户打开弹窗前的 app，**绝不能是 CopyAttach 自身**（agent 应用没有粘贴目标）。预览窗口通过 `NSApp.activate(ignoringOtherApps:)` 真实激活才能收到捏合手势（LSUIElement agent 在 nonactivating panel 上浮期间从不收到 applicationDidBecomeActive，`NSApp.isActive` 误报 true），这会让 agent 成为前台应用——`updateSourceApp()` 检测到自 pid 时直接跳过覆盖，保留上一应用为粘贴目标。
- **image_encoding_counter**：Swift 轮询此计数器检测 Phase 2 编码完成，及时刷新缩略图。

**SwiftUI 模型关系**：
- `ClipboardBackend.shared`（@State）— 单数据源，驱动列表刷新
- `HotkeyManager.shared`（@State）— 快捷键显示/录制
- `HistoryPopupWindow.shared` — NSPanel 单例
- FocusState 双管理：isSearchFocused（selectedIndex=0）和 isContainerFocused（selectedIndex>0），解决 TextField focus 接管后 onKeyPress 失效
- Escape 键三层拦截：SwiftUI `.onKeyPress(.escape)`（正常焦点时）→ PopupHostingView 的 NSEvent local monitor（NSTextView 第一响应者时）→ Notification 转发。Escape 在当前焦点下优先关闭预览，否则关闭弹窗。
- **触控板双指左右滑动切换标签页**：PopupHostingView 的 `.scrollWheel` local monitor（`popupSwipeNotification`，方向 "left"=上一标签/"right"=下一标签，与箭头键同约定；页面随手指行进——左滑=下一标签、右滑=上一标签）在 ScrollView 消费事件之前拦截——只认手指手势（`event.phase != []`），鼠标滚轮/惯性动量一律忽略；水平位移累积 ≥50pt 且水平:垂直 ≥ 1.5:1 即在**手势中途**提交切换（`swipeActivationThreshold`/`swipeAxisRatio`，不等松手——内容在手指还在动时就响应，跟手），累积前按 `isDirectionInvertedFromDevice` 还原手指实际方向（自然滚动开/关下行为一致）；手势过程中吞掉事件防列表竖向漂移，`menuTracking` 期间让位。内容侧 `HistoryPopupContent.switchFilterTab(direction:animated:)` 与搜索框 ←/→ 监视器、列表 ←/→ 按键共用；切换动画为**同源数据重过滤**（不做翻页滑动——标签本质是对同一条数据流的过滤条件）：行按 `entry_id` 保持稳定身份，`filterRowTransition` 只让**被过滤掉的行就地溶解**（透明度 + 0.96 缩放，无方向位移）、**新出现的行就地浮现**；**幸存的行没有任何过渡、原地不动**，仅随列表坍缩平滑上移（`filterSwitchAnimation(removed:added:)` 自适应时长：基础 `easeOut(0.15s)`，按实际变更行数——离场 + 入场、各方向封顶 6 行——线性加时至上限 0.28s；标签胶囊用 `.animation(.easeOut(duration: 0.08), value: filterMode)` 即时响应——控件反馈不拖沓，列表动画保持可读；无弹簧过冲）——「同一数据、不同条件」的视觉锚点。日期分隔符同规则；**切换后选中行按索引保留、不按条目跟随**：`switchToFilterTab` 切换前**不捕获选中条目 id**，只统计 removed/added 行数来选定时长。切换后的处理都在 `onChange(of: filterMode)`：关预览；`selectedIndex` 越界时钳制到新列表末尾（`max(0, maxIndex)`）——保留的是**行号而非条目**，entry_id 不跨标签跟随，新列表更短时选中落在末尾而非第一条；`scrollTarget` 置 nil——不强制滚动、保持视口（列表坍缩让幸存行自然重排），也不追逐已消失的行。搜索框聚焦（selectedIndex == 0）时切换，selectedIndex 保持 0，搜索焦点随之保留。滚动靠 `itemsListScrollView` 的 `.scrollPosition(id: $scrollTarget)`：`itemsList` 的 `onChange(of: selectedIndex)` 在选中项移动时用 `scrollTargetForItem(at:)` 设目标（含其上方日期分隔符 id），**无 ScrollViewReader/`scrollTo`**。底栏计数用 `.contentTransition(.numericText())` 滚动数字。标签点击与双指滑动共用同一 `withAnimation`。
- 搜索：searchText → CJK 感知 debounce（CJK 150ms / ASCII 80ms）→ 离线线程过滤 → cached searchResults。全文/标签/来源名匹配在 Rust 侧（`clipboard_search_ids` 对内存 Vec 做大小写不敏感 contains，返回匹配 entry_id）；Swift 侧只并集日期 label 匹配（DayGroup label 是 UI 派生文本，后端没有）。Swift 不再持有 `fullText`——快照只带 `preview`（`clipboard_snapshot_item_preview`，前 256 Unicode scalar），行渲染不变（`ItemRowView.textContent` 本就只读前 200 字符），预览/拖拽按需 `clipboard_get_text_by_id`。搜索栏固定 index 0，项目从 index 1 开始。
- 弹窗关闭：普通失焦/点击外部走 `closeWithAnimation()`（popup 0.12s fade 与 preview 0.1s fade **独立并行**，各自完成即关闭，互不阻塞，另有 `.common` + `.eventTracking` 双模式 Timer 0.4s 保证关闭必然执行——CA completion 在事件跟踪模式下不可靠）；拖拽后自动关闭（开关开启）走**直接 `close()`**，与 Esc 相同，无动画依赖。
- 日期分组：`DayGroup` 枚举按日历日分组条目，`PopupRow` 枚举在扁平列表中渲染分隔符+条目行
- 选中高亮：选中行的 RoundedRectangle 用 `matchedGeometryEffect(id: "itemSelectionHighlight", in: selectionNamespace)`（`@Namespace` 声明在 HistoryPopupContent）在行间滑动，Spotlight 式弹性过渡；hover 为静态填充（`popupRowHover`）。删除模式（按住 ⌃⌫）高亮变红。
- **右键上下文菜单**：`PopupHostingView.rightMouseDown` 用 `PopupRowFrameStore`（各行以 GeometryReader + `RowFramePreferenceKey` 上报 `.global` 屏幕坐标 frame；NSHostingView `isFlipped=true`，`convert(_:from:nil)` 与 `.global` 同坐标系、无需换算）把右键命中映射到行 → 发 `popupContextMenuNotification` → `HistoryPopupContent.showContextMenu` 选中该行并 `NSMenu.popUp`。菜单项 handler 用 `ContextMenuItemTarget`（`NSMenuItem.target` 是 weak，靠 `representedObject` 强持有存活）；动作一律 `currentIndex(of:)` 按**稳定 entry_id 重新解析行**，不用构建菜单时捕获的索引。菜单 tracking 期间（`NSMenu.didBegin/EndTrackingNotification` → `isMenuTracking`）Esc/←/→/⌘Z 全让位给菜单导航，不得关闭弹窗或移动列表选中。图片行含「另存为…」（NSSavePanel 写 PNG）。
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

所有 Rust 测试集中在 `src/tests.rs`（cfg-gated）。覆盖：基本添加与顺序、去重（文本/图片/混合）、图片编解码与缩略图、内容哈希一致性、SourceApp 元数据、label 生成（含多字节安全）、FFI 空指针安全、阈值清理（多个阈值 + 边界 + 百分比 trim + ceil 行为）、阈值变更、ignore rules（app/类型/长度）、应力测试数据生成。

## .claude 配置

`.claude/settings.local.json` 包含命令白名单权限。新命令需要时在此文件 `permissions.allow` 数组中添加。

`vision-hook.js`：`UserPromptSubmit` hook，当 prompt 中包含本地图片路径时，自动通过 vision API 转译为文本描述，使 Claude 无需直接读取图片文件即可理解其内容。

## 安装的 Skills

`.claude/skills/` 目录包含动画/设计相关的 skill（软链接，实际源在 `.agents/skills/`），可用于 UI 动效分析与改进：
- `apple-design`, `emil-design-eng` — Apple 风格 UI 设计原则
- `animation-vocabulary`, `improve-animations`, `review-animations`, `find-animation-opportunities` — 动画分析与改进
