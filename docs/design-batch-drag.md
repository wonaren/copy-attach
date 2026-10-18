# 设计提案：批量拖拽（一次拖出，多条落位）

> 状态：**设计稿，未实现**。文中每一条「已验证」都必须在真实调用路径上观察到才算数；未标注的一律视为假设。

## 1. 目标与非目标

**目标**：用户在弹窗里标记若干条记录，一次拖拽把它们送进目标应用，得到 N 条**按顺序**落位的内容，全程不切窗口、不逐条操作。

**非目标（v1 明确不做）**
- 跨应用「批量搬运文件到 Finder 的某个文件夹」的专门优化（复用同一机制即可，不做额外分支）。
- 拖拽过程中实时预览批次清单、拖拽中动态改序。
- 无辅助功能权限下的自动多贴（降级为只送首条并明示）。

## 2. 结论先行：三个决策

| # | 决策 | 理由 | 验证状态 |
|---|---|---|---|
| D1 | **选择模型复用「粘贴队列」**，不新增多选体系 | 队列已经是「有序 + 序号徽标 + 会话级生命周期」的多选单一真相源；新增一套 ⌘-click 选择会与队列徽标、底栏文案、排序语义三处冲突 | 队列行为已实现；「拖动队列中任一行 = 拖整组」是行为变更 |
| D2 | **传输 = 1 条原生投递 + N-1 条合成 ⌘V 派发** | 多 pasteboard item 的文本投递在各落点是否全收**未知**，而「只收第一条」是**静默丢失**；派发的失败可观测、可控速 | 多 item 能力：**未验证**（Phase 0 必测） |
| D3 | **不改拖拽传输层**：保留 SwiftUI `.onDrag`，用「落点几何 + 队列」驱动派发 | `.onDrag` 是这套代码里被反复踩坑后唯一验证过的传输（UTI 风味矩阵见 `docs/engineering-notes.md`「原生拖拽」）。换 `NSDraggingSession` 等于重做那份矩阵 | 落点解析与派发均为新代码，需 Phase 0/2 验证 |

D2 的替代方案（`payload = N items`，零合成击键）保留为 Phase 0 的实测分支：若 6 个落点里有 ≥5 个能一次收下 N 条文本，则它严格优于 D2（原子、无权限依赖、无时序竞态）。**在测出来之前不采用**。

## 3. 现状事实（改动必须贴着这些走）

| 事实 | 位置 |
|---|---|
| 单条拖拽 = 每行一个 `.onDrag`，返回 `NSItemProvider`；图片落成临时 PNG 文件 URL | `SwiftApp/Popup/HistoryPopupContent.swift:985`、`ClipboardDragProvider.swift:33` |
| 拖拽板上文本只广播 `utf8PlainText / plainText / text`，富文本按「唤起弹窗前的 App」逐次开启 | 同上 + `ClipboardBackend.swift:490` |
| 拖拽在途弹窗智能停车；松手检测靠 40ms 轮询 `NSEvent.pressedMouseButtons`（事件跟踪模式下 monitor 收不到 mouse-up） | `HistoryPopupWindow.swift:419-447`、`+DragParking.swift` |
| 拖到别的 App → `didResignKey` 里直接 `close()`（与 Esc 同路径）；「连续拖拽」开时才保留弹窗 | `HistoryPopupWindow.swift:387-417` |
| 队列：`⌘C` 切换成员，顺序 = 按下顺序，`orderMap` 派生徽标；进入弹窗时若队列非空会被清空 | `PopupHostingView.swift:366/464`、`PasteQueueManager.swift:85`、`HistoryPopupContent.swift:439` |
| 粘贴两阶段：`prepare_paste_by_id` 写板 + 置顶 + 返回 pid（**写板前先查辅助功能权限**），`send_paste(pid)` 发 ⌘V；`send_paste` 接受任意 pid | `src/ffi/paste.rs:129/384/406`、`ClipboardBackend.swift:860` |
| 自写抑制：`prepare` 设 `pending_self_write`，监控线程按 changeCount 跳过自家写入 | `prepare_paste_impl` / `monitor.rs` |
| 底栏已有「已选 N 项 · ⏎ 开始顺序粘贴 · ⎋ 清空」形态可复用 | `HistoryPopupContent.swift:1096` |

**由此推出的两个硬约束**

