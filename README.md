<p align="center">
  <img src="assets/icon_inner.svg" alt="CopyAttach" width="96">
</p>

<h1 align="center">CopyAttach</h1>

<p align="center">
  <strong>做全网最轻量高效的剪贴板管理软件。</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-0.107.0-blue?style=flat" alt="Version 0.107.0">
  <img src="https://img.shields.io/badge/macOS-15.0%2B-000000?style=flat&logo=apple&logoColor=white" alt="macOS 15.0+">
  <img src="https://img.shields.io/badge/Swift-6%2B-f05138?style=flat&logo=swift&logoColor=white" alt="Swift 6+">
  <img src="https://img.shields.io/badge/Rust-1.75%2B-dea584?style=flat&logo=rust&logoColor=white" alt="Rust 1.75+">
  <img src="https://img.shields.io/badge/license-Apache%202.0-3da639?style=flat" alt="License Apache 2.0">
</p>

---

<p align="center">
  <a href="https://copyattach.abovepast.shop/"><img src="assets/icon_inner.svg" alt="CopyAttach" height="14" style="vertical-align: -1px;"> 项目官网 copyattach.abovepast.shop</a>
  &nbsp;&nbsp;·&nbsp;&nbsp;
  <a href="https://pay.ldxp.cn/shop/F5T5GUPN"><img src="assets/ldxp.svg" alt="链动小铺" height="14" style="vertical-align: -1px;"> 购买许可证</a>
</p>

CopyAttach 是一个 macOS 剪贴板管理器。它默默记录你复制的一切——文本、代码、链接、图片——然后通过一个快捷键让你在任何应用中快速搜索、预览、粘贴。从渲染帧率到磁盘写入，从内存分配到功耗管理，每个环节都经过精心优化，做到真正的无负担。

## 特性

- **秒级唤出** — 全局快捷键（默认 **⌥X**）一键唤出/隐藏，键盘直达粘贴，从唤起到粘贴常在一秒内
- **事件驱动即时感知** — 剪贴板变动后由底层 Rust 条件变量即时通知 UI，捕获到 UI 察觉仅 ~0.3 ms（p95 <0.5 ms），复制后唤出即可立即看到最新内容，彻底告别轮询延迟
- **全文搜索** — SQLite **FTS5 trigram 索引**：子串匹配、大小写折叠、CJK 同速；全文只存磁盘、不占内存，内存与粘贴文本大小解耦。图片条目支持按备注与来源应用检索
- **过滤标签页** — 全部 / 收藏 / 图片 / 文本，双指左右滑动或 ←/→ 切换；切换即换源过滤，列表不做逐行动画
- **富交互** — 预览（文本等宽渲染 + 图片捏合缩放/平移）、收藏、快速删除、撤销删除（最近 1 步）、⌘1-9 快捷选择、右键上下文菜单、⌘, 直达偏好设置、原生拖拽到任意应用（支持连续拖拽模式，拖拽时弹窗智能防遮挡落点）
- **图片全能** — 支持 PNG/JPEG/GIF/WebP/BMP/TIFF 六种格式捕获，两阶段捕获（先轻量缩略图入列、后异步全量 PNG 编码），按 920×200 矩形框等比 fit 锐利缩放，大图按需加载与并发解码门控
- **智能忽略** — 按应用（bundle identifier）、按类型（文本/图片）、按短文本阈值与敏感内容过滤，在捕获前拦截
- **存储可控** — SQLite write-through 即时去重，可调清理阈值（100–10,000），存储统计一目了然，水位持久化确保重启不复活、不串 ID
- **常驻不打扰** — 菜单栏图标（无 Dock 图标），开机启动、后台运行、图标显隐均可开关

> 应用内支持自动检查更新（蓝奏云优先、GitHub Releases 兜底），也可从源码自行构建。

## 快捷键

