#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DB=""
BATCHES="10 20 30"

while [ $# -gt 0 ]; do
    case "$1" in
        --db) DB="$2"; shift 2 ;;
        --batches) BATCHES="$2"; shift 2 ;;
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
launch_isolated
wait_migration_if_needed
mem_checkpoint "启动后"

TOTAL=0
for n in $BATCHES; do
    TOTAL=$((TOTAL + n))
    bash "$STRESS_ROOT/perf/collect.sh" smoke "$n" >/dev/null 2>&1 || warn "smoke $n 失败"
    sleep 1
    mem_checkpoint "开合累计 $TOTAL 次"
done

quit_isolated
bash "$STRESS_ROOT/scripts/stress/crash_scan.sh" --since-epoch "$(( $(date +%s) - 3600 ))" --report "$REPORT" >/dev/null 2>&1 || true
summary
