#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CopyAttach 蓝奏云稳定跳转入口。

蓝奏云会不定期轮换对外域名（pan.lanzoub.com / wwbvw.lanzouv.com / ...），
任一写死的域名迟早 NXDOMAIN，导致发布说明与官网上的下载链接随域名一起失效。

本服务对外暴露一个永久不变的地址（https://dl.abovepast.shop/lanzou）：
每次请求时在候选域名池里探测哪一个真的能打开当前分享页，然后 302 过去。
分享 ID 与域名池只存在于本文件，蓝奏换域名时运维无需改动官网 / Release。

对外契约：
  GET /lanzou   -> 302 Location: https://<healthy-domain>/<SHARE_ID>
  GET /healthz  -> 200 JSON，当前选中域名与最近一次探测结果
"""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# ── 唯一配置点 ──────────────────────────────────────────────────────────
# 分享 ID：蓝奏云文件夹分享 ID，稳定不变（换域名不影响它）。
SHARE_ID = "b0341lhs5g"
# 候选域名池：按历史稳定性排序，探测出第一个真正可用的即采用。
DOMAINS = [
    "wwbvw.lanzouv.com",
    "wwv.lanzouw.com",
    "www.lanzoui.com",
    "www.lanzoux.com",
    "pan.lanzoub.com",
    "pan.lanzoui.com",
    "wwb.lanzouw.com",
]
# 分享页有效性标记：域名存活且分享存在时，页面内联脚本引用了 /savep.php。
# 域名解析不到或分享被删时，页面只有 ~1KB 且不含该串——两种失效都能识别。
MARKER = b"savep.php"

PROBE_TIMEOUT = 8          # 单个域名探测超时（秒）
PROBE_TTL = 300            # 选中域名多久后重新探测
RETRY_TTL = 30             # 全池失败后多久重试
STATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "state.json")
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "redirect.log")
LISTEN = ("127.0.0.1", 8100)
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"

_state = {"domain": None, "checked_at": 0.0, "ok": False}
_state_lock = threading.Lock()
_refresh_lock = threading.Lock()


def log(message: str) -> None:
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n"
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(line)
    except OSError:
        pass
    sys.stdout.write(line)
    sys.stdout.flush()


def load_state() -> None:
    try:
        with open(STATE_PATH, encoding="utf-8") as handle:
            saved = json.load(handle)
        if saved.get("domain") in DOMAINS:
            _state.update({"domain": saved["domain"], "checked_at": 0.0, "ok": False})
    except (OSError, ValueError):
        pass


def save_state() -> None:
    tmp = STATE_PATH + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump({"domain": _state["domain"], "checked_at": _state["checked_at"]}, handle)
        os.replace(tmp, STATE_PATH)
    except OSError as error:
        log(f"state write failed: {error}")


def probe(domain: str) -> bool:
    url = f"https://{domain}/{SHARE_ID}"
    request = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(request, timeout=PROBE_TIMEOUT) as response:
            if response.status != 200:
                log(f"probe {domain}: HTTP {response.status}")
                return False
            body = response.read(200_000)
    except (URLError, HTTPError, OSError) as error:
        log(f"probe {domain}: {error}")
        return False
    hit = MARKER in body
    log(f"probe {domain}: {'ok' if hit else 'marker missing'} ({len(body)} bytes)")
    return hit


def refresh() -> bool:
    """串行化探测，避免并发请求同时打满域名池。"""
    with _refresh_lock:
        # 拿到锁后可能已被别的线程刷新过，复核一次 TTL。
        with _state_lock:
            age = time.time() - _state["checked_at"]
            ttl = PROBE_TTL if _state["ok"] else RETRY_TTL
            if _state["domain"] and age <= ttl:
                return True
        for domain in DOMAINS:
            if probe(domain):
                with _state_lock:
                    _state.update({"domain": domain, "checked_at": time.time(), "ok": True})
                save_state()
                log(f"selected {domain}")
                return True
        with _state_lock:
            _state["checked_at"] = time.time()
            _state["ok"] = False
        log("no healthy domain in pool")
        return False


def current_domain():
    with _state_lock:
        domain = _state["domain"]
        age = time.time() - _state["checked_at"]
        healthy = _state["ok"]
    ttl = PROBE_TTL if healthy else RETRY_TTL
    if domain is None or age > ttl:
        refresh()
        with _state_lock:
            domain = _state["domain"]
    return domain


class Handler(BaseHTTPRequestHandler):
    server_version = "lanzou-redirect/1.0"
    protocol_version = "HTTP/1.1"

    def _redirect(self, include_body: bool) -> None:
        domain = current_domain() or DOMAINS[0]
        location = f"https://{domain}/{SHARE_ID}"
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Content-Length", "0")
        self.end_headers()
        if include_body:
            log(f"302 {location} (from {self.client_address[0]})")

    def do_GET(self) -> None:
        if self.path.split("?")[0] == "/healthz":
            with _state_lock:
                payload = {
                    "domain": _state["domain"],
                    "healthy": _state["ok"],
                    "checked_at": _state["checked_at"],
                    "share_id": SHARE_ID,
                }
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._redirect(include_body=True)

    def do_HEAD(self) -> None:
        self._redirect(include_body=False)

    def log_message(self, message: str, *args) -> None:
        # 默认实现会把每次访问写进 stderr；统一走滚动日志。
        return


def main() -> None:
    load_state()
    refresh()
    server = ThreadingHTTPServer(LISTEN, Handler)
    server.daemon_threads = True
    log(f"listening on http://{LISTEN[0]}:{LISTEN[1]}  share={SHARE_ID}")
    server.serve_forever()


if __name__ == "__main__":
    main()