1. **派发必须在弹窗不再是 key window 之后**。`prepare` 的注释记录了实测：panel 仍为 key 时 WeChat 会间歇丢掉短文本粘贴。所以批量拖拽**不尊重「连续拖拽」开关**——只要进入派发就强制关闭弹窗（这是行为差异，要写进 README/CHANGELOG）。
2. **派发的 ⌘V 只能投给「用户实际落点所在的那个 App」**，不能沿用 `source_app.pid`（那是唤起弹窗前的 App，可能与落点不同）。

## 4. 交互设计

### 4.1 标记（复用队列，零新手势）

```
弹窗列表
 ├─ ⌘C            → 该行入队 / 出队（既有）
 ├─ 队列 1 项      → 拖该行 = 单条拖拽（与今天完全一致，零回归）
 └─ 队列 ≥2 项     → 拖动任意「在队」的行 = 拖整组
                     拖动「不在队」的行 = 仍只拖该行（今天的行为）
```

底栏文案调整：
- 队列为空：普通底栏补一条 `⌘C 批量`（现在底栏没有 ⌘C 提示，这是既有发现性问题）。
- 队列 1 项：`已选 1 项 · 继续按 ⌘C 标记 · ⏎ 顺序粘贴 · 拖拽发送`。
- 队列 ≥2 项：`已选 N 项 · 拖拽到目标应用一次落位 · ⏎ 手动节奏 · ⎋ 清空`。

### 4.2 拖拽中

- 拖影：首条的常规行快照 + 右下角胶囊 `N 条`（单条时无胶囊）。**整组只承载 1 个 pasteboard item**，所以拖影必须是一张合成位图（多 `NSDraggingItem` 会同时写出多个 pasteboard item，与 D2 冲突）。
- 落点停车、松手关闭全部沿用现状，不新增动画。

### 4.3 落位（派发）

```
松手 / 弹窗失焦
   ↓  取落点（NSEvent.mouseLocation）
   ↓  解析落点窗口 → ownerPID（非本进程）
   ↓  校验：该 pid 是 frontmost？  ── 否 → 中止，HUD 明示「目标未激活，仅送达首条」
   ↓  关闭弹窗（强制，忽略「连续拖拽」）
   ↓  settle 250ms（等目标把首条真正插进去）
   ↓  for i in 2..N:  prepare(i) → send_paste(pid) → 150ms
   ↓  HUD：3/5 → 完成 / 中断点
```

HUD 复用队列胶囊的视觉（`PasteQueueHUDView` 的排版），但**独立窗口与独立模型**——队列 HUD 绑在 `PasteQueueManager.status` 上，混用会让「顺序粘贴」与「批量投递」两种状态互相污染。

### 4.4 收尾

- 全部送达：清空队列（意图已兑现），HUD 900ms 后消失。
- 中途失败：**不清空**，HUD 显示「已送达 k/N · 其余未发送」并保留队列供重试；日志 `batch.dispatch_aborted reason=...`。
- 落点被拒（拖到桌面空白、拖回自己）：什么都不做，队列保持原样。
- Esc / 再次唤起弹窗 / 目标进程消失：立即中止剩余项。

## 5. 数据模型与不变量

- **选择 = `PasteQueueManager.queueItems`**（有序数组，顺序即索引）。不新增第二个「选择」状态。
- 派发任务的输入是**快照**：`[(entryId, index)]` + `targetPID` + `startedAt`。派发开始后不再读队列，避免用户在 HUD 期间改动队列导致语义漂移。
- 不变量 I1：`payload` 永远只含 1 条 = `queueItems[0]`；派发只处理 `1..<N`。
- 不变量 I2：任何一次 `send_paste` 之前的 `prepare` 必须先成功；`prepare == 0` → 停止整批（权限/DB/条目失效都会让它返回 0）。
- 不变量 I3：派发期间弹窗必须已 close（见 §3 硬约束 1）。
- 不变量 I4：派发目标 pid 在整批内固定不变；pid 失活（`send_paste == 0`）即中止，不换目标重试。
- 不变量 I5：N == 1 时派发循环为空，**行为与今天逐字节一致**（这是 Phase 1 的验收线）。

## 6. 模块与改动清单

