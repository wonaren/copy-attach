#!/bin/bash
# 在分发服务器上安装/更新蓝奏云稳定跳转服务。
# 幂等：重复执行只做覆盖 + 重启 + 自检。
# 用法（在服务器上）: bash install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PY="$(command -v python3)"

echo "[*] python: $PY"
"$PY" -c 'import sys; assert sys.version_info >= (3, 8), "需要 Python 3.8+"'

# 1) 语法自检：坏文件绝不进生产
"$PY" -m py_compile "$ROOT/redirect.py"

# 2) 停掉旧进程（只认本目录，不误伤其他 python 服务）
if pgrep -f "$ROOT/redirect.py" >/dev/null 2>&1; then
  pkill -f "$ROOT/redirect.py" || true
  sleep 1
fi

# 3) 启动
nohup "$PY" "$ROOT/redirect.py" >> "$ROOT/redirect.log" 2>&1 &
sleep 1

# 4) 自检：本机 302 + Location 指向蓝奏
PORT=$(grep -oE 'LISTEN = \("127.0.0.1", [0-9]+' "$ROOT/redirect.py" | grep -oE '[0-9]+$')
LOC=$(curl -s -o /dev/null -D - --max-time 10 "http://127.0.0.1:${PORT}/lanzou" | grep -i '^location:' | tr -d '\r')
if [ -z "$LOC" ]; then
  echo "[!] 自检失败：未拿到 Location 头"
  tail -5 "$ROOT/redirect.log"
  exit 1
fi
echo "[+] $LOC"
curl -s --max-time 10 "http://127.0.0.1:${PORT}/healthz"; echo
echo "[+] install ok"