| 操作 | 效果 |
|---|---|
| **⌥X** | 唤出 / 隐藏历史弹窗（可在设置中录制自定义） |
| **↑  /  ↓** | 选择上 / 下一条 |
| **⏎** | 粘贴选中条目 |
| **Space** | 预览完整内容 |
| **⌥P** | 收藏 / 取消收藏 |
| **⌥R** | 添加 / 编辑备注 |
| **⌃⌫** | 删除选中条目 |
| **⌘Z** | 撤销删除（最近 1 步） |
| **⌘1 ~ 9** | 快速粘贴第 1 ~ 9 项 |
| **⌘,** | 打开偏好设置（平滑让出焦点直达设置） |
| **← / →** | 切换过滤标签页 |
| **右键** | 上下文菜单（插入 / 预览 / 复制 / 另存为 / 收藏 / 备注 / 删除） |
| **Esc** | 关闭弹窗 / 预览 |

触控板上双指左右滑动同样可以切换标签页。

## 核心设计原则

1. **不搞兜底**——主流程失败就暴露错误，不静默降级。你不会粘贴到错误的内容。
2. **不重复捕获**——粘贴时不会把自己刚写回的内容又读进来，形成死循环。
3. **不丢数据**——每条历史实时写入 SQLite，重启还在。
4. **不阻塞 UI**——读历史走无锁快照，Swift 随时拿到完整数据。

## 技术栈

- **Rust 后端**（`cdylib` → `libcopy_attach.dylib`）——剪贴板监控、去重、图片编解码、SQLite 持久化、全文索引，经 C FFI 暴露给 Swift
- **Swift 6 前端**（AppKit/SwiftUI）——启用 Swift 6 严格并发（`@MainActor` 隔离 + `@Observable` 状态管理），无锁快照驱动渲染

## 无负担的设计

作为常驻菜单栏的工具，我们对每一毫秒、每一 KB 都斤斤计较：

| 维度 | 做法 | 效果 |
|---|---|---|
| **性能流畅** | 无锁快照 + 两阶段图片捕获 + 事件驱动刷新 + CatmullRom 快速缩略图 | 列表滚动不掉帧，4K 截图不卡顿，复制后即时呈现零延迟感 |
| **内存克制** | 全文移出内存 + 4MB LRU page cache（禁用 mmap，FTS 索引不入驻内存）+ 8MB 缩略图缓存（按解码尺寸计量）+ madvise/claim 严格回收契约 | 内存与粘贴文本大小解耦，空闲态常驻物理占用稳定在 ~36–44 MB |
| **存储精简** | 全文走 SQLite FTS5 trigram 索引 + write-through 单事务落盘 + 即时去重与范围淘汰 | 数据库始终控制在阈值内，零碎片增长 |
| **功耗节制** | changeCount 轻量检测 + Rust 条件变量事件驱动 + Phase 2 有界背压异步编码 | 安静时 CPU 占用近乎为零，杜绝后台空转 |
| **交互高效** | ⌥X 一键唤出 + CJK 感知搜索 + 键盘直达粘贴 + ⌘, 直达偏好设置 | 从唤起到粘贴，常在一秒内完成 |

## 压力测试与性能

以下数据基于 **`0.106.0` 正式版**在 macOS（Apple Silicon，固定随机种子 `42`）上实机采集。完整测试流程可通过 `STRESS=1 ./build.sh`（编译压力测试面板与基准工具）、`bash stress_test.sh`（生成数据并采集指标）与 `perf/analyze.py`（纳秒级埋点分析器）进行复现与验证。

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

CopyAttach 是单进程应用（Rust 后端以 dylib 载入 Swift app 进程）。剪贴板变动后由底层 Rust 条件变量即时通知前端，UI 阻塞等待并在唤醒后即刻重载快照。以下为生产构建下的纳秒级埋点实测值（详见 `perf/BASELINE.md`）：

