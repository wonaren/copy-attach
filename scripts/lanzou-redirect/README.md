# 蓝奏云稳定跳转入口 (lanzou-redirect)

## 解决什么问题

蓝奏云会不定期轮换对外域名（`pan.lanzoub.com` / `wwbvw.lanzouv.com` / `wwv.lanzouw.com` …）。
任何写死的域名迟早 NXDOMAIN，于是官网、Release 说明里的下载链接会随域名一起失效。

本服务对外暴露一个**永久不变**的地址：

    https://dl.abovepast.shop/lanzou

每次请求时在候选域名池里实测哪一个能真正打开当前分享页，再 302 过去。
分享 ID 与域名池只存在于 `redirect.py`，蓝奏换域名时**运维无需改动官网 / Release / App**。

## 对外契约

| 请求 | 行为 |
|---|---|
| `GET /lanzou` | `302 Location: https://<healthy-domain>/<SHARE_ID>` |
| `HEAD /lanzou` | 同上（无响应体） |
| `GET /healthz` | `200` JSON：`{domain, healthy, checked_at, share_id}` |

## 实现要点

- **有效性判据**：分享页存活时内联脚本引用 `/savep.php`；域名解析失败或分享被删时页面仅 ~1KB 且不含该串。两种失效都能识别，不依赖玄学。
- **探测节流**：选中域名缓存 5 分钟（`PROBE_TTL`）；全池失败时 30 秒后重试（`RETRY_TTL`）。`refresh()` 用锁串行化，并发请求不会一起打满域名池。
- **探测视角**：由分发服务器（与用户同为国内网络）发起，比在 CI/海外探测更接近真实可用性。

## 部署与自愈

```bash
# 首次安装 / 更新代码后（幂等）
bash install.sh

# 自检 + 崩溃自动拉起（crontab 每 10 分钟）
bash check.sh
```

服务器上的持久化由 crontab 承担（`install.sh` 不写 crontab，需手动加一次）：

    @reboot sleep 15 && nohup /usr/bin/python3 <dir>/redirect.py >> <dir>/redirect.log 2>&1 &
    */10 * * * * /bin/bash <dir>/check.sh

## 接入方式

- **Cloudflare Tunnel**：命名为 `copyattach` 的隧道 ingress 增加
  `dl.abovepast.shop → http://localhost:8100`，并执行
  `cloudflared tunnel route dns copyattach dl.abovepast.shop` 建立 CNAME。
- **链接**：官网 `src/config.js` 的 `LANZOU_URL`、Release 说明中的「国内下载」一律指向
  `https://dl.abovepast.shop/lanzou`，**不要**再直接写蓝奏域名。

## 蓝奏彻底换分享 / 分享被删时

只有一种情况需要改动本服务：分享 ID 变了。改 `redirect.py` 顶部的 `SHARE_ID`，
在服务器上重跑 `bash install.sh` 即可；域名池也可按需增删 `DOMAINS`。
## 当前部署状态（2026-09-16）

已上线并实测通过，运行在分发服务器上：

- 进程：`python3 ~/www/lanzou-redirect/redirect.py`，监听 `127.0.0.1:8100`
- 隧道：`copyattach` 的 ingress 增加 `dl.abovepast.shop → http://localhost:8100`
  （原 `copyattach.abovepast.shop → 8099` 保持不变）
- crontab：`@reboot` 自启 + `*/10` 自检（`check.sh` 掉线自动拉起）
- 线上实测：`https://dl.abovepast.shop/lanzou` → `302` → 蓝奏分享页 `200`；
  官网 `copyattach.abovepast.shop` 仍 `200`，未受影响

## 想彻底关掉服务器时：一次性完全脱离

**只迁跳转入口不等于脱离服务器**——官网也由这台机器提供。要真正下线，需同时完成两步：

1. **跳转入口 → Cloudflare Worker**：按本文件「对外契约」一节重写一个 Worker 即可，
   逻辑与 `redirect.py` 相同（探测域名池 → 302）。挂在自定义域 `dl.abovepast.shop`，
   **不要用 `workers.dev`**（中国大陆被污染，用户打不开）。
2. **官网 → Cloudflare Pages**：`npm run build` 后
   `npx wrangler pages deploy dist --project-name copyattach`

两步都完成后：删除 `dl` 与 `copyattach` 的隧道 CNAME、停掉 nginx 与 cloudflared、
取消 crontab 中相关 `@reboot` 项。**在此之前不要停任何现有服务**，否则入口会立刻不可用。

切换是 DNS 层面的：把 `dl` 的 CNAME 从隧道改为 Worker 自定义域即可；回滚同理（指回隧道）。

## 已知限制

- 入口可用性绑定在这台服务器上：断电、家里断网或机器故障时，跳转与官网同时不可用。
  这是选择 Pi 版的代价；`@reboot` 只覆盖重启，不覆盖断电期间。
- 因此若要高可用，应择机执行上面的「一次性完全脱离」。