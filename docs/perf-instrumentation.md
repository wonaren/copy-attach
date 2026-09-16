# CopyAttach 性能仪表（Perf Instrumentation）

面向「流畅度」的可验证测量系统。目标不是「感觉更快」，而是**让每一次延迟都能被测量、被反驳、被回归**。

---

## 1. 设计约束（为什么是这样）

一套测量系统若自身不被验证，它给出的数字就只是另一种猜测。因此本仪表遵循五条硬约束：

1. **默认关闭，开启前对被测路径零影响。** Rust 侧一次 relaxed atomic load，Swift 侧一次 atomic 检查；关闭时分配与写入均为零。**已实测**：关闭态 `PerfSpan.start` 0 ns/次（G8 门禁）。
2. **观测不改被测。** 仪表只向既有 debug 日志追加行，不阻塞、不持有、不重排任何 UI 工作。不用「每 N 毫秒新建连接去探询」这类副作用式采样。
3. **单一观测通道。** Rust 与 Swift 写同一个文件 `/tmp/copyattach_debug.log`，每行以 magic token `__CA_PERF__` 开头。收集器只 grep 这个 token，不受诊断日志噪声影响。
4. **记录自描述。** 每行携带 pid、`pthread_self()` 线程 id、单调时钟 ns、墙钟 ms、category/name；完成型 span 带 `dur_us`。分析器不需要读源码即可重建一条延迟链。
5. **记录里没有剪贴板内容。** 上下文只写数值或经 `sanitize_token` 处理的短 token（`[A-Za-z0-9._-]`，≤48 字节）。

### 时钟约定（关键）

Swift 用 `DispatchTime.now().uptimeNanoseconds`，Rust 用 `mach_absolute_time` 按 timebase 换算——**两者是同一个单调时钟、同一原点**。这一点很关键：Rust 进程内的 `Instant::elapsed()` 是进程相对量，与 Swift 的绝对 uptime 不同原点，直接相减会得到无意义的跨语言时长。自检里有一条专门的**跨语言时钟对齐**门禁（G6）：Swift 打点后紧跟 Rust 打点，实测偏差约 60–210 µs（同一次调用内），因此两条记录可安全排序相减。

---

## 2. 记录格式

```
__CA_PERF__ v=1 pid=<u32> tid=<hex> t=<mono_ns> wall=<unix_ms> kind=<b|e|i|c> cat=<cat> name=<name> [dur_us=<u64>] [val=<i64>] [src=<id>] [scen=<id>] [data=<token>]
```

