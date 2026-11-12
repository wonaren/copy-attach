#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DB=""
SMOKE=10
SETTLE=2
ROUNDS=1
PREMIGRATE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --db) DB="$2"; shift 2 ;;
        --smoke) SMOKE="$2"; shift 2 ;;
        --settle) SETTLE="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        --premigrate) PREMIGRATE=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$DB" ] || { echo "--db required" >&2; exit 2; }

trap cleanup_all EXIT INT TERM

report_header
WAS_RUNNING=0
if [ -n "$(app_pid)" ]; then WAS_RUNNING=1; fi
save_clipboard_text

copy_db_into_scratch "$DB"
log "源库：$DB（version=$(sql_scalar "$DB" 'PRAGMA user_version;') rows=$(db_count "$DB")）"

if [ "$PREMIGRATE" -eq 1 ]; then
    launch_isolated
    if wait_log_line "$LAUNCH_LOG_OFFSET" "metadata migration complete" 120; then
        log "预迁移完成：version=$(sql_scalar "$SCRATCH_DATA/history.db" 'PRAGMA user_version;')"
    else
        warn "预迁移等待超时"
    fi
    quit_isolated
fi

launch_isolated
sleep "$SETTLE"
for round in $(seq 1 "$ROUNDS"); do
    START_MS="$(bash "$STRESS_ROOT/perf/collect.sh" begin)"
    APP="$APP" LOG="$LOG" bash "$STRESS_ROOT/perf/collect.sh" smoke "$SMOKE" >/dev/null 2>&1 || true
    OUT="$RUN_DIR/perf-round-$round.md"
    if APP="$APP" LOG="$LOG" bash "$STRESS_ROOT/perf/collect.sh" analyze "$START_MS" >"$OUT" 2>&1; then
        log "round $round：perf VALID"
    else
        warn "round $round：perf 未通过（$OUT）"
    fi
    grep -E "thumb\.|thumbnail decode" "$OUT" | sed 's/^/  /' | tee -a "$REPORT"
done
quit_isolated
bash "$STRESS_ROOT/scripts/stress/crash_scan.sh" --hours 1 --report "$REPORT" || fail "最近一小时存在崩溃报告"
summary
