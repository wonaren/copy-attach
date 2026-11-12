# 压力测试方案

目标：用真实路径、高频重复、故障注入和崩溃报告门禁，覆盖单元测试抓不到的问题（事件 tap 线程、撤销/恢复时序、UI 状态、更新链路）。所有结论以实测为准。

## 验收门槛

| 项 | 门槛 |
|---|---|
| 崩溃 | 测试窗口内 `~/Library/Logs/DiagnosticReports/CopyAttach-*.ips` 为 0（已归档的历史崩溃单独列出） |
| 数据 | 无丢失、无幽灵条目；`db_id`、收藏、槽位、撤销侧表无孤儿行；操作前后行数可对账 |
| 内存 | 空闲稳态在基线内（~36–44MB `Writable regions`）；长跑 8h 无单调增长 |
| 流畅 | 主线程卡顿 p99 < 100ms；弹窗呼出 < 200ms |
| 竞态 | 竞态套件全部 ≥20 轮、失败率 0；`cargo test` ×20 失败率 0 |
| 构建 | `check_push.sh` 全绿；`codesign --verify --deep --strict` 通过且 Authority 为正式身份 |

任何一项不过：不发布，先修。

## 执行约定（硬约束）

- 任何写库实测前先在线备份，并核对行数与当前库一致；测试结束必须换回并再次核对。
- GUI 一律使用真实 `HOME`；不启动第二个实例；不用覆盖的 `HOME` 启动 GUI。
- 数据隔离使用 `COPYATTACH_DATA_DIR=/tmp/copyattach-stress/...` 启动隔离实例：真实库只做备份、不被写入，测试库跑完即丢弃。
- 观测动作不得改变被测对象：不做轮询式建连、不额外起进程、不在测量时打开压力面板。
- 冷启动测量必须等待一次性元数据迁移完成（日志出现 `metadata migration complete`）后再开始；迁移期间的开合、缩略图、内存数字只作为「升级瞬时项」单独记录。实测未等迁移时缩略图 p95 345–640ms，迁移后 20.5–22.6ms。
- 失败必须留证据：命令、日志片段、崩溃报告路径、SQL 对账结果。
- 每个失败项转成永久回归用例，纳入下一轮 S0。

## 套件

### S0 回归门禁

- `cargo clippy --all-targets -- -D warnings`
- `cargo test` 连续 20 次，记录失败率
- `bash check_push.sh`
- 签名校验
- 扫描最近 24h 的 `CopyAttach-*.ips`

### S1 数据与持久化

- 现有 `stress_test.sh --quick` 与完整 10k；新增 50k 行混合数据集
- FTS 边界：1/2 字符查询、>512K 字符长文、纯符号/换行/emoji、同内容 1000 次去重
- 图片：200 张 5K 截图、50MB 图片、GIF/WebP/BMP/TIFF、0 字节/损坏 PNG
- 清理：阈值被收藏 + 快捷槽位占满、收藏数超过阈值、连续复制新内容
- 撤销：连续 500 次删除/撤销；五档预算（1 条 / 16MB / 64MB / 256MB / 不限制）；删除 → 重捕获 → 撤销；重启后撤销链仍在
- 备份：导出 → 清空 → 恢复；对账行数、hash、收藏、槽位、备注；损坏/截断备份文件
- 迁移：0.111.4 真实库副本、`user_version` 3 的库、含空 preview 的旧行
- 每步后断言：`db_id` 指向活行、侧表无孤儿、收藏/槽位无孤儿、去重后无重复内容

### S2 捕获链路

- `pbcopy` 高频灌入：10/50 次每秒，文本/图片/超大内容混合，持续 10 分钟
- 自写抑制：粘贴后监控线程不得二次捕获
- 忽略规则：bundle ID、类型、短文本阈值
- Phase 2 背压：连续 100 张图片，内存有界、最终全部落库且顺序正确
- 5K 截图 ×50、50MB 文本、系统级隐藏类型

### S3 UI 与交互

- 呼出/关闭 500 次；快速连按打断状态机；Esc 三层
- 双指滑动切标签 200 次；1 万条滚动；搜索 1/2/3/长文；日期吸顶
- 悬停气泡 200 次、大预览 100 次、缩放/长文选择
- 点击选中/回车、单击使用开关、备注编辑、右键菜单、另存为
- 删除 500 次 + 撤销 500 次（含「继续删除/取消」弹窗）
- 拖拽：单条、批量、空载荷；落点 TextEdit / VS Code 终端 / Finder；落点拒绝
- 粘贴队列：1/10/50 条；Esc 一次/连按；3 分钟看门狗；`clear/cancel`
- 快捷槽位：绑定/解绑、左/右 ⌘、Shift+⌘1..9、拨盘、录制模式、secure input 下启停
- 切换输入法/键盘布局时按槽位键（验证 TIS 监听）、外接键盘小键盘
- 更新 UI：进度、红点、完成小窗（mock 版本号）

### S4 并发与竞态

