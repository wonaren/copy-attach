<p align="center">
  <img src="assets/icon_inner.svg" alt="CopyAttach" width="96">
</p>

<h1 align="center">CopyAttach</h1>

<p align="center">
  <strong>做全网最轻量高效的剪贴板管理软件。</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15.0%2B-000000?style=flat&logo=apple&logoColor=white" alt="macOS 15.0+">
  <img src="https://img.shields.io/badge/Swift-6%2B-f05138?style=flat&logo=swift&logoColor=white" alt="Swift 6+">
  <img src="https://img.shields.io/badge/Rust-1.75%2B-dea584?style=flat&logo=rust&logoColor=white" alt="Rust 1.75+">
  <img src="https://img.shields.io/badge/license-Apache%202.0-3da639?style=flat" alt="License Apache 2.0">
</p>

---

<p align="center">
  <a href="https://copyattach.abovepast.shop/">🌐 项目官网 copyattach.abovepast.shop</a>
  &nbsp;&nbsp;·&nbsp;&nbsp;
  <a href="https://pay.ldxp.cn/shop/F5T5GUPN"><img src="assets/ldxp.svg" alt="链动小铺" height="14" style="vertical-align: -1px;"> 购买许可证</a>
</p>

CopyAttach 是一个 macOS 剪贴板管理器。它默默记录你复制的一切——文本、代码、链接、图片——然后通过一个快捷键让你在任何应用中快速搜索、预览、粘贴。从渲染帧率到磁盘写入，从内存分配到功耗管理，每个环节都经过精心优化，做到真正的无负担。

## 特性

- **秒级唤出** — 全局快捷键（默认 **⌥X**）一键唤出/隐藏，键盘直达粘贴，从唤起到粘贴常在一秒内
- **全文搜索** — SQLite **FTS5 trigram 索引**：子串匹配、大小写折叠、CJK 同速；全文只存磁盘、不占内存，内存与粘贴文本大小解耦
- **过滤标签页** — 全部 / 收藏 / 图片 / 文本，双指左右滑动或 ←/→ 切换；同源数据重过滤，行就地溶解/浮现
- **富交互** — 预览（文本等宽渲染 + 图片捏合缩放/平移）、收藏、快速删除、撤销删除（最近 1 步）、⌘1-9 快捷选择、右键上下文菜单、原生拖拽到任意应用（拖拽时弹窗智能防遮挡落点）
- **图片全能** — 支持 PNG/JPEG/GIF/WebP/BMP/TIFF，两阶段捕获（先轻量缩略图入列、后异步全量编码），图片按需加载
- **智能忽略** — 按应用（bundle identifier）、按类型（文本/图片）、按短文本阈值过滤，在捕获前拦截
- **存储可控** — SQLite write-through 即时去重，可调清理阈值（100–10,000），存储统计一目了然
- **常驻不打扰** — 菜单栏图标（无 Dock 图标），开机启动、后台运行、图标显隐均可开关

> 应用内支持自动检查更新（GitHub Releases），也可从源码自行构建。

## 快捷键

| 操作 | 效果 |
|---|---|
| **⌥X** | 唤出 / 隐藏历史弹窗（可在设置中录制自定义） |
| **↑  /  ↓** | 选择上 / 下一条 |
| **⏎** | 粘贴选中条目 |
| **Space** | 预览完整内容 |
| **⌥P** | 收藏 / 取消收藏 |
| **⌃⌫** | 删除选中条目 |
| **⌘Z** | 撤销删除（最近 1 步） |
| **⌘1 ~ 9** | 快速选择第 1 ~ 9 项 |
| **← / →** | 切换过滤标签页 |
| **右键** | 上下文菜单（插入 / 预览 / 复制 / 另存为 / 收藏 / 删除） |
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
| **性能流畅** | 无锁快照 + 两阶段图片捕获 + CatmullRom 快速缩略图 | 列表滚动不掉帧，4K 截图不卡顿 |
| **内存克制** | 全文移出内存 + 4MB LRU page cache（禁用 mmap，FTS 索引不入驻内存）+ 10MB 缩略图缓存 + 动态阈值裁剪 | 内存与粘贴文本大小解耦，随条目数亚线性增长 |
| **存储精简** | 全文走 SQLite FTS5 trigram 索引 + write-through 即时去重 + 自动淘汰 | 数据库始终控制在阈值内，零碎片增长 |
| **功耗节制** | changeCount 轻量检测 + 500ms 低频轮询 + 异步编码 | 安静时 CPU 占用近乎为零 |
| **交互高效** | ⌥X 一键唤出 + CJK 感知搜索 + 键盘直达粘贴 | 从唤起到粘贴，常在一秒内完成 |

