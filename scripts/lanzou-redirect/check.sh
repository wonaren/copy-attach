#!/bin/bash
# 跳转服务自检 + 自动拉起（供 crontab 周期调用；每次动作都落日志）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PORT=$(grep -oE 'LISTEN = \("127.0.0.1", [0-9]+' "$ROOT/redirect.py" | grep -oE '[0-9]+$')
STAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() { echo "$STAMP [check] $*" >> "$ROOT/redirect.log"; }

if ! pgrep -f "$ROOT/redirect.py" >/dev/null 2>&1; then
  log "process missing; restarting"
  nohup "$(command -v python3)" "$ROOT/redirect.py" >> "$ROOT/redirect.log" 2>&1 &
  sleep 2
fi

LOC=$(curl -s -o /dev/null -D - --max-time 10 "http://127.0.0.1:${PORT}/lanzou" | grep -i '^location:' | tr -d '\r')
if [ -z "$LOC" ]; then
  log "local check FAILED; restarting"
  pkill -f "$ROOT/redirect.py" || true
  sleep 1
  nohup "$(command -v python3)" "$ROOT/redirect.py" >> "$ROOT/redirect.log" 2>&1 &
  sleep 2
  LOC=$(curl -s -o /dev/null -D - --max-time 10 "http://127.0.0.1:${PORT}/lanzou" | grep -i '^location:' | tr -d '\r')
  if [ -z "$LOC" ]; then
    log "still FAILED after restart"
    exit 1
  fi
fi

PUB=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://dl.abovepast.shop/lanzou" || echo 000)
log "ok | $LOC | public=$PUB"
[ "$PUB" = "302" ] || exit 1
