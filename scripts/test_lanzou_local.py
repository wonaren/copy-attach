#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地蓝奏云上传验证器。不会运行 CI，也不会读取或打印 Cookie。"""

import argparse
import getpass
import os
import sys
import tempfile
import zipfile
from pathlib import Path

from lanzou_uploader import login_by_cookie, upload_file


def main():
    parser = argparse.ArgumentParser(description="本地验证蓝奏云 Cookie、文件夹和上传流程")
    parser.add_argument("file", nargs="?", help="待上传文件；不传则自动生成一个临时测试 zip")
    parser.add_argument("--cookie", help="Cookie；省略时从 LANZOU_COOKIE 读取，再交互式输入")
    parser.add_argument("--folder-name", default="copyattach", help="目标文件夹名")
    parser.add_argument("--folder-id", type=int, help="已知目标文件夹 ID；传入后跳过文件夹查询")
    parser.add_argument("--password", default="", help="上传文件提取码；留空则不设置")
    args = parser.parse_args()

    cookie = args.cookie or os.environ.get("LANZOU_COOKIE") or getpass.getpass("LANZOU_COOKIE: ")
    if not cookie.strip():
        raise SystemExit("未提供 Cookie")

    try:
        from lanzou.api import LanZouCloud
    except ImportError:
        raise SystemExit("缺少依赖，请先运行: python3 -m pip install -r scripts/requirements-lanzou.txt")

    temp_dir = None
    if args.file:
        file_path = Path(args.file).expanduser().resolve()
    else:
        temp_dir = tempfile.TemporaryDirectory(prefix="copyattach-lanzou-")
        file_path = Path(temp_dir.name) / "copyattach-upload-test.zip"
        with zipfile.ZipFile(file_path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("README.txt", "CopyAttach Lanzou local upload test\n")
        print(f"[*] 未指定文件，已生成测试文件: {file_path}")

    if not file_path.is_file():
        raise SystemExit(f"文件不存在: {file_path}")

    cookies = {}
    for item in cookie.split(";"):
        item = item.strip()
        if "=" in item:
            key, value = item.split("=", 1)
            cookies[key.strip()] = value.strip()

    missing = {"ylogin", "phpdisk_info"} - cookies.keys()
    if missing:
        raise SystemExit(f"Cookie 缺少: {', '.join(sorted(missing))}")

    lzy = LanZouCloud()
    print("[*] 验证登录态...")
    code = login_by_cookie(lzy, cookies)
    if code != LanZouCloud.SUCCESS:
        raise SystemExit(f"登录失败，返回码: {code}。请重新从 pc.woozooo.com 复制 Cookie。")
    print("[+] 登录成功")

    folder_id = args.folder_id
    if folder_id is None:
        print("[*] 查询文件夹...")
        folders = lzy.get_move_folders()
        print("[*] 可用文件夹:", ", ".join(f"{folder.name}={folder.id}" for folder in folders))
        target = next((folder for folder in folders if folder.name == args.folder_name), None)
        if target is None:
            raise SystemExit(f"找不到文件夹: {args.folder_name}")
        folder_id = target.id
    print(f"[+] 目标文件夹: {args.folder_name} ({folder_id})")

    def progress(name, total, current):
        percent = current * 100 / total if total else 100
        print(f"\r[*] 上传进度: {percent:5.1f}%", end="", flush=True)

    uploaded_id = None

    def uploaded_handler(file_id, is_file):
        nonlocal uploaded_id
        if is_file:
            uploaded_id = file_id

    print(f"[*] 上传: {file_path.name} ({file_path.stat().st_size} bytes)")
    code = upload_file(lzy, str(file_path), folder_id=folder_id, callback=progress, uploaded_handler=uploaded_handler)
    print()
    if code != LanZouCloud.SUCCESS:
        raise SystemExit(f"上传失败，返回码: {code}")

    if not uploaded_id:
        raise SystemExit("上传返回成功，但没有拿到文件 ID")

    print(f"[+] 上传成功: https://wwbvw.lanzouv.com/{uploaded_id}")
    if args.password:
        password_code = lzy.set_passwd(uploaded_id, args.password, is_file=True)
        if password_code != LanZouCloud.SUCCESS:
            raise SystemExit(f"上传成功，但设置提取码失败，返回码: {password_code}")
        print("[+] 提取码设置成功")

    print("[+] 本地验证完成")
    if temp_dir:
        temp_dir.cleanup()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n已取消")
        sys.exit(130)
