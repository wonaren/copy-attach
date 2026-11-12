#!/bin/bash
set -euo pipefail

STRESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${APP:-$STRESS_ROOT/CopyAttach.app}"
BIN="$APP/Contents/MacOS/CopyAttach"
REAL_SUPPORT="$HOME/Library/Application Support/CopyAttach"
REAL_DB="$REAL_SUPPORT/history.db"
BACKUP_DIR="$REAL_SUPPORT/backups"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="${RUN_DIR:-/tmp/copyattach-stress/$RUN_ID}"
SCRATCH_DATA="$RUN_DIR/data"
REPORT="$RUN_DIR/report.md"
LOG="${LOG:-/tmp/copyattach_debug.log}"

FAILED=0
ISOLATED_PID=""
WAS_RUNNING=0
SAVED_CLIPBOARD=""

mkdir -p "$RUN_DIR" "$SCRATCH_DATA"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$REPORT"; }
h1()   { printf '\n=== %s ===\n\n' "$*" | tee -a "$REPORT"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$REPORT"; }
fail() { printf '[%s] FAIL: %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$REPORT"; FAILED=1; }

summary() {
    echo
    if [ "$FAILED" -eq 0 ]; then
        log "全部通过"
    else
        log "存在失败项，见 $REPORT"
    fi
    exit "$FAILED"
}

report_header() {
    {
        echo "# CopyAttach Stress Report"
        echo
        echo "- Run: $RUN_ID"
        echo "- Generated: $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "- Platform: $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
        echo "- Commit: $(git -C "$STRESS_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        echo "- Version: $(sed -n 's/^version = "\([^"]*\)".*/\1/p' "$STRESS_ROOT/Cargo.toml" | head -1)"
        echo
    } > "$REPORT"
}

app_pid() {
    pgrep -f 'CopyAttach.app/Contents/MacOS/CopyAttach' | head -1 || true
}

quit_app() {
    local pid
    pid="$(app_pid)"
    [ -n "$pid" ] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    local deadline=$((SECONDS + 8))
    while [ "$SECONDS" -lt "$deadline" ]; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
}

relaunch_real() {
    [ "$WAS_RUNNING" -eq 1 ] || return 0
    open "$APP"
}

cleanup_all() {
    if [ -n "${ISOLATED_PID:-}" ]; then
        kill -TERM "$ISOLATED_PID" 2>/dev/null || true
        local deadline=$((SECONDS + 5))
        while [ "$SECONDS" -lt "$deadline" ] && kill -0 "$ISOLATED_PID" 2>/dev/null; do
            sleep 0.1
        done
        kill -KILL "$ISOLATED_PID" 2>/dev/null || true
    fi
    if [ -n "${SAVED_CLIPBOARD:-}" ]; then
        printf '%s' "$SAVED_CLIPBOARD" | pbcopy 2>/dev/null || true
    fi
    relaunch_real
}

save_clipboard_text() {
    SAVED_CLIPBOARD="$(pbpaste 2>/dev/null || true)"
    if [ -z "$SAVED_CLIPBOARD" ]; then
        warn "当前剪贴板不是文本（或为空），测试结束后无法还原"
    fi
}

sql_scalar() {
    local db="$1" query="$2"
    sqlite3 "$db" "$query" 2>/dev/null || echo "ERR"
}

db_count() {
    sql_scalar "$1" "SELECT COUNT(*) FROM clipboard_history;"
}

backup_real_db() {
    BACKUP_PATH=""
    [ -f "$REAL_DB" ] || { warn "真实库不存在：$REAL_DB"; return 0; }
    mkdir -p "$BACKUP_DIR"
    local target="$BACKUP_DIR/stress_before_${RUN_ID}.db"
    local before after
    before="$(db_count "$REAL_DB")"
    sqlite3 "$REAL_DB" ".backup '$target'"
    after="$(db_count "$target")"
    if [ "$before" != "$after" ]; then
        fail "备份行数不一致：$before -> $after"
        return 1
    fi
    BACKUP_PATH="$target"
    log "真实库已备份：$target（$after 行）"
}

copy_db_into_scratch() {
    local src="$1"
    rm -f "$SCRATCH_DATA/history.db" "$SCRATCH_DATA/history.db-wal" "$SCRATCH_DATA/history.db-shm"
    sqlite3 "$src" ".backup '$SCRATCH_DATA/history.db'"
    local expected actual
    expected="$(db_count "$src")"
    actual="$(db_count "$SCRATCH_DATA/history.db")"
    if [ "$expected" != "$actual" ]; then
        fail "测试库复制行数不一致：$expected -> $actual"
        return 1
    fi
    log "测试库已就位：$SCRATCH_DATA（$actual 行）"
}

log_size() {
    if [ -f "$LOG" ]; then wc -c < "$LOG" | tr -d ' '; else echo 0; fi
}

wait_log_line() {
    local offset="$1" pattern="$2" timeout="${3:-30}"
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if tail -c +$((offset + 1)) "$LOG" 2>/dev/null | grep -q "$pattern"; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

launch_isolated() {
    quit_app
    local offset
    offset="$(log_size)"
    COPYATTACH_DATA_DIR="$SCRATCH_DATA" COPYATTACH_PERF=1 "$BIN" >>"$LOG" 2>&1 &
    ISOLATED_PID=$!
    LAUNCH_LOG_OFFSET="$offset"
    if ! wait_log_line "$offset" "Initialization complete" 30; then
        fail "隔离实例启动超时（pid=$ISOLATED_PID）"
        return 1
    fi
    if ! kill -0 "$ISOLATED_PID" 2>/dev/null; then
        fail "隔离实例启动后立即退出"
        return 1
    fi
    log "隔离实例已启动：pid=$ISOLATED_PID，数据目录=$SCRATCH_DATA"
}

wait_migration_if_needed() {
    local version
    version="$(sql_scalar "$SCRATCH_DATA/history.db" 'PRAGMA user_version;')"
    case "$version" in
        0|1|2|3)
            if wait_log_line "$LAUNCH_LOG_OFFSET" "metadata migration complete" 180; then
                log "元数据迁移完成（启动前 version=$version）"
            else
                warn "元数据迁移等待超时（version=$version）"
            fi
            ;;
    esac
}

quit_isolated() {
    [ -n "${ISOLATED_PID:-}" ] || return 0
    kill -TERM "$ISOLATED_PID" 2>/dev/null || true
    local deadline=$((SECONDS + 8))
    while [ "$SECONDS" -lt "$deadline" ] && kill -0 "$ISOLATED_PID" 2>/dev/null; do
        sleep 0.1
    done
    kill -KILL "$ISOLATED_PID" 2>/dev/null || true
    log "隔离实例已退出：pid=$ISOLATED_PID"
    ISOLATED_PID=""
}

vmmap_writable() {
    local pid="$1"
    vmmap -summary "$pid" 2>/dev/null | grep -m1 'Writable regions' || echo "Writable regions: unavailable"
}

mem_checkpoint() {
    local label="$1" pid="${2:-$ISOLATED_PID}"
    [ -n "$pid" ] || return 0
    {
        echo "### $label"
        echo '```'
        vmmap_writable "$pid"
        echo '```'
    } >> "$REPORT"
}

app_threshold() {
    local value
    value="$(defaults read cc.wonaren.copyattach CleanupThreshold 2>/dev/null || echo 3000)"
    case "$value" in ''|*[!0-9]*) echo 3000 ;; *) echo "$value" ;; esac
}

run_invariants() {
    local db="$1" mode="${2:-rest}"
    python3 "$STRESS_ROOT/scripts/stress/invariants.py" \
        --db "$db" --threshold "$(app_threshold)" --mode "$mode" \
        --report "$REPORT"
}
