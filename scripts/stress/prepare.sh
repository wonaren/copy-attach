#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

report_header
h1 "P0 准备"

WAS_RUNNING=0
if [ -n "$(app_pid)" ]; then WAS_RUNNING=1; fi

[ -x "$BIN" ] || fail "找不到可执行文件：$BIN"
if [ -x "$BIN" ]; then
    APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
    SRC_VERSION="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "$STRESS_ROOT/Cargo.toml" | head -1)"
    if [ "$APP_VERSION" = "$SRC_VERSION" ]; then
        log "构建版本一致：$APP_VERSION"
    else
        fail "构建版本 $APP_VERSION 与 Cargo.toml $SRC_VERSION 不一致，先 ./build.sh"
    fi
    if codesign --verify --deep --strict "$APP" 2>/dev/null; then
        log "代码签名校验通过"
    else
        fail "代码签名校验失败"
    fi
    codesign -dv --verbose=4 "$APP" 2>&1 | grep '^Authority=' | sed 's/^/  /' | tee -a "$REPORT"
fi

h1 "备份真实库"
backup_real_db || fail "真实库备份失败"

h1 "准备隔离副本"
if [ -n "${BACKUP_PATH:-}" ] && [ -f "$BACKUP_PATH" ]; then
    copy_db_into_scratch "$BACKUP_PATH" || fail "测试库复制失败"
    {
        echo "### 库状态"
        echo '```'
        printf 'live_rows=%s\n' "$(db_count "$SCRATCH_DATA/history.db")"
        printf 'favorites=%s\n' "$(sql_scalar "$SCRATCH_DATA/history.db" 'SELECT COUNT(*) FROM clipboard_favorites;')"
        printf 'quick_slots=%s\n' "$(sql_scalar "$SCRATCH_DATA/history.db" 'SELECT COUNT(*) FROM clipboard_quick_slots;')"
        printf 'deleted=%s\n' "$(sql_scalar "$SCRATCH_DATA/history.db" 'SELECT COUNT(*) FROM clipboard_deleted;')"
        printf 'user_version=%s\n' "$(sql_scalar "$SCRATCH_DATA/history.db" 'PRAGMA user_version;')"
        printf 'threshold=%s\n' "$(app_threshold)"
        echo '```'
    } | tee -a "$REPORT"
else
    fail "没有可用的真实库备份"
fi

if [ -n "$(app_pid)" ]; then
    mem_checkpoint "准备前（真实实例）" "$(app_pid)"
fi

h1 "产物"
log "运行目录：$RUN_DIR"
log "隔离数据目录：$SCRATCH_DATA"
log "报告：$REPORT"
log "真实库未被修改；后续套件会临时退出真实实例并启动隔离实例，结束时自动恢复"

summary
