<p align="center">
  <img src="assets/icon_inner.svg" alt="CopyAttach" width="96">
</p>

<h1 align="center">CopyAttach</h1>

<p align="center">
  <strong>做全网最轻量高效的自由开源 macOS 剪贴板管理器。</strong>
</p>

<p align="center">
  <a href="https://github.com/wonaren/copy-attach/releases"><img src="https://img.shields.io/badge/version-0.108.1-blue?style=flat" alt="Version 0.108.1"></a>
  <img src="https://img.shields.io/badge/macOS-15.0%2B-000000?style=flat&logo=apple&logoColor=white" alt="macOS 15.0+">
  <img src="https://img.shields.io/badge/Swift-6%2B-f05138?style=flat&logo=swift&logoColor=white" alt="Swift 6+">
  <img src="https://img.shields.io/badge/Rust-1.75%2B-dea584?style=flat&logo=rust&logoColor=white" alt="Rust 1.75+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPLv3-3da639?style=flat" alt="License GPLv3"></a>
</p>

---

<p align="center">
  <a href="https://copyattach.abovepast.shop/"><img src="assets/icon_inner.svg" alt="CopyAttach" height="14" style="vertical-align: -1px;"> 官方网站 copyattach.abovepast.shop</a>
  &nbsp;&nbsp;·&nbsp;&nbsp;
  <a href="https://github.com/wonaren/copyattach-release/releases">GitHub Releases 下载</a>
  &nbsp;&nbsp;·&nbsp;&nbsp;
  <a href="https://dl.abovepast.shop/lanzou">蓝奏云高速镜像</a>
</p>

CopyAttach 是一款专为 macOS 设计的极轻量、高效、自由开源剪贴板管理器。它在后台默默记录你复制的一切——文本、代码、链接、图片，通过全局快捷键让你在任何应用中极速检索、预览与盲打粘贴。

自 **v0.108.0** 起，CopyAttach 全面转为**完全免费与开源**，代码遵循 **GNU General Public License v3.0 (GPLv3)**。从渲染帧率到磁盘写入，从原子内存回收（madvise）到功耗治理，每个环节都经过严苛打磨，坚守**纯本地离线、零数据上传、零后台遥测**的极客精神。

## 特性

- **秒级唤出** — 全局快捷键（默认 **⌥X**）一键唤出/隐藏，盲打选择，键盘直达粘贴，从唤起到粘贴常在一秒内。
- **事件驱动即时感知** — 底层 Rust 条件变量即时通知前端 UI，捕获到 UI 察觉仅 ~0.3 ms（p95 <0.5 ms），复制后唤出即可立即看到最新内容，彻底告别轮询延迟。
- **全文检索与关键词高亮** — SQLite **FTS5 trigram 索引**：子串匹配、大小写折叠、CJK 同速，搜索关键词在正文、备注与来源应用中实时高亮；全文只存磁盘、不占常驻内存。
- **五大分类过滤标签页** — 全部 / 收藏 / 备注 / 图片 / 文本，触控板双指轻扫或 ←/→ 极速切换；切换即换源过滤，列表不做逐行动画。
- **粘贴队列，逐项取用** — 列表内按 `⌘C` 连续标记多项入队（自动按序标号 ① ② ③），按回车确认后前往目标应用，直接按系统原生的 `⌘V` 即可按顺序逐项粘贴，配合屏幕顶部轻量悬浮胶囊 HUD，大幅减少窗口频繁切换。
- **独立备注与分类管理** — 随时为重要记录添加自定义备注（⌥R），配合独立「备注」过滤 Tab 快速召回高频内容。
- **空格大图与文本预览** — Space 键呼出独立预览窗，文本自适应等宽排版，高清大图支持触控板双指捏合缩放、双击复位与平移，不打断当前工作流。
- **原生拖拽智能避让** — 历史条目直接拖拽送出到任意应用；文本即拖即贴，图片以真实文件送出；拖拽时弹窗智能停车避让，绝不遮挡目标落点。
- **撤销删除（载荷即刻落盘）** — ⌃⌫ 快速删除，⌘Z 撤销恢复；删除时载荷数据立即落盘暂存，内存仅保留轻量元数据，兼顾数据安全与极致内存。
- **图片六大格式全能支持** — 原生支持 PNG/JPEG/GIF/WebP/BMP/TIFF 捕获，两阶段异步编码（缩略图瞬时入列渲染，全量 PNG 异步后台存库），显示框等比 fit 锐利缩放。
- **智能隐私与忽略规则** — 支持按应用 bundle ID、内容类型或短文本过滤，自动拦截 1Password 等密码管理器内容，纯本地离线运行。
- **自由开源 & 纯本地持久化** — 遵循 GNU GPLv3 自由软件协议，基于 SQLite WAL 事务落盘与水位持久化，零网络请求、零数据遥测、永久离线可用。
- **常驻不打扰** — MenuBarExtra 菜单栏常驻（无 Dock 图标），开机启动、后台运行、图标显隐均可自主配置。