- 撤销进行中继续复制；粘贴中监控捕获；清理中生成快照；搜索中删除
- 弹窗关闭中按快捷键；队列派发中关闭弹窗；tap 重启用时粘贴
- 连续开合 + 后台捕获 + 预览解码同时进行
- 每项 ≥20 轮，记录失败率

### S5 内存与泄漏

- 检查点 `vmmap -summary`：启动空闲、开合 50 次、预览 100 次、撤销 500 次、备份恢复后
- 8 小时长会话，每 5 分钟一次脚本活动
- 判定：稳态不超基线 +8MB；任一段单调增长即失败并留档对比

### S6 故障注入

- 无辅助功能权限、secure input、睡眠/唤醒、多显示器不同 scale、时钟跳变
- 数据库：损坏页、只读、磁盘满（小型磁盘映像模拟，不碰真实盘）
- 更新链路：GitHub 不可达、蓝奏云不可达、下载中断、DMG 截断、篡改包、安装替换失败、重启失败
- 网络故障用本地代理注入，不改系统 hosts

### S7 长跑

- 8 小时：随机操作 + 定时灌剪贴板；每小时记录内存/CPU/线程数/句柄数
- 结束后统计崩溃报告数、日志 `error/panic/failed` 计数
- 通过：0 崩溃、内存无趋势性上涨、无 tap 反复 disabled

### S8 报告与归档

- 每个套件产出：命令、原始指标、失败项、复现步骤
- 失败项转成永久回归用例，纳入 S0

## 脚本

| 脚本 | 作用 |
|---|---|
| `scripts/stress/prepare.sh` | P0：检查构建/签名、备份真实库、准备隔离副本、记录基线 |
| `scripts/stress/data_suite.sh` | P1：真实库副本启动 + 数据集启动 + 弹窗开合 + 捕获风暴 + 不变量对账 + 崩溃扫描 |
| `scripts/stress/rust_suite.sh` | P1：真实路径批量删除/撤销/内存断言（Rust 测试二进制，隔离库） |
| `scripts/stress/ui_suite.sh` | P2：真实 GUI 搜索/收藏/删除/撤销/预览/队列（cua-driver，隔离实例） |
| `scripts/stress/race_suite.sh` | P3：捕获与开合交错、kill -9 恢复、真实路径测试重复 ≥20 次 |
| `scripts/stress/fault_suite.sh` | P4：只读库退避恢复、损坏库弹窗重建、RAM 盘写满恢复 |
| `scripts/stress/soak_suite.sh` | P5：8 小时长跑，每小时内存/线程/fd/不变量，定时重启持久化 |
| `scripts/stress/popup_cycles.sh` | 弹窗开合与内存检查点 |
| `scripts/stress/thumb_probe.sh` | 缩略图延迟 A/B（迁移前后） |
| `scripts/stress/invariants.py` | SQL 不变量检查（收藏/槽位/撤销侧表/去重/阈值/水位） |
| `scripts/stress/crash_scan.sh` | 指定时间窗口内的 `.ips` 崩溃报告扫描 |
| `scripts/stress/common.sh` | 隔离启动、备份、vmmap、日志等待等公共函数 |

```bash
bash scripts/stress/prepare.sh
bash scripts/stress/data_suite.sh                # 1000 条 + 200 次捕获 + 10 次开合
bash scripts/stress/data_suite.sh --full         # 10000 条数据集
bash scripts/stress/rust_suite.sh                # 真实路径批量删除/撤销/内存
bash scripts/stress/ui_suite.sh --rounds 5       # GUI 交互（需 cua-driver 与辅助功能授权）
bash scripts/stress/race_suite.sh                # 竞态：20 轮 + kill -9 + Rust 20 次
bash scripts/stress/fault_suite.sh               # 故障注入（--skip-disk 跳过 RAM 盘）
bash scripts/stress/soak_suite.sh --hours 8      # 8 小时长跑（期间真实实例保持退出）
```

执行期间会临时退出真实实例、启动隔离实例；脚本退出时恢复真实实例与原剪贴板文本。真实库只备份、不写入。

## 执行顺序

| 阶段 | 内容 | 时长 |
|---|---|---|
| P0 | 备份真实库、准备测试库、构建 normal + STRESS、准备 AX 驱动 | 30 min |
| P1 | S0 + S1 | 2–3 h |
| P2 | S3 + S2 | 3–4 h |
| P3 | S4（20 轮） | 2 h |
| P4 | S5 + S6 | 3 h |
| P5 | S7 长跑 | 8 h |
| P6 | S8 报告与门禁 | 1 h |

发版前最低门槛：P1 + P3。

## 本轮决定

- 长跑时长：8 小时
- 数据隔离：`COPYATTACH_DATA_DIR` 指向临时目录启动隔离实例；真实库只备份、不写入
- GUI 自动化：允许使用 cua-driver / 辅助功能驱动点击与按键
- 网络故障注入：本地代理模拟，不改系统 hosts
- 更新包签名校验尚未实现：本轮记为已知失败项，不阻塞其他套件
- 脚本落点：`scripts/stress/`，并扩展 `stress_test.sh` 的套件参数