| 文件 | 改动 | 性质 |
|---|---|---|
| `Popup/ClipboardDragProvider.swift` | 抽出 `representations(for:richText:) -> [(uti, Data)]`；`provider(for:)` 与其新调用方共用（风味单一真相源） | 重构，行为不变 |
| `Popup/BatchDragController.swift`（新） | 判断本次拖动是否整组；生成拖影位图；记录拖拽起始状态；落点解析；触发派发 | 新增 ~180 行 |
| `Popup/BatchDropper.swift`（新） | 落点 → pid 解析（`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 前到后第一个包含落点、owner≠自身的窗口）+ frontmost 校验 | 新增 ~60 行 |
| `Queue/BatchDispenseRunner.swift`（新） | 定速派发状态机（MainActor Task）、取消、进度回调 | 新增 ~120 行 |
| `Queue/BatchHUDWindow.swift` + View（新，复用视觉） | 进度胶囊 | 新增 |
| `Popup/HistoryPopupContent.swift:985` | `.onDrag` 内分流：在队且 N≥2 → 整组；否则原路径 | 小改 |
| `Popup/HistoryPopupWindow.swift:387-475` | 拖拽结束时通知 `BatchDragController`（`didResignKey` 与 `completeItemDrag` 两条出口都要），批量时强制 close | 小改，注意别改变单条路径的时序 |
| `ClipboardBackend.swift:860` | `pasteEntryById` 增加 `targetPID: Int32?`（nil = 今天的行为）；有值时 `send_paste(targetPID)` | 参数化，无分支扩散 |
| `PasteQueueManager.swift` | `orderedSnapshot()`、`batchDidComplete()`（清空/保留）；不改 `status` 语义 | 小改 |
| `HistoryPopupContent.swift:1096` 底栏 | 队列文案增加「拖拽发送」 | UI |

**FFI 零改动**：`clipboard_send_paste(pid)` 本来就接受任意 pid；`clipboard_prepare_paste_by_id` 的返回值在批量路径里只作为「成功/失败」用，pid 用我们自己解析的。这是刻意的——不动 66 个 `extern "C"` 中的任何一个，就没有三处同步的负担。

**落点解析的两个坐标陷阱**（先写进设计，避免实现时返工）：
- `NSEvent.mouseLocation` 与 `NSScreen` 是 Cocoa 全局坐标（主屏**左下**为原点）；`CGWindowListCopyWindowInfo` 的 `kCGWindowBounds` 是 CG 全局坐标（主屏**左上**为原点，副屏可为负）。翻转公式 `cgY = NSScreen.screens[0].frame.height - cocoaY`。
- `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` 返回的是**前到后**的 z 序；「第一个包含落点且 owner ≠ 本进程」就是接收这次 drop 的窗口。不要按 layer 过滤（浮层/工具窗也可能接收 drop，过滤等于替系统猜）。

## 7. 失败模式（全部显式，不兜底）

| 情况 | 表现 | 处理 |
|---|---|---|
| 无辅助功能权限 | `prepare` 返回 0 | 只送达首条；HUD「批量粘贴需要辅助功能权限」；队列保留 |
| 落点无窗口 / 落回自己 | 无 pid | 不派发，队列不动（用户视为取消） |
| 落点窗口的 App 不是 frontmost | 可能贴进它的另一个窗口 | 中止剩余项并明示，不猜测 |
| 落点 App 拒绝该拖拽风味 | 首条没有落进去 | 剩余 N-1 条仍按落点投递（落点是用户的意图），日志记录 |
| 派发中途某条失效 | `prepare == 0` | 停止整批（不跳过继续，避免「跳过一条后顺序错位 + 用户不知道少了哪条」） |
| 目标进程退出 | `send_paste == 0` | 中止，HUD「目标应用已退出」 |
| 用户在派发中做别的事 | — | 总时长 = N×150ms，有界；Esc/唤起弹窗即取消 |

> 「跳过继续」与「停止整批」的选择：队列路径选了「跳过并前进」，因为**用户手动按 ⌘V 的节奏里跳过是可解释的**；批量是一次性自动动作，跳过会让用户失去「落进去的到底是哪几条」的对应关系，所以停止更诚实。

## 8. 验证计划（每一关都有观测手段）

**观测手段先自证**：所有日志走既有 `/tmp/copyattach_debug.log`，先打一条已知为真的样本（如单条拖拽 `drag.session_start` / `drag.ended point=… pid=…`），确认采样点能看到拖拽，再采信它给出的「没有」。

| 关卡 | 内容 | 通过标准 |
|---|---|---|
| G0 | 落点观测自证 | 在 6 个落点各拖一次单条，日志里的 `point` 与 `pid` 与肉眼落点一致 6/6 |
| G1 | **传输零回归**（Phase 1 的唯一目的） | 队列为空时单条拖拽在 6 落点（TextEdit / 备忘录 / VS Code / Chrome 输入框 / 微信 / 访达）行为与改动前构建**逐项相同**：文本落位、图片落成文件、思源/Typora 富文本风味仍生效 |
| G2 | 多 item 能力（决定 D2 是否反转） | 探针构造 3 个 pasteboard item 的文本拖拽，逐落点记录「实际插入几条」；≥5/6 收全 N 条 → 改用 payload=N 的方案 |
| G3 | 顺序正确性 | 5 条编号文本批量拖入编辑器，连跑 **10 次**，10/10 顺序为 1..5；有一次失败即视为未通过（时序类问题不许单次下结论） |
| G4 | 权限缺失 | 撤销辅助功能权限后批量拖拽：剪贴板只被首条写入、HUD 明示、队列保留 |
| G5 | 目标失活 | 派发中途 `kill` 目标进程：HUD 报中断点，无障碍残留，无 ⌘V 泄漏到别的 App |
| G6 | 落点 app 非 frontmost | 拖到后台窗口：中止剩余项并明示（不贴错窗口） |
| G7 | 取消 | 派发中按 Esc / 唤起弹窗：剩余项不再发送，队列状态可预期 |
| G8 | 20 条上限批量 | 总时长 ≈ 20×150ms，弹窗关闭期间无可感知卡顿（看 `perf` 门的既有基线，不引入新的主线程长任务） |
| G9 | 内存 | 连续 50 次批量拖拽后 `vmmap -summary` 的 `Writable regions` 无单调增长（临时 PNG 由既有 `clipboard_purge_stale_drag_images` 收敛） |

## 9. 风险与开放问题

1. **`.onDrag` 拿不到「落点被接受」的权威信号**——这是 D3 的代价。缓解：不依赖「被接受」，只依赖「落点在哪个窗口」，并在 G0/G3 里证明这足以得到正确行为。若 G3 出现「首条没落进去、后几条却贴了」的错位，升级为备选 D3'：自建 `NSDraggingSource`（`draggingSession(_:endedAt:operation:)` 给出 `operation` 与落点，权威但要把风味矩阵在 6 个落点上整份重验）。
2. **settle 250ms 是猜的**。G3 里要扫一遍 150/250/400ms，选出「10/10 正确」的最小值；不同落点（Electron 的 IPC 提交更晚）可能要取更大值。必要时按 pid 的 bundleID 做已知慢应用的单独节奏——但那属于数据驱动的例外表，需实测支持，不凭猜。
3. **历史置顶副作用**：每条 `prepare` 都会把该条移到历史顶部，一批 5 条会把历史顺序搅成 5,4,3,2,1。是否在批量路径上抑制置顶需要 Rust 侧加参数（FFI 变更）。v1 先接受并写进文档，等有真实抱怨再评估。
4. **队列被复用为选择集合**，会改变「队列非空时拖单条」的既有行为（现在是拖该条，改后是拖整组）。这是功能本体，但要在 CHANGELOG 里说清楚。
5. **入口发现性**：目前底栏没有 ⌘C 提示，批量拖拽完全依赖用户已知队列。v1 必须补底栏提示，否则功能等于隐藏。
6. 摘要文案的中文口径：「批量投递」/「拖拽发送」二选一，需与 README 现有措辞（「原生拖拽智能避让」）统一。

## 10. 任务拆解与工期

| 阶段 | 内容 | 出口 | 估时 |
|---|---|---|---|
| P0 探针 | G0 + G2 + settle 扫描；只写临时探针与日志，不碰产品代码 | 三个数字：落点解析命中率、多 item 收入率、最小 settle | 0.5–1 天 |
| P1 传输与原语 | `representations` 抽取、`targetPID` 参数化、`BatchDropper`、日志 | G0 通过、G1 通过（单条零回归） | 1 天 |
| P2 选择与拖拽 | 队列整组判定、合成拖影、`didResignKey`/mouse-up 双出口、强制关窗 | 队列 ≥2 时拖出「1 条 payload + 计划 N-1」可见于日志 | 1 天 |
| P3 派发 | `BatchDispenseRunner` + HUD + 取消 + 失败文案 | G3–G8 | 1.5 天 |
| P4 收口 | 底栏文案、README/CHANGELOG、G9、`check_push.sh` | 全关卡通过 | 0.5 天 |

合计 **4.5–5 个工作日**（含探针）。版本号：按仓库约定只动 patch 位（`0.108.3` → `0.108.4`），若需要 minor 递增由你拍板。

## 11. 为什么不是另外两种设计

- **把整组拼成一段文本（join）再拖**：原子、零权限、零时序——但语义从「N 条」变成「1 段」，粘贴顺序之外还多了分隔符约定，且图片无法参与。作为将来「合并粘贴」的独立模式更合适，不是本功能的默认。
- **自建多选（⌘-click / ⇧-click）**：交互上更接近 Finder，但它与队列形成两套「选中的若干条」，序号徽标、底栏文案、Esc 层级、排序语义都要各解释一遍；同一个集合两种表达，用户迟早要问「我按 ⌘C 标的和 ⌘-click 标的有什么区别」。复用队列把这四类问题一次性消掉。

## 12. 实现结果（v0.108.4，已落地）

落地版本与提案的两处**实质偏差**，都是实测逼出来的，不是偏好：

| 提案 | 落地 | 实测原因 |
|---|---|---|
| 载荷 = 首条（文本/图片都原生投递），其余 N-1 条派发 | **载荷 = 空占位，N 条全部派发** | 接收方会**选中** drop 刚插入的内容：TextEdit 收到 9 字节文本后 AX 选区 `loc=0 len=9`，紧随的 ⌘V 把它替换掉（首条从结果里消失）；图片同理，一次拖两张 PNG 最终只剩 1 个附件（实测 `attachment count = 1`）。空占位不留选区，全部条目走同一条路，顺序由队列决定 |
| 落点解析 = `AXUIElementCopyElementAtPosition` | **前台应用 + 窗口几何校验** | AX 命中在 SwiftUI opaque list 上返回 `-25208`，且落点压在自家弹窗上会解析到**背后**的应用；`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 会列出其他 Space 的窗口（四个全屏应用同 bounds），z 序取第一个会指向看不见的应用 |