| 字段 | 含义 |
|---|---|
| `v` | 格式版本，当前 `1`；分析器拒绝未知版本 |
| `pid` | 进程 id（用于把一次启动的记录聚成一个会话） |
| `tid` | `pthread_self()` 十六进制；**Swift 与 Rust 同值**，用于跨 FFI 归因 |
| `t` | 单调时钟 ns（见上）；只用于同 pid 内相减 |
| `wall` | Unix 毫秒；用于切分测量窗口 |
| `kind` | `e`=完成型 span（带 dur_us）、`i`=瞬时标记、`c`=计数采样、`b`=开始（预留） |
| `cat` | `rust` / `swift` / `probe` / `perfcheck` |
| `name` | span 或标记名（见 `4） |
| `dur_us` | 微秒 |
| `val` | 数值上下文（行数、字节数、结果数等） |
| `src`/`scen` | 关联用的稳定 id（预留） |

---

## 3. 如何开关

| 方式 | 适用 | 说明 |
|---|---|---|
| `defaults write com.example.copyattach PerfTracing -bool true` | **推荐** | 持久化偏好；`open` 启动的 app 也能读到（`open` 不继承 shell 环境变量） |
| `COPYATTACH_PERF=1 <binary>` | 直接运行二进制 | 注意：从受限启动器启动会被沙箱限制，且 app 需要写 `~/Library/Application Support/CopyAttach` |
| `clipboard_set_perf_enabled(1)` | 运行中 | FFI，可选 |

关闭：`defaults write com.example.copyattach PerfTracing -bool false`（或删除该 key）。

---

## 4. 已埋点的路径与含义

### Swift

| name | 覆盖的真实路径 |
|---|---|
| `popup.show` / `popup.show_begin` / `popup.content_appear` | 窗口 orderFront → key → 淡入启动；`content_appear` 是 SwiftUI 挂载内容的同步代理 |
| `popup.visible_setup` | `setPopupVisible(true)` 的同步开销（含首个 `refresh()`） |
| `popup.reload` | 请求刷新 → 新列表在主线程发布 |
| `snapshot.decode` | packed buffer → `[ClipboardItem]` |
| `search.end_to_end` / `search.filter` | 按键 → 结果上屏（含 debounce）；detached 过滤本身 |
| `thumb.decode_total` / `thumb.queue_wait` / `thumb.ffi_read` / `thumb.imageio` | 行缩略图：总耗时拆成「等 4 槽信号量 + 取 blob + ImageIO 重采样」 |
| `preview.open` / `preview.load_full_text` | 预览窗口建立；主线程同步读全文（预览的 suspect 点） |
| `paste.menu_to_keystroke` | 菜单动作 → 剪贴板就绪 → 关弹窗 → 发出 ⌘V |
| `drag.materialize` | `.onDrag` 闭包里同步读全文/整图并物化临时文件 |
| `undo.perform` | 撤销删除（主线程同步 DB 读 + 插入） |
| `popup.close` | 关闭路径 |
| `nav.input` / `nav.applied` | 方向键输入 → 选中态应用（配合算 chain） |
| `capture.ui_observed` | UI 刷新首次观测到变化 |
| `thumb.cache_hit` / `thumb.cache_miss` | 缩略图缓存计数 |

### Rust

| name | 覆盖的真实路径 |
|---|---|
| `snapshot.pack` | `clipboard_snapshot_packed_acquire` 序列化全部行 |
| `search.query` | `clipboard_search_ids` 的 FTS/LIKE 查询（`data` 区分） |
| `thumb.load_db` | 缩略图 blob 的 SQLite 读取 |
| `db.write` | `persist_entry_to_db` 单事务写穿（捕获/粘贴/撤销共用） |
| `paste.prepare` / `paste.load_text` / `paste.load_image_blobs` / `paste.write_temp_png` | 两阶段粘贴的准备阶段及其子阶段 |
| `preview.decode` | 预览大图解码 |
| `image.thumbnail_phase1` / `image.encode_png` | 捕获 Phase 1 缩略图；Phase 2 PNG 编码 |
| `capture.text` / `capture.image_phase1` | 捕获落地的瞬时标记（与 `capture.ui_observed` 配对） |

---

## 5. 运行一次测量

```bash
# 1. 打开 tracing 并启动
defaults write com.example.copyattach PerfTracing -bool true
open ./CopyAttach.app

# 2. 记录会话窗口起点
START=$(python3 -c 'import time;print(int(time.time()*1000))')

# 3. 在真实使用中操作（外部事件驱动，不做合成注入）
#    搜索、方向键、预览、拖拽、粘贴等需要在真实键盘/触控板下操作

# 4. 分析该窗口
python3 perf/analyze.py /tmp/copyattach_debug.log --session-start "$START"