> 应用内支持自动检查更新（蓝奏云优先、GitHub Releases 兜底），也可直接从源码一键构建。

## 快捷键

| 操作 | 快捷键 | 效果 |
|---|---|---|
| **唤出 / 隐藏** | **⌥X** | 一键唤出或隐藏历史弹窗（可在设置中自定义录制） |
| **导航选择** | **↑  /  ↓** | 选择上 / 下一条记录 |
| **立即粘贴** | **⏎** | 粘贴选中条目至当前活跃应用并自动收起（若已入队则启动顺序粘贴） |
| **标记入队 / 移出** | **⌘C** | 历史列表内按 ⌘C 标记入队序号 ① ② ③，再次按下取消标记 |
| **完整预览** | **Space** | 预览完整内容（文本等宽排版 / 大图捏合缩放） |
| **收藏切换** | **⌥P** | 收藏 / 取消收藏当前选中条目 |
| **添加备注** | **⌥R** | 为当前条目添加或修改自定义备注 |
| **快速删除** | **⌃⌫** | 删除选中条目（载荷落盘暂存） |
| **撤销删除** | **⌘Z** | 撤销上一步删除操作，原位置恢复 |
| **序号直达** | **⌘1 ~ 9** | 键盘盲打快速粘贴前 1 ~ 9 项 |
| **偏好设置** | **⌘,** | 打开偏好设置（平滑让出焦点直达设置） |
| **切换分类** | **← / →** | 切换过滤标签页（全部 / 收藏 / 备注 / 图片 / 文本） |
| **右键菜单** | **右键** | 上下文菜单（插入 / 预览 / 复制 / 另存为 / 收藏 / 备注 / 删除） |
| **退出 / 取消** | **Esc** | 关闭弹窗或退出预览 |

*注：在触控板上双指左右轻扫亦可流畅切换过滤标签页。*

## 核心设计原则

1. **不搞兜底** — 主流程失败就显式暴露错误，绝不静默降级，确保不会粘贴出错误的内容。
2. **不重复捕获** — 粘贴时通过 `pending_self_write` 抑制重捕，避免自身写回的内容被重复监听形成死循环。
3. **不丢数据** — 每条历史实时 write-through 写入 SQLite，即便断电重启记录依然完好。
4. **不阻塞 UI** — 批量读历史走无锁紧凑快照，Swift 前端随取随用，渲染永不被后台 I/O 挂起。

## 技术栈与架构

- **Rust 后端**（`src/`，编译为 cdylib `libcopy_attach.dylib`）— 剪贴板底层监控、去重、图片 CatmullRom 缩略图与解码、SQLite FTS5 持久化与内存回收（madvise），通过 65 个 C FFI 接口导出。
- **Swift 6 前端**（`SwiftApp/`，LSUIElement agent app）— Swift 6 严格并发架构（`@MainActor` 隔离 + `@Observable` 状态管理），AppKit / SwiftUI 无边框原生浮动面板，ProMotion 120fps 滑动无离屏开销。

## 无负担的设计

作为长期常驻后台的系统级工具，我们对每一毫秒、每一 KB 都斤斤计较：

| 维度 | 设计实践 | 实测表现 |
|---|---|---|
| **性能流畅** | 无锁快照 + 两阶段图片捕获 + 事件驱动刷新 + CatmullRom 快速缩略图 | 10,000 条满压下方向键 12.7 ms 上屏、缩略图解码 ~3.6 ms、复制到列表出现 ~0.3 ms 被感知 |
| **内存克制** | 全文移出内存 + 4MB SQLite page cache + 8MB 缩略图缓存 + madvise 严格回收契约 | 10,000 条（553 MB）库空闲实占 **30.7 MB**，弹窗稳态 58–63 MB，12 轮开关零累积 |
| **存储精简** | 全文走 SQLite FTS5 trigram 索引 + write-through 单事务落盘 + 即时去重与平滑淘汰 | 数据库严格受控于可调阈值，零无界增长 |
| **功耗节制** | changeCount 轻量检测 + Rust 条件变量事件驱动 + Phase 2 有界背压异步编码 | 30 秒 top 连续采样，空闲 CPU 全部 0.0% |
| **交互高效** | ⌥X 一键唤出 + CJK 感知全文搜索 + 关键词实时高亮 + 键盘盲打粘贴 | 按下 ⌥X 到内容挂载 p50 43–55 ms；菜单到发出 ⌘V p50 14.7 ms |