## 压力测试与性能

以下均为 **2026-08-19 在 `0.99.20-dev` 构建上实机采集**（macOS 26.6.2 / Apple Silicon，固定随机种子 `42`）。完整流程见 `STRESS=1 ./build.sh` + `bash stress_test.sh`。

| 负载 | 条目构成 | 数据生成 | 数据库体积 |
|---|---|---|---|
| **日常（3000 条）** | 1,800 文本 / 1,200 图片 | 11.047 s（272 条/s） | 166.47 MB |
| **满压（10,000 条）** | 6,000 文本 / 4,000 图片 | 37.364 s（268 条/s） | 554.15 MB |

### 应用级指标（实机采集）

CopyAttach 是单进程应用（Rust 后端以 dylib 载入 Swift app 进程），以下均为**整个进程**的实测值。

| 指标 | 3000 条（日常） | 10000 条（满压） | 说明 |
|---|---|---|---|
| **空闲态 · 物理内存 / RSS**（菜单栏，弹窗关闭） | 14.8 / 78.8 MB | 14.8 / 78.9 MB | vmmap phys_footprint / ps，RSS 含共享库 |
| **空闲 CPU** | 0.0% | 0.0% | 5 秒 top 采样，changeCount 轻量检测 + 500ms 低频轮询 |
| **冷启动** | ~640 ms | ~644 ms | 从 `open` 到进程出现；条目按需加载 |

两个观察：

- **空闲态内存与条目数基本解耦**：3,000 与 10,000 条下物理 footprint 同为 14.8 MB；全文与 FTS 索引仅保存在 SQLite，内存历史只持元数据。
- **本次脚本只采集空闲态**：弹窗展开与深滚的内存需通过交互式场景单独测量，未沿用旧数据。


### 搜索实测（10,000 条，6,000 文本）

| 查询 | 耗时 | 说明 |
|---|---|---|
| **FTS5 子串查询** | <1 ms（命中近全部行时 ~7.5 ms） | 命中量越大越慢；常见词条亚毫秒 |
| **LIKE 兜底（<3 字符）** | ~41 ms | 无法构成 trigram，退化为全表扫描 |

### Rust 内部基准（`cargo run --bin bench --features stress-test` 实测）

| 指标 | 成绩 | 说明 |
|---|---|---|
| **快照获取** | 0.23 – 3.79 µs | 100 → 10,000 条，读取不阻塞写入 |
| **计数开销** | ~6.9 ns | `.len()` 常数时间，不随条目数增长 |
| **图片编码** | 1.1 – 7.7 ms | 540p → 4K PNG，按需加载不驻留内存 |
| **图片解码** | 1.3 – 14.6 ms | 540p → 4K PNG |
| **缩略图** | ~0.1 ms | ≤300px CatmullRom 生成 + 编码 |


### 快捷键系统

两种机制确保在任何场景下都能唤出弹窗：

- **Carbon RegisterEventHotKey** — 系统级注册，应用在后台也生效
- **NSEvent global monitor** — 后备方案，覆盖 Carbon 的边缘情况

两者都需要 macOS「辅助功能权限」。首次运行时应用会自动引导授权；设置页可一键打开系统设置，或直接把应用图标拖入授权列表。

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
