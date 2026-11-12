#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

trap cleanup_all EXIT INT TERM

report_header
RUN_START_EPOCH="$(date +%s)"
WAS_RUNNING=0
if [ -n "$(app_pid)" ]; then WAS_RUNNING=1; fi
save_clipboard_text

h1 "P1: 真实路径撤销/删除批量测试"
backup_real_db || fail "真实库备份失败"
if [ -n "${BACKUP_PATH:-}" ]; then
    copy_db_into_scratch "$BACKUP_PATH" || fail "测试库准备失败"
fi
quit_app

if COPYATTACH_DATA_DIR="$SCRATCH_DATA" cargo test --release --features stress-test --lib \
        tests::soft_delete_real:: -- --ignored --nocapture --test-threads=1 2>&1 | tee -a "$REPORT"; then
    log "真实路径删除/撤销/内存断言通过"
else
    fail "真实路径删除/撤销/内存断言失败"
fi

run_invariants "$SCRATCH_DATA/history.db" rest || fail "批量删除/撤销后不变量检查失败"
bash "$STRESS_ROOT/scripts/stress/crash_scan.sh" --since-epoch "$RUN_START_EPOCH" --report "$REPORT" || fail "指定窗口内存在崩溃报告"

h1 "产物"
log "运行目录：$RUN_DIR"
log "报告：$REPORT"

summary