| 关键链路 / 操作 | 实测耗时 (p50) | 实测耗时 (p95) | 机制与表现 |
|---|---|---|---|
| **捕获 → UI 感知 (`capture->ui_observed`)** | **306 µs (~0.31 ms)** | **422 µs (~0.42 ms)** | Rust condvar 即时唤醒，相比旧版 500ms 定时轮询延迟降低 **~99.9%** |
| **捕获 → 列表就绪 (`capture->list_published`)** | **14.27 ms** | **14.94 ms** | 端到端整表更新（含无锁快照解构与文本格式化），几乎达到人类视觉即时感知极限 |
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
| **关闭预览/弹窗后回落** | **即刻回落至 ~44 MB** | — | `madvise(MADV_FREE_REUSABLE)` + claim 契约强制归还系统，杜绝内存滞留 |
| **撤销删除（⌘Z）栈开销** | **0 MB（零内存钉住）** | — | 载荷（≤48MB）删除时立即落盘至临时目录，内存仅留路径引用，删大图后物理内存反降 |

### 全文与元数据搜索实测（10,000 条真实库，6,000 文本）

| 查询类型 | 实测耗时 | 说明 |
|---|---|---|
| **FTS5 子串检索 (≥3 字符)** | **0.01 – 0.56 ms**（命中近 2,000 行时 ~68 ms） | SQLite FTS5 trigram 索引：常见词条亚毫秒级匹配、全 Unicode 大小写折叠、CJK 同速 |
| **元数据即时匹配** | **~48 – 50 ms** | 覆盖备注、自定义标签、来源应用，图片条目支持按来源与备注瞬时检索 |
| **LIKE 兜底 (<3 字符)** | **~70 – 140 ms** | 1–2 字符无法构成 trigram，退化为全表扫描，确保长文中段不漏匹配 |

### Rust 内部基准（`cargo run --release --bin bench --features stress-test` 实测）

| 指标 | 成绩 | 说明 |
|---|---|---|
| **快照获取 (`snapshot.acquire`)** | **0.08 – 3.16 µs** | 100 → 10,000 条条目无锁快照 clone，读取绝不阻塞后台写入 |
| **计数开销 (`get_count`)** | **~6.0 – 7.9 ns** | `.len()` 常数时间 O(1)，不随历史规模增长 |
| **图片异步全量编码** | **1.5 – 9.5 ms** | 540p → 4K UHD PNG 异步编码，背压队列防内存无界堆积 |
| **图片全量解码** | **1.6 – 13.4 ms** | 540p → 4K UHD PNG 解码 |
| **缩略图生成与编码** | **~0.1 ms** | 等比 fit 进 920×200 显示框（≤460×100pt @2x），CatmullRom 锐利缩放 |


### 快捷键系统

两种机制确保在任何场景下都能唤出弹窗：

- **Carbon RegisterEventHotKey** — 系统级注册，应用在后台也生效，**不需要**辅助功能权限
- **NSEvent global monitor** — 后备方案，覆盖 Carbon 的边缘情况（Carbon 注册失败时接管）

NSEvent 后备路径与「粘贴时模拟 ⌘V」都依赖 macOS「辅助功能权限」，因此应用仍会引导授权：首次运行时自动提示，设置页可一键打开系统设置，或直接把应用图标拖入授权列表。未授权时 Carbon 主路径的唤出快捷键依然可用，仅自动粘贴不可用。

## 构建

```bash
# 完整构建（Rust release + Swift 应用 + 签名）
./build.sh

# 带压力测试面板与 bench 的构建
STRESS=1 ./build.sh

# 仅 Rust 构建 / 检查 / 测试
cargo build --release
cargo check
cargo test
```

构建要求：**macOS 15.0+（Sequoia）**、**Xcode 16+**、**Rust 1.75+**。

> 默认连接生产许可证服务器；本地开发可用 `LICENSE_ENV=local COPYATTACH_LICENSE_PUBLIC_KEY='<dev 公钥>' ./build.sh` 指向本地 license-server。

## 购买与激活

- **购买许可证**：前往 [<img src="assets/ldxp.svg" alt="链动小铺" height="14" style="vertical-align: -1px;"> 在线店铺](https://pay.ldxp.cn/shop/F5T5GUPN) 购买激活码。
- **激活流程**：构建或下载的应用支持免费试用与激活码激活；激活码按设备绑定，Lease 离线验证，断网后仍可继续使用。

## 许可证

Apache 2.0
