<p align="center">
  <img src="assets/icon.svg" alt="CopyAttach" width="96">
</p>

<h1 align="center">CopyAttach</h1>

<p align="center">
  <strong>做全网最轻量高效的剪贴板管理软件。</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Rust-1.75%2B-dea584?style=flat&logo=rust&logoColor=white" alt="Rust 1.75+">
  <img src="https://img.shields.io/badge/Swift-6%2B-f05138?style=flat&logo=swift&logoColor=white" alt="Swift 6+">
  <img src="https://img.shields.io/badge/macOS-15.0%2B-000000?style=flat&logo=apple&logoColor=white" alt="macOS 15.0+">
  <img src="https://img.shields.io/badge/license-Apache%202.0-3da639?style=flat" alt="License Apache 2.0">
</p>

---

CopyAttach 是一个 macOS 剪贴板管理器。它默默记录你复制的一切——文本、代码、链接、图片——然后通过一个快捷键让你在任何应用中快速搜索、预览、粘贴。从渲染帧率到磁盘写入，从内存分配到功耗管理，每个环节都经过精心优化，做到真正的无负担。


## 使用方式

| 操作 | 效果 |
|---|---|
| **⌥X** | 唤出 / 隐藏历史弹窗 |
| **↑  /  ↓** | 选择上 / 下一条 |
| **⏎** | 粘贴选中条目 |
| **␣** 空格 | 预览完整内容 |
| **⎋**  Esc | 关闭弹窗 / 预览 |
| **点击条目** | 直接粘贴 |

你可以自己在设置里改成顺手的快捷键。

## 核心设计原则

1. **不搞兜底**——主流程失败就暴露错误，不静默降级。你不会粘贴到错误的内容。
2. **不重复捕获**——粘贴时不会把自己刚写回的内容又读进来，形成死循环。
3. **不丢数据**——每条历史实时写入 SQLite，重启还在。
4. **不阻塞 UI**——读历史走无锁快照，Swift 随时拿到完整数据。

## 技术栈

- **Rust 后端**（`cdylib`）——剪贴板监控、去重、图片编解码、SQLite 持久化，经 C FFI 暴露给 Swift
- **Swift 6 前端**（AppKit/SwiftUI）——启用 Swift 6 严格并发（`@MainActor` 隔离 + `@Observable` 状态管理），无锁快照驱动渲染

## 无负担的设计

作为常驻菜单栏的工具，我们对每一毫秒、每一 KB 都斤斤计较：

| 维度 | 做法 | 效果 |
|---|---|---|
| **性能流畅** | 无锁快照 + 两阶段图片捕获 + CatmullRom 快速缩略图 | 列表滚动不掉帧，4K 截图不卡顿 |
| **内存克制** | 512KB SQLite page cache + 动态阈值裁剪 + 缩略图按需加载 | 常驻内存在几 MB 量级，从不膨胀 |
| **存储精简** | mmap 读写 + write-through 即时去重 + 自动淘汰 | 数据库始终控制在阈值内，零碎片增长 |
| **功耗节制** | changeCount 轻量检测 + 300ms 低频轮询 + 异步编码 | 安静时 CPU 占用近乎为零 |
| **交互高效** | ⌥X 一键唤出 + CJK 感知搜索 + 键盘直达粘贴 | 从唤起到粘贴，常在一秒内完成 |

## 压力测试

构建并运行完整压力测试流程（`STRESS=1 ./build.sh` + `bash stress_test.sh`），覆盖两种负载：

- **日常场景**：默认 3000 条上限满负载（1,800 文本 / 1,200 图片，DB 84.6 MB）——用户长期日常使用的实际规模
- **满压场景**：10,000 条（6,000 文本 / 4,000 图片，DB 282 MB）——验证极端负载上限

### 应用级指标对比（实机 vmmap / heap / ps / top 采集）

| 指标 | 3000 条（日常） | 10000 条（满压） | 说明 |
|---|---|---|---|
| **物理内存** | ~54 MB（峰值 54 MB） | 137 MB | vmmap 实测，App 独占 + 私有内存，稳态不增长 |
| **RSS** | ~145 MB（私有 53 MB） | 201 MB | 含共享库（SwiftUI/AppKit） |
| **堆内 malloc** | ~43 MB | — | heap 实测，条目全文 + 图片缩略图 |
| **空闲 CPU** | ~0.2% | 0.3% | changeCount 轻量检测 + 300ms 低频轮询，几乎零功耗 |
| **冷启动** | ~599 ms | 615 ms | 进程出现即就绪，冷启动后内存回落、条目按需加载 |

条目数 ×3.3，物理足迹仅 ×2.5、RSS 仅 ×1.4——**内存增长亚线性**，日常规模下内存、功耗、启动均更轻。

### Rust 内部基准（`cargo run --bin bench --features stress-test`）

| 指标 | 成绩 | 说明 |
|---|---|---|
| **快照获取** | 0.10 – 2.83 µs | Mutex lock + clone，100 → 10,000 条，读取不阻塞写入 |
| **计数开销** | ~6.8 ns | `.len()` 常数时间，不随条目数增长 |
| **搜索过滤** | ~150 µs | 10,000 条全文子串扫描（大小写不敏感），CJK 字符同速 |
| **缩略图生成** | ~0.1 ms | 540p → 4K 均 0.1ms 生成+编码（≤300px CatmullRom），解码同速 |
| **全图编码 / 解码** | 1.0 – 9.4 ms / 1.6 – 14.0 ms | 540p → 4K PNG，按需加载不驻留内存 |
| **DB 写入速率** | 829 条/秒 | 含 PNG 编码 + SQLite write-through，10,000 条用时 12.1s |
| **DB 文件体积** | 282 MB | 10,000 条（含 4,000 张截图），内部自动淘汰至阈值 |


### 快捷键系统

两种机制确保在任何场景下都能唤出弹窗：
- **Carbon RegisterEventHotKey** — 系统级注册，应用在后台也生效
- **NSEvent global monitor** — 后备方案，覆盖 Carbon 的边缘情况

两者都需要 macOS「辅助功能权限」。首次运行时应用会自动引导授权。

## 构建依赖

- macOS 15.0+（Sequoia）
- Xcode 16+（Swift 6 语言模式）
- Rust 1.75+

## 许可证

Apache 2.0
