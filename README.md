<p align="center">
  <img src="assets/icon_inner.svg" alt="CopyAttach" width="96">
</p>

<h1 align="center">CopyAttach</h1>

<p align="center">
  <strong>做全网最轻量高效的自由开源 macOS 剪贴板管理器。</strong>
</p>

<p align="center">
  <a href="https://github.com/wonaren/copy-attach/releases"><img src="https://img.shields.io/badge/version-0.108.0-blue?style=flat" alt="Version 0.108.0"></a>
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
| **性能流畅** | 无锁快照 + 两阶段图片捕获 + 事件驱动刷新 + CatmullRom 快速缩略图 | 列表滚动不掉帧，4K 截图复制零卡顿，复制后即时呈现零延迟感 |
| **内存克制** | 全文移出内存 + 4MB LRU page cache + 8MB 缩略图缓存 + madvise 严格回收契约 | 内存与粘贴大文本解耦，空闲态物理内存稳定在 ~24–34 MB |
| **存储精简** | 全文走 SQLite FTS5 trigram 索引 + write-through 单事务落盘 + 即时去重与平滑淘汰 | 数据库严格受控于可调阈值，零无界增长 |
| **功耗节制** | changeCount 轻量检测 + Rust 条件变量事件驱动 + Phase 2 有界背压异步编码 | 空闲时 CPU 占用近乎 0.0%，全天常驻不消耗电池续航 |
| **交互高效** | ⌥X 一键唤出 + CJK 感知全文搜索 + 关键词实时高亮 + 键盘盲打粘贴 | 从唤起到粘贴，常在一秒内完成 |

## 压力测试与性能

以下数据基于在 macOS（Apple Silicon，固定随机种子 `42`）上实机采集。完整测试流程可通过 `STRESS=1 ./build.sh`（编译压力测试面板与基准工具）、`bash stress_test.sh`（生成数据并采集指标）与 `perf/analyze.py`（纳秒级埋点分析器）进行复现与验证。

### 数据负载与生成吞吐

| 负载规模 | 条目构成 | 数据生成耗时与速率 | 数据库文件体积 |
|---|---|---|---|
| **日常（3,000 条）** | 1,800 文本 / 1,200 图片 | 11.69 s（257 条/s） | 166.2 MB |
| **满压（10,000 条）** | 6,000 文本 / 4,000 图片 | 40.24 s（249 条/s） | 553.1 MB |

### 应用级指标（10,000 条满压数据部署实测）

CopyAttach 是单进程应用（Rust 后端以 dylib 载入 Swift app 进程），以下为整个进程在部署 10,000 条数据库（553 MB）下的实机实测值：

| 指标 | 10,000 条（满压）实测值 | 测量方法与说明 |
|---|---|---|
| **冷启动耗时** | **~169 ms** | 从 `open` 发起到进程出现并就绪，元数据与缩略图按需加载 |
| **空闲态 · 物理内存 (`resident`)** | **~24 – 34 MB** | `vmmap -summary` 的 `resident`，空闲态无泄漏，无虚假膨胀 |
| **空闲态 · 脏页账本 (`written`)** | **~24 – 37 MB** | `vmmap -summary` 的 `written`，包含所有未释放的脏页 |
| **空闲 CPU** | **0.0%** | 5 秒 top 采样，changeCount 轻量检测，安静时后台完全静止 |

### 事件驱动交互流水线实测（高精度纳秒仪表）

| 关键链路 / 操作 | 实测耗时 (p50) | 实测耗时 (p95) | 机制与表现 |
|---|---|---|---|
| **捕获 → UI 感知 (`capture->ui_observed`)** | **306 µs (~0.31 ms)** | **422 µs (~0.42 ms)** | Rust condvar 即时唤醒，相比旧版 500ms 定时轮询延迟降低 **~99.9%** |
| **捕获 → 列表就绪 (`capture->list_published`)** | **14.27 ms** | **14.94 ms** | 端到端整表更新，几乎达到人类视觉即时感知极限 |
| **列表重载发布 (`popup.reload`)** | **13.88 ms** | **14.60 ms** | 10,000 条满压下解码并发布完整列表 |
| **SQLite 单事务写穿 (`db.write`)** | **606 µs (~0.61 ms)** | **712 µs (~0.71 ms)** | insert + dedup + trim 单事务 WAL 一次性落盘 |
| **快捷键唤出到内容挂载 (`open->content_appear`)** | **~92.8 ms** | **~92.8 ms** | 0.2s 视觉平滑淡入与首帧渲染极速就位 |

### 内存基线与治理真相

> 💡 **内存测量标准**：判定常驻内存只认 `vmmap -summary` 的 `Writable regions`（`resident` 为真正物理内存占用，`written` 包含已被系统压缩换出的冷页，不使用易产生账本混淆的 `footprint` 单值）。详见 `CLAUDE.md`「内存测量」与 `docs/engineering-notes.md`。

| 运行场景 | 真实物理内存 (`resident`) | 脏页账本 (`written`) | 机制说明 |
|---|---|---|---|
| **干净冷启动空闲** | **19 – 22 MB** | ~20 MB | 启动不扫剪贴板，冷启动秒开，元数据按需加载 |
| **弹窗唤起后常驻稳态** | **36 – 44 MB** | ~60 – 75 MB | 包含 SwiftUI 视图图、CoreText 字形缓存与 8MB 缩略图缓存，多轮开关**零累积** |
| **大图预览/复制瞬时峰值** | ~70 – 110 MB | — | 2880×1800 或 4K 大图瞬时解码缓冲，独占池化管理 |
| **关闭预览/弹窗后回落** | **即刻回落至 ~44 MB** | — | `madvise(MADV_FREE_REUSABLE)` 强制归还系统，杜绝内存滞留 |
| **撤销删除（⌘Z）栈开销** | **0 MB（零内存钉住）** | — | 载荷删除时立即落盘至临时目录，内存仅留路径引用，删大图后物理内存反降 |

### 全文与元数据搜索实测（10,000 条真实库，6,000 文本）

| 查询类型 | 实测耗时 | 说明 |
|---|---|---|
| **FTS5 子串检索 (≥3 字符)** | **0.01 – 0.56 ms** | SQLite FTS5 trigram 索引：常见词条亚毫秒级匹配、全 Unicode 大小写折叠、CJK 同速 |
| **元数据即时匹配** | **~48 – 50 ms** | 覆盖备注、自定义标签、来源应用，图片条目支持按来源与备注瞬时检索 |
| **LIKE 兜底 (<3 字符)** | **~70 – 140 ms** | 1–2 字符无法构成 trigram，退化为全表扫描，确保长文中段不漏匹配 |

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
