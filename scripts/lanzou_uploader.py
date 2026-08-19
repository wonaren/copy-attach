#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
蓝奏云自动化上传与分发工具
用于 GitHub Actions CI 在构建 Release 时自动将安装包上传到蓝奏云指定文件夹
"""

import sys
import os
import argparse
import requests
from requests_toolbelt.multipart.encoder import MultipartEncoder, MultipartEncoderMonitor

LANZOU_DOUPLOAD_URL = "https://pc.woozooo.com/doupload.php"
LANZOU_MYDISK_URL = "https://pc.woozooo.com/mydisk.php"

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Referer": "https://pc.woozooo.com/mydisk.php",
    "Accept": "application/json, text/javascript, */*; q=0.01",
}


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


def verify_login(session: requests.Session) -> bool:
    """验证 Cookie 是否有效"""
    try:
        resp = session.get(LANZOU_MYDISK_URL, headers=HEADERS, timeout=15)
        if resp.status_code == 200 and "网盘用户登录" not in resp.text and ("退出" in resp.text or "我的网盘" in resp.text):
            return True
        test_resp = session.post(LANZOU_DOUPLOAD_URL, data={"task": "18"}, headers=HEADERS, timeout=15)
        res = test_resp.json()
        if res.get("zt") == 1:
            return True
    except Exception as e:
        print(f"[!] 登录状态检查异常: {e}")
    return False


def get_folders(session: requests.Session) -> list:
    """获取网盘下的文件夹列表"""
    try:
        resp = session.post(LANZOU_DOUPLOAD_URL, data={"task": "47", "folder_id": "-1"}, headers=HEADERS, timeout=15)
        data = resp.json()
        if data.get("zt") == 1:
            return data.get("text", [])
    except Exception as e:
        print(f"[!] 获取文件夹列表失败: {e}")
    return []


def set_file_password(session: requests.Session, file_id: str, password: str) -> bool:
    """设置单文件提取码 (密码)"""
    try:
        # task=23: 设置文件访问密码
        resp = session.post(
            LANZOU_DOUPLOAD_URL,
            data={"task": "23", "file_id": str(file_id), "shows": "1", "pass": password},
            headers=HEADERS,
            timeout=15
        )
        res = resp.json()
        return res.get("zt") == 1
    except Exception as e:
        print(f"[!] 设置提取码异常: {e}")
    return False


def upload_file(session: requests.Session, file_path: str, folder_id: str = "-1") -> dict:
    """上传文件到指定文件夹"""
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"文件不存在: {file_path}")

    filename = os.path.basename(file_path)
    file_size = os.path.getsize(file_path)
    print(f"[*] 准备上传: {filename} ({file_size / 1024 / 1024:.2f} MB) -> 目标 folder_id: {folder_id}")

    with open(file_path, "rb") as f:
        fields = {
            "task": "1",
            "vie": "2",
            "ve": "2",
            "id": "WU_FILE_0",
            "folder_id_bb_n": str(folder_id),
            "name": filename,
            "upload_file": (filename, f, "application/octet-stream")
        }

        encoder = MultipartEncoder(fields=fields)

        def progress_callback(monitor):
            percent = (monitor.bytes_read / file_size) * 100 if file_size > 0 else 100
            print(f"\r[*] 上传进度: {monitor.bytes_read}/{file_size} bytes ({percent:.1f}%)", end="", flush=True)

        monitor = MultipartEncoderMonitor(encoder, progress_callback)

        req_headers = HEADERS.copy()
        req_headers["Content-Type"] = monitor.content_type

        resp = session.post(
            LANZOU_DOUPLOAD_URL,
            data=monitor,
            headers=req_headers,
            timeout=3600
        )
        print()

    try:
        return resp.json()
    except Exception as e:
        return {"zt": 0, "info": f"解析响应失败: {resp.text}"}


def write_github_output(key: str, value: str):
    """写入 GitHub Actions Step Output"""
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file and os.path.exists(output_file):
        with open(output_file, "a", encoding="utf-8") as f:
            f.write(f"{key}={value}\n")


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
    session = requests.Session()
    session.cookies.update(cookies)

    print("[*] 正在验证蓝奏云登录态...")
    if not verify_login(session):
        print("[!] 登录失败！请检查 Cookie 是否有效或已过期。")
        sys.exit(1)
    print("[+] 登录成功！")

    folder_id = args.folder_id
    if args.folder_name:
        folders = get_folders(session)
        target = None
        for f in folders:
            if f.get("name") == args.folder_name:
                target = f
                break
        if target:
            folder_id = target.get("fol_id") or target.get("folder_id") or target.get("id")
            print(f"[+] 找到文件夹 '{args.folder_name}' -> ID: {folder_id}")
        else:
            print(f"[!] 未找到名为 '{args.folder_name}' 的文件夹，可用文件夹: {[f.get('name') for f in folders]}")
            sys.exit(1)

    res = upload_file(session, args.file, folder_id=folder_id)
    if res.get("zt") == 1:
        text_info = res.get("text", [])
        if isinstance(text_info, list) and len(text_info) > 0:
            file_item = text_info[0]
            f_id = file_item.get("id")
            f_name = file_item.get("name_all") or file_item.get("name")
            share_url = f"https://wwbvw.lanzouv.com/{f_id}"

            print(f"\n🎉 上传成功!")
            print(f"   文件名: {f_name}")
            print(f"   文件 ID: {f_id}")
            print(f"   下载页面: {share_url}")

            if args.password:
                if set_file_password(session, f_id, args.password):
                    print(f"   访问密码: {args.password} (已成功设置)")
                else:
                    print(f"   [!] 设置访问密码失败")

            write_github_output("lanzou_file_id", str(f_id))
            write_github_output("lanzou_file_url", share_url)
            write_github_output("lanzou_file_name", str(f_name))
        else:
            print(f"\n🎉 上传成功! 返回数据: {res}")
    else:
        print(f"\n[!] 上传失败: {res.get('info', res)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