派发实现为 `Popup/BatchDrag.swift`（落点解析 + 控制器 + 拖影）+ `Queue/BatchDispenseRunner.swift`（定速派发，settle 250 ms / 间隔 150 ms）+ `Queue/BatchDispenseHUD.swift`（进度胶囊）。队列增加 `isQueued` / `removeDelivered`；`pasteEntryById` 增加 `targetPID` / `refreshAfter` 两个可选参数；**FFI 零改动**。

已验证（真实路径，合成输入驱动真实拖拽，非替身）：

| 关卡 | 结果 |
|---|---|
| G1 单条零回归（队列为空时拖动一行） | 文本与图片行为与改动前一致；`PARITY-SINGLE` 落在 TextEdit 文档里 |
| G3 顺序正确性（3 条，连跑 10 次） | **10/10** 与队列徽标顺序完全一致，`sent=3/3 notice=none` |
| 第二落点（备忘录） | 3/3 顺序落位；同一机制在非 TextEdit 目标上成立 |
| 图片批量（2 张 PNG） | 2/2，文档内 `attachment count = 2` |
| G5 目标进程中途退出 | `simulate_cmd_v: target PID … no longer running` → `finished sent=2/3 notice=第 3 条未送达`，队列保留 1 条可重试（`batch removed 2 delivered items, remaining=1`） |
| G7 取消（派发中唤出弹窗） | `togglePopup: cancelling the in-flight batch dispatch` → `sent=2/3 notice=已取消` |
| HUD | 派发中窗口列表可见 296×64 胶囊（顶部居中），结束后自淡出 |
| 已送达即出队 | 全送达 `remaining=0`；中断只移除已送达条目，重试不重复 |

**未实测（不要在文档/Release 里宣称）**：
- 辅助功能权限被撤销时的降级（需要用户到系统设置里改授权，未动）；
- 思源笔记 / Typora 的富文本风味（本机未安装这两个应用）；
- 拖到桌面空白 / 后台非前台窗口 ⇒ 按设计不派发、队列不动，但只做了代码路径审查，未在真实落点上复现；
- 队列 > 3 条的长批次（机制是循环，未做长批次计时）。

