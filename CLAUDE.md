# CLAUDE.md

CopyAttach 是一个 macOS 剪贴板历史管理器：Rust 后端（cdylib）+ Swift 前端（LSUIElement agent app）+ SQLite 持久化 + 许可证体系。

## 行为约定

### 从第一性原理分析代码
先理解核心数据流和不变量的本质，再逐层验证具体实现是否忠实于这些原理。不依赖既有注释、命名或架构图——它们可能过时。

### 不要搞兜底实现
不写 fallback / 兜底逻辑。兜底会掩盖主流程错误，让 bug 难以发现。主流程失败应该显式暴露（panic、返回错误、日志 + 空结果），由调用方决定如何处理。

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
- **版本号**：唯一版本源在 `Cargo.toml` 的 `version` 字段，`build.sh` 自动同步到 `Info.plist` 的 `CFBundleShortVersionString`。开发版本带 `-dev` 后缀（如 `0.93.0-dev`），发布版本去掉后缀。每次功能/修复提交都提升版本号并写入提交信息。
- **CHANGELOG 规范**：内容必须**纯面向用户且简洁凝练**。

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
| `image.rs` | PNG/JPEG/GIF/WebP/BMP/TIFF 编解码，CatmullRom 缩略图（最长边 300px），FNV-1a 内容哈希 |
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
- **undo 删除**：撤销栈 ≤1 条，单条 ≤48MB（文本正文 + 图片 blob 统一计入），入栈为移动语义

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
  ├── Popup/                           ← 主弹窗（7 文件：内容/窗口/事件/行/拖拽）
  ├── Preview/                         ← 预览窗口（4 文件：窗口/内容/布局/缩放）
  ├── Backend/                         ← ClipboardItem / ImageDecode / AppIcon 缓存
  └── Utility/                         ← DebugLog / VisualWidth
```

**关键 FFI 模式**：

- **Snapshot API**（`clipboard_snapshot_acquire/release`）：Swift 批量读取时一次性加锁构建紧凑快照（`SnapshotRow`：类型/id/时间戳/label/source/图片尺寸 + preview，**不含全文**），后续无锁访问。新功能优先用此 API
- **稳定 ID**：`entry_id`（u64，AtomicU64 单调递增），用于 `select_and_paste_by_id`，避免数组索引竞争
- **图片加载**：缩略图走 `clipboard_get_image_thumb_by_db_id`（仅 SQLite 读），后台用 ImageIO 降采样至最长边 160px（禁用 ImageIO 驻留缓存）后存入 `NSCache`（countLimit 60、4MB），弹窗关闭立即清空；大图走 `clipboard_get_image_full_by_db_id`（优先内存，后备 DB）。预览大图由 Rust 降采样解码，预算 = 显示尺寸×scale 与 2048px 的较小值
- **select_and_paste**：先查 accessibility 权限（未授权直接 return 0 且不动剪贴板）→ 查 history（by entry_id）→ DB 加载（失败显式 return 0，不兜底）→ 写剪贴板（设 pending_self_write）→ DB write-through → move entry to top → sleep 50ms → Cmd+V。**图片粘贴走唯一的文件路径模式**：先写 `$TMPDIR/CopyAttach/Paste/` 临时 PNG，剪贴板放 `public.file-url`（Finder 复制文件同款）再 Cmd+V
- **粘贴目标 pid 不变式**：Cmd+V 投递给 `source_app.pid`（由 `NSWorkspace.didActivateApplicationNotification` 事件驱动更新，不轮询）。该 pid 必须是用户打开弹窗前的 app，绝不能是 CopyAttach 自身

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