## 压力测试与性能

以下数据为 **v0.108.1 实机复测**（Apple M5 / macOS 27.0.1 / 10 核 / 16 GB，固定随机种子 `42`），全部由 `perf/analyze.py` 的门禁校验通过后采信（本轮 self-check verdict `swift15_rust7_seen11_clk1`，时钟偏差 35–116 µs）。复现路径：`STRESS=1 ./build.sh` 编译带埋点的构建，`stress_gen` 生成数据，CGEvent 注入真实按键驱动交互，`perf/analyze.py` 按 pid + 墙钟窗口切分相位后统计。v0.108.2 只修复了启动裁剪阈值，未改动任何性能路径。

### 数据负载与生成吞吐

| 负载规模 | 条目构成 | 数据生成耗时与速率 | 数据库文件体积 |
|---|---|---|---|
| **日常（3,000 条）** | 1,800 文本 / 1,200 图片 | 11.5 s（261 条/s） | 166.3 MB |
| **满压（10,000 条）** | 6,000 文本 / 4,000 图片 | 38.7 s（258 条/s） | 553.4 MB |

### 冷启动与唤出（10,000 条 / 553 MB 库，各 5 次取中位数）

| 阶段 | 实测值 | 说明 |
|---|---|---|
| `open` → 进程出现 | **60 – 77 ms** | 冷启动不扫剪贴板 |
| `open` → 后端就绪（自检 verdict 落盘） | **203 – 229 ms** | 载入水位、按需元数据、不触全文 |
| `open` → 首屏列表内容可见 | **338 – 434 ms** | 含首次快照解码与首帧渲染 |
| 按下 **⌥X** → 内容挂载 | **p50 43 – 55 ms / p95 78 – 85 ms** | 3,000 条库为 p50 36.5 ms |
| 关闭弹窗 | **p50 5.6 ms / p95 16.0 ms** | 收起动画不阻塞列表释放 |

### 事件驱动交互流水线实测

10,000 条满压库，弹窗打开状态下的真实按键驱动（每个相位单独切窗统计）：

| 关键链路 / 操作 | 3,000 条 | 10,000 条 | 机制与说明 |
|---|---|---|---|
| **捕获 → UI 感知** (`capture->ui_observed`) | p50 0.50 ms / p95 0.57 ms | **p50 0.30 ms / p95 0.47 ms** | Rust condvar 即时唤醒，相比旧版 500 ms 轮询降低 ~99.9% |
| **SQLite 单事务写穿** (`db.write`) | p50 0.96 ms | **p50 1.11 ms / p95 1.43 ms** | insert + dedup + trim 单事务 WAL |
| **Rust 快照序列化** (`snapshot.pack`) | p50 0.45 ms | **p50 1.0 – 1.35 ms** | 242 KB 打包，不是瓶颈 |
| **Swift 快照解码** (`snapshot.decode`) | p50 45.9 ms | **p50 102.1 ms** | 其中 `formatDisplayPreview` 占 **99.9 ms**，构造 String 仅 1.6 ms |
| **列表重载发布** (`popup.reload`) | p50 46.9 ms | **p50 103.3 ms / p95 106.0 ms** | = 解码 + 发布，「复制后整表刷新」的真实成本 |
| **捕获 → 列表就绪** (`capture->list_published`) | p50 47.4 ms | **p50 103.7 ms** | 端到端整表更新 |
| **方向键 → 选中态上屏** | p50 15.9 ms | **p50 12.7 ms / p95 14.4 ms** | 键盘导航不触碰快照 |
| **缩略图解码** (`thumb.decode_total`) | p50 5.4 ms | **p50 3.6 – 4.3 ms / p95 5.1 ms** | 拆解：读 blob 0.09 ms + ImageIO 0.9 ms，其余为排队 |
| **预览窗口建立** (`preview.open`) | p50 10.1 ms | **p50 9.8 ms / p95 13.4 ms** | 其中 Rust 池化解码 6.0 ms |
| **菜单 → 发出 ⌘V** (`paste.menu_to_keystroke`) | — | **p50 14.7 ms**（11.5 – 17.4 ms） | 含两阶段写剪贴板与关闭弹窗 |
| **撤销删除** (`undo.perform`) | — | **p50 6.8 ms** | 主线程同步 DB 读 + 回插 |

