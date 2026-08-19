#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""蓝奏云 Cookie 保活验证脚本。仅验证当前 Cookie，不修改 GitHub Secret。"""

import sys
import os
import requests

LANZOU_MYDISK_URL = "https://pc.woozooo.com/mydisk.php"
LANZOU_DOUPLOAD_URL = "https://pc.woozooo.com/doupload.php"

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/75.0.3770.100 Safari/537.36",
    "Referer": "https://pc.woozooo.com/mydisk.php",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
}


def parse_cookie_str(cookie_str: str) -> dict:
    cookies = {}
    for item in cookie_str.strip().split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        k, v = item.split("=", 1)
        cookies[k.strip()] = v.strip()
    return cookies


def main():
    cookie_str = os.environ.get("LANZOU_COOKIE", "").strip()
    if not cookie_str:
        print("[!] 错误: 未找到环境变量 LANZOU_COOKIE")
        sys.exit(1)

    cookies = parse_cookie_str(cookie_str)
    session = requests.Session()
    session.cookies.update(cookies)

    print("[*] 正在请求蓝奏云控制台进行心跳保活...")
    try:
        resp = session.get(LANZOU_MYDISK_URL, headers=HEADERS, timeout=20)
    except Exception as e:
        print(f"[!] 网络请求失败: {e}")
        sys.exit(1)

    if resp.status_code != 200 or "网盘用户登录" in resp.text or ("退出" not in resp.text and "我的网盘" not in resp.text):
        # 尝试通过接口再次探测
        try:
            test_resp = session.post(LANZOU_DOUPLOAD_URL, data={"task": "18"}, headers=HEADERS, timeout=15)
            if test_resp.json().get("zt") != 1:
                print("[!] 蓝奏云 Cookie 已完全失效，需要手动在浏览器中重新登录并更新 Secret！")
                sys.exit(1)
        except Exception:
            print("[!] 蓝奏云 Cookie 已失效！")
            sys.exit(1)

    print("[+] 蓝奏云 Session 活跃，保活成功！")

    # 提取最新的 Cookie
    new_cookies = session.cookies.get_dict()
    updated = False

    # 保留原有的 ylogin 和更新后的 phpdisk_info
    ylogin = new_cookies.get("ylogin") or cookies.get("ylogin")
    phpdisk_info = new_cookies.get("phpdisk_info") or cookies.get("phpdisk_info")

    if not ylogin or not phpdisk_info:
        print("[!] 缺少必要的 cookie 键")
        sys.exit(0)

    new_cookie_str = f"ylogin={ylogin}; phpdisk_info={phpdisk_info}"

    if phpdisk_info != cookies.get("phpdisk_info"):
        print("[+] 检测到 phpdisk_info 发生更新，准备同步最新 Secret...")
        updated = True
    else:
        print("[*] Cookie 未发生变动，状态正常。")

    # 输出到 GitHub Output
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file and os.path.exists(output_file):
        with open(output_file, "a", encoding="utf-8") as f:
            f.write(f"updated={'true' if updated else 'false'}\n")
            f.write(f"new_cookie={new_cookie_str}\n")


if __name__ == "__main__":
    main()