# 或：严格模式（任一门禁失败返回码 2）
python3 perf/analyze.py /tmp/copyattach_debug.log --session-start "$START" --json report.json
```

辅助脚本 `perf/collect.sh`：

```
perf/collect.sh launch     # 停止旧实例并用 COPYATTACH_PERF=1 启动，等到「新 pid」的自检通过
perf/collect.sh quit
perf/collect.sh smoke N    # 通过 open（真实 reopen 路径）开合弹窗 N 次
perf/collect.sh begin      # 打印会话起点 wall-ms
perf/collect.sh analyze <start_ms>
```

> 注意：直接启动二进制写 `~/Library/Application Support/CopyAttach`，在受限沙箱下会失败（报 `readonly database`）。优先用 `open` + `PerfTracing` 偏好。**绝不要覆盖 HOME**（钥匙串会坏）。

---

## 6. 门禁（"仪器是否有效"的证明）

分析器在给出任何延迟数字之前，先跑 9 条门禁；任一条 FAIL 则整份报告判 **INVALID** 并以返回码 2 退出（`--no-strict` 可只看数字）。

| 门禁 | 证明什么 |
|---|---|
| G1 selfcheck | 启动自检通过（Swift 15 + Rust 7 + 通道 + 时钟对齐） |
| G2 channel | Swift 与 Rust 的探针都真的落到文件里 |
| G3 overhead_bounded | 每次启动的无条件记录数有界 |
| G4 clock | 单调时钟 `t` 与墙钟 `wall` 斜率≈1、R²≥0.99 |
| G5 / G5b parse | 每行都能按声明版本解析，无畸形 |
| G6 clock_alignment | Rust 与 Swift 打点共享同一时钟域（差值在容差内） |
| G7 format_cost | 开启态「格式化一条记录」的 CPU 成本有界（实测 ~350 ns） |
| G8 disabled_inert | 关闭态热路径成本有界（实测 **0 ns/call**） |

**自检自身也测过**：G6 的第一版把纳秒与微秒混用，被自检当场判 FAIL（`clk0_skew61us`），改为正确单位后 PASS。这正是门禁存在的意义——仪器先自证，再量别人。

---

## 7. 当前基线（已实测，全部门禁 VALID）

数据来自一次真实操作会话（真实剪贴板捕获 + 6 次弹窗开合 + 实时捕获），release 构建，130 条记录，0 畸形。

### 启动与弹窗

| 指标 | p50 | p95 | 判读 |
|---|---|---|---|
| `rust/snapshot.pack`（~950 行） | ~120 µs | ~170 µs | Rust 侧不是瓶颈 |
| `swift/snapshot.decode` | ~16.2 ms | ~18.5 ms | **比 Rust 序列化慢约 130×** |
| `popup.reload`（请求→发布） | ~17.5 ms | ~90 ms | |
| `open->content_appear` | ~36.8 ms | ~84.5 ms | 热键→内容挂载 |

### 捕获（复制内容 → 列表出现）

| 指标 | p50 | p95 |
|---|---|---|
| `capture->ui_observed` | 135 ms | **522 ms** |
| 其中后端捕获→内存落库 (`rust/db.write`) | 0.6 ms p50 / 1.2 ms p95 | |

- **高置信结论**：UI 刷新由定时器驱动，而非变化驱动。Rust 侧捕获与写库合计不到 1 ms，但 UI 平均 **135 ms、p95 522 ms** 才知道——这正是此前「500 ms 轮询是即时感上限」的实测证据。

### 缩略图（一次会话）

`thumb.decode_total` p50 27 ms、p95 47 ms。其中 `ffi_read` ~0.2 ms、`imageio` ~0.6 ms——**真正的时间花在等 4 个解码槽的信号量上**，不是解码本身。

### 已复现的真实问题（附带）

- **收尾窗口列表为空**：每次历史行数变化都触发全量 `snapshot.pack`（~248 KB）。数据在更新。
- **重启后来源应用显示为 Unknown**：新进程启动日志显示 `frontmostApplication` 早于首次 `updateSourceApp()` 就绪，来源名为 "Unknown"。数据在更新。

### 尚未测定（NOT MEASURED，不做推测）

搜索、方向键、预览、拖拽、粘贴这几条需要真实输入事件；本环境中 System Events 无辅助功能授权，无法合成，**因此不给出数字**。埋点已在位，在真实键盘/触控板下操作即可纳入报告。

---

## 8. 数据可达性与局限

- `first_data_us` 只在「打开时列表为空」时才有意义（已修正语义：列表已有缓存则直接视为可用）。
- 采样步长约等于 `POLL_INTERVAL_MS`（500 ms），是 1 Hz 采样；短于该间隔的连续捕获会合并，故 `capture->ui_observed` 的样本量小于捕获数。
- 分析器只对「同 pid」的 `t` 相减；跨进程不做时间换算。
- 高负载下关闭态计时可能取整为 0 ns（编译器与 CPU 都会把它压到极限），这本身就是「关闭态惰性」的证据，不是缺失数据。

---

## 9. 增量演进规则

- 新增埋点用 `PerfSpan.start(cat, name)`，`end()` 或让它 `deinit` 收尾（幂等，不会丢时长）。
- Swift 跨 `Task`/`DispatchQueue` 捕获 span 是安全的（`PerfSpan` 标注 `@unchecked Sendable`，同一 span 只会被单一顺序流触碰）。
- 名字保持稳定小写点分；`data` 只放枚举化 token，**绝不放入剪贴板正文**。
- 不新增控制流分支以适配仪表；仪表只做旁路观测。
