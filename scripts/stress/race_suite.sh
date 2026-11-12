#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ROUNDS=20
RUST_RUNS=20
SKIP_RUST=0
DB="${DB:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --rounds) ROUNDS="$2"; shift 2 ;;
        --rust-runs) RUST_RUNS="$2"; shift 2 ;;
        --db) DB="$2"; shift 2 ;;
        --skip-rust) SKIP_RUST=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

trap cleanup_all EXIT INT TERM
report_header
RUN_START_EPOCH="$(date +%s)"
WAS_RUNNING=0
if [ -n "$(app_pid)" ]; then WAS_RUNNING=1; fi
save_clipboard_text

backup_real_db || fail "真实库备份失败"
if [ -z "$DB" ]; then
    DB="$RUN_DIR/dataset.db"
    cargo build --release --features stress-test --bin stress-gen >>"$REPORT" 2>&1
    "$STRESS_ROOT/target/release/stress-gen" --count 300 --text-ratio 0.5 --seed 21 \
        --db-path "$DB" --threshold "$(app_threshold)" --report >>"$REPORT" 2>&1
fi

h1 "S4.1 应用层：捕获与开合交错（$ROUNDS 轮）"
copy_db_into_scratch "$DB"
launch_isolated
wait_migration_if_needed
for round in $(seq 1 "$ROUNDS"); do
    for i in $(seq 1 20); do
        printf 'CA-RACE-%s-%02d-%02d' "$RUN_ID" "$round" "$i" | pbcopy
        sleep 0.02
    done
    open "$APP"
    sleep 0.35
    open "$APP"
    sleep 0.35
    if ! kill -0 "$ISOLATED_PID" 2>/dev/null; then
        fail "第 $round 轮交错后隔离实例退出"
        break
    fi
    log "交错轮次 $round/$ROUNDS"
done
quit_isolated
run_invariants "$SCRATCH_DATA/history.db" rest || fail "交错测试后不变量失败"

h1 "S4.2 强制终止后重启（kill -9）"
copy_db_into_scratch "$DB"
launch_isolated
wait_migration_if_needed
BEFORE="$(db_count "$SCRATCH_DATA/history.db")"
for i in $(seq 1 60); do
    printf 'CA-KILL-%s-%03d' "$RUN_ID" "$i" | pbcopy
    sleep 0.01
done
sleep 0.4
kill -KILL "$ISOLATED_PID" 2>/dev/null || true
ISOLATED_PID=""
sleep 0.5
launch_isolated
wait_migration_if_needed
AFTER="$(db_count "$SCRATCH_DATA/history.db")"
log "kill -9 前后行数：$BEFORE → $AFTER"
if kill -0 "$ISOLATED_PID" 2>/dev/null; then
    log "kill -9 后重启成功"
else
    fail "kill -9 后无法重启"
fi
quit_isolated
run_invariants "$SCRATCH_DATA/history.db" rest || fail "kill -9 恢复后不变量失败"

if [ "$SKIP_RUST" -eq 0 ]; then
    h1 "S4.3 真实路径删除/撤销重复（$RUST_RUNS 次）"
    copy_db_into_scratch "$DB"
    sqlite3 "$SCRATCH_DATA/history.db" \
        "INSERT INTO clipboard_meta (key, value) VALUES ('undo_budget_bytes', 0)
         ON CONFLICT(key) DO UPDATE SET value = 0;"
    FAILS=0
    for run in $(seq 1 "$RUST_RUNS"); do
        set +e
        COPYATTACH_DATA_DIR="$SCRATCH_DATA" cargo test --release --features stress-test --lib \
            tests::soft_delete_real:: -- --ignored --nocapture --test-threads=1 >>"$REPORT" 2>&1
        rc=$?
        set -e
        if [ "$rc" -ne 0 ]; then
            FAILS=$((FAILS + 1))
            warn "第 $run 次失败（累计 $FAILS）"
        fi
    done
    if [ "$FAILS" -ne 0 ]; then
        fail "真实路径测试 $FAILS/$RUST_RUNS 次失败（失败率 $FAILS/$RUST_RUNS）"
    else
        log "真实路径测试 $RUST_RUNS/$RUST_RUNS 通过"
    fi
fi

h1 "汇总"
bash "$STRESS_ROOT/scripts/stress/crash_scan.sh" --since-epoch "$RUN_START_EPOCH" --report "$REPORT" || fail "指定窗口内存在崩溃报告"
log "报告：$REPORT"
summary
