#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
蓝奏云自动化上传与分发工具 (基于 lanzou-api 稳定版)
用于 GitHub Actions CI 在构建 Release 时自动将安装包上传到蓝奏云指定文件夹
"""

import sys
import os
import argparse
from lanzou.api import LanZouCloud
from requests_toolbelt.multipart.encoder import MultipartEncoder, MultipartEncoderMonitor

ACCOUNT_URL = "https://pc.woozooo.com/account.php"
MYDISK_URL = "https://pc.woozooo.com/mydisk.php"


def parse_cookie_str(cookie_str: str) -> dict:
    """解析形如 'ylogin=12345; phpdisk_info=xxx' 的 Cookie 字符串"""
    cookies = {}
    for item in cookie_str.strip().split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        k, v = item.split("=", 1)
        cookies[k.strip()] = v.strip()
    return cookies


def write_github_output(key: str, value: str):
    """写入 GitHub Actions Step Output"""
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file and os.path.exists(output_file):
        with open(output_file, "a", encoding="utf-8") as f:
            f.write(f"{key}={value}\n")


def login_by_cookie(lzy: LanZouCloud, cookies: dict) -> int:
    """使用控制台页验证 Cookie；lanzou-api 的 account.php 检查会误判当前页面。"""
    if "ylogin" not in cookies or "phpdisk_info" not in cookies:
        return LanZouCloud.FAILED
    lzy._uid = cookies["ylogin"]
    lzy._session.cookies.update(cookies)
    response = lzy._get(MYDISK_URL)
    if not response:
        return LanZouCloud.NETWORK_ERROR
    return LanZouCloud.SUCCESS if "mydisk.php?item=files" in response.text else LanZouCloud.FAILED


def upload_file(lzy: LanZouCloud, file_path: str, folder_id: int, callback=None, uploaded_handler=None) -> int:
    """调用蓝奏云当前网页上传接口 html5up.php。"""
    file_size = os.path.getsize(file_path)
    file_name = os.path.basename(file_path)
    with open(file_path, "rb") as file_handle:
        encoder = MultipartEncoder(fields={
            "task": "1",
            "vie": "2",
            "ve": "2",
            "folder_id_bb_n": str(folder_id),
            "name": file_name,
            "upload_file": (file_name, file_handle, "application/octet-stream"),
        })

        def report(monitor):
            if callback:
                callback(file_name, file_size, monitor.bytes_read)

        monitor = MultipartEncoderMonitor(encoder, report)
        headers = lzy._headers.copy()
        headers["Content-Type"] = monitor.content_type
        response = lzy._session.post(
            "https://pc.woozooo.com/html5up.php",
            data=monitor,
            headers=headers,
            verify=False,
            timeout=3600,
        )

    try:
        result = response.json()
    except ValueError:
        print(f"[!] 上传接口返回非 JSON: HTTP {response.status_code}")
        return LanZouCloud.FAILED

    if result.get("zt") != 1:
        print(f"[!] 蓝奏云拒绝上传: {result}")
        return LanZouCloud.FAILED

    items = result.get("text") or []
    if not items:
        return LanZouCloud.FAILED
    if uploaded_handler:
        uploaded_handler(int(items[0]["id"]), True)
    return LanZouCloud.SUCCESS


def main():
    parser = argparse.ArgumentParser(description="蓝奏云自动化上传工具")
    parser.add_argument("file", help="要上传的本地文件路径 (建议 .zip / .dmg 等)")
    parser.add_argument("--cookie", help="蓝奏云 Cookie 字符串 (包含 ylogin 与 phpdisk_info)", default=None)
    parser.add_argument("--folder-id", help="目标文件夹 ID (默认根目录 -1)", default="-1")
    parser.add_argument("--folder-name", help="目标文件夹名称 (如果指定，自动查找对应 folder-id)", default=None)
    parser.add_argument("--password", help="为上传的文件设置访问密码/提取码 (可选)", default=None)
    args = parser.parse_args()

    cookie_str = args.cookie or os.environ.get("LANZOU_COOKIE")
    if not cookie_str:
        print("[!] 错误: 未提供 Cookie。请通过 --cookie 参数或环境变量 LANZOU_COOKIE 传入。")
        sys.exit(1)

    cookies = parse_cookie_str(cookie_str)
    if "ylogin" not in cookies or "phpdisk_info" not in cookies:
        print("[!] 警告: Cookie 缺少 ylogin 或 phpdisk_info")

    lzy = LanZouCloud()

    print("[*] 正在验证蓝奏云登录态...")
    code = login_by_cookie(lzy, cookies)
    if code != LanZouCloud.SUCCESS:
        print(f"[!] 登录失败！错误代码: {code}，请检查 Cookie 是否有效、是否从 pc.woozooo.com 域名复制，或是否已过期。")
        print("    Cookie 只需要包含 ylogin 和 phpdisk_info，不要复制浏览器的 Cookie 请求头前缀。")
        sys.exit(1)
    print("[+] 登录成功！")

    folder_id = int(args.folder_id) if args.folder_id.lstrip("-").isdigit() else -1

    if args.folder_name:
        folders = lzy.get_move_folders()
        target = None
        for f in folders:
            if f.name == args.folder_name:
                target = f
                break
        if target:
            folder_id = target.id
            print(f"[+] 找到文件夹 '{args.folder_name}' -> ID: {folder_id}")
        else:
            print(f"[!] 未找到名为 '{args.folder_name}' 的文件夹，可用文件夹: {[f.name for f in folders]}")
            sys.exit(1)

    file_path = os.path.abspath(args.file)
    file_size = os.path.getsize(file_path)
    file_name = os.path.basename(file_path)
    print(f"[*] 准备上传: {file_name} ({file_size / 1024 / 1024:.2f} MB) -> folder_id: {folder_id}")

    uploaded_fid = None

    def progress_callback(name, total_size, now_size):
        percent = (now_size / total_size) * 100 if total_size > 0 else 100
        print(f"\r[*] 上传进度: {now_size}/{total_size} bytes ({percent:.1f}%)", end="", flush=True)

    def uploaded_handler(fid, is_file):
        nonlocal uploaded_fid
        if is_file:
            uploaded_fid = fid
            if args.password:
                res = lzy.set_passwd(fid, args.password, is_file=True)
                if res == LanZouCloud.SUCCESS:
                    print(f"\n[+] 成功设置提取码: {args.password}")
                else:
                    print(f"\n[!] 设置提取码返回码: {res}")

    code = upload_file(
        lzy,
        file_path,
        folder_id=folder_id,
        callback=progress_callback,
        uploaded_handler=uploaded_handler,
    )
    print()

    if code == LanZouCloud.SUCCESS:
        print(f"\n🎉 上传成功!")
        print(f"   文件名: {file_name}")
        if uploaded_fid:
            print(f"   文件 ID: {uploaded_fid}")
            share_url = f"https://wwbvw.lanzouv.com/{uploaded_fid}"
            print(f"   下载页面: {share_url}")
            write_github_output("lanzou_file_id", str(uploaded_fid))
            write_github_output("lanzou_file_url", share_url)
        write_github_output("lanzou_file_name", file_name)
    else:
        print(f"\n[!] 上传失败，返回码: {code}")
        sys.exit(1)


if __name__ == "__main__":
    main()