> ⚠️ **口径修正**：此前 README 记载的「列表重载 13.88 ms」是在 151 条库上测得的，10,000 条满压复测为 **103 ms**，随行数线性增长（~10 µs/行），成本 98% 落在 Swift 侧的 `formatDisplayPreview`。这是当前最大的一处待优化点（Rust 侧等价实现实测 647 ns/行，10,000 行约 6.5 ms）。

### 内存基线与治理真相

> 💡 **内存测量标准**：以 `vmmap -summary` 的 `Writable regions` 为准（`resident` = 真实物理内存，`written` = 脏页账本），并同时记录 `Physical footprint`。关闭埋点后测量（埋点本身每 span 写一行日志会抬高占用与 CPU）。

| 运行场景 | 物理内存 `footprint` | `resident` | `written` | 机制说明 |
|---|---|---|---|---|
| **干净冷启动空闲（10,000 条库）** | **30.7 MB**（峰值 33.1） | 28.0 MB | 27.9 MB | 启动不扫剪贴板，元数据按需加载 |
| **干净冷启动空闲（3,000 条库）** | **25.0 MB** | 20.7 MB | 20.6 MB | 与库体积弱相关 |
| **弹窗稳态（10,000 条）** | **57.6 – 63.1 MB** | 46.1 – 70.1 MB | 39.8 – 41.9 MB | SwiftUI 视图图 + CoreText 字形缓存 + 8 MB 缩略图缓存 |
| **关闭弹窗后（12 轮开关）** | **56.6 – 60.3 MB** | 46.1 – 57.9 MB | 39.8 – 42.1 MB | 第 7 轮起稳定在 56.7 MB 上下，无累积增长 |
| **4K 图预览瞬时峰值**（3,000 条库） | **83.3 MB** | 108 MB | 61.3 MB | 3840×2160 RGBA 解码缓冲 |
| **关闭预览与弹窗后**（同上） | **72.4 MB** | 94.8 MB | 48.8 MB | 比该次操作前（51.6 MB）高 ~21 MB，未完全回落 |
| **撤销删除（⌘Z）栈开销** | 0 MB（零钉住） | — | — | 载荷删除时立即落盘，内存仅留路径引用 |
| **空闲 CPU** | **0.0%**（30 次 1 s 采样全部为 0） | — | — | changeCount 轻量检测 + 事件驱动 |

### 全文与元数据搜索实测（10,000 条库，6,000 条文本）

`clipboard_search_ids` 一次调用会跑三条 SQL（FTS5 + 超长文本兜底 LIKE + 元数据 LIKE），下面按 SQL 层与端到端两层分别给出：

| 层次 | 实测耗时（p50） | 说明 |
|---|---|---|
| **FTS5 trigram 命中（≥3 字符）** | **10.2 ms**（命中 2,846 行） | `lorem` 命中面很宽时的最坏情况；命中 10 行的 CJK 词为 **0.01 ms** |
| **超长文本兜底 LIKE** | **43.7 ms** | 对 `length(text) > 512 KB` 的行做 LIKE；本库无此类行，成本来自 6,000 行全扫 |
| **元数据 LIKE（备注/自定义标签/来源应用）** | **40.3 ms** | 1 万行三列 LIKE 扫描 |
| **Rust `search.query` 合计** | **41 – 106 ms** | 上述三条之和 + 去重；两次独立运行分别 41.4 / 105.8 ms |
| **Swift 端到端（含 debounce）** | **236 – 325 ms** | ASCII 去抖 80 ms、CJK 去抖 150 ms |
| **同上，3,000 条库** | **144 – 235 ms** | 端到端随行数近似线性 |

> CJK 查询端到端比 ASCII 稳定多 ~70 ms，差值正好等于两档 debounce 之差（150 − 80 ms），与结果集大小无关。

## 构建与运行

### 环境要求
- **macOS 15.0+（Sequoia）**
- **Xcode 16+**（含 macOS SDK 15.0+）
- **Rust 1.75+**

### 一键构建
```bash
# 完整构建（Rust release + Swift 应用编译 + 证书签名）
./build.sh

# 编译带压力测试面板的版本
STRESS=1 ./build.sh

# 仅编译 Rust 动态库
cargo build --release

# 运行单元测试
cargo test
```

产物将输出至根目录下的 `CopyAttach.app`，直接执行 `open "CopyAttach.app"` 即可运行体验。

## 免费与开源

CopyAttach 自 **v0.108.0** 起全面免费与开源。所有功能无需激活码、无需联网验证、永久离线可用。

## 许可证

本项目遵循 [GNU General Public License v3.0](LICENSE) (GPL-3.0) 自由软件协议。

商业历史版本（<= v0.107.10）及相关许可证架构已归档封存于 `archive/commercial-v0.107` 分支。
