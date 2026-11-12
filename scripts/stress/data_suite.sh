#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

COUNT=1000
CAPTURE=200
PACED=50
SMOKE=10

while [ $# -gt 0 ]; do
    case "$1" in
        --count) COUNT="$2"; shift 2 ;;
        --capture) CAPTURE="$2"; shift 2 ;;
        --paced) PACED="$2"; shift 2 ;;
        --smoke) SMOKE="$2"; shift 2 ;;
        --full) COUNT=10000; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

trap cleanup_all EXIT INT TERM

report_header
RUN_START_EPOCH="$(date +%s)"
RUN_LOG_OFFSET="$(log_size)"
WAS_RUNNING=0
if [ -n "$(app_pid)" ]; then WAS_RUNNING=1; fi
save_clipboard_text

h1 "P1: S1 数据与持久化"
log "参数：count=$COUNT paced=$PACED burst=$CAPTURE smoke=$SMOKE threshold=$(app_threshold)"

backup_real_db || fail "真实库备份失败"
if [ -n "${BACKUP_PATH:-}" ]; then
    copy_db_into_scratch "$BACKUP_PATH" || fail "真实库副本准备失败"
fi

h1 "Session A：真实库副本启动"
if launch_isolated; then
    wait_migration_if_needed
    mem_checkpoint "启动后（真实库副本）"
    quit_isolated
    run_invariants "$SCRATCH_DATA/history.db" rest || fail "真实库副本不变量检查失败"
else
    fail "Session A 启动失败"
fi

h1 "Session B：生成数据集"
cargo build --release --features stress-test --bin stress-gen >>"$REPORT" 2>&1
"$STRESS_ROOT/target/release/stress-gen" \
    --count "$COUNT" --text-ratio 0.6 --seed 42 \
    --db-path "$RUN_DIR/dataset.db" --threshold "$(app_threshold)" --report \
    >>"$REPORT" 2>&1
log "数据集：$RUN_DIR/dataset.db（$(db_count "$RUN_DIR/dataset.db") 行）"
run_invariants "$RUN_DIR/dataset.db" generated || fail "生成数据集不变量检查失败"

copy_db_into_scratch "$RUN_DIR/dataset.db" || fail "数据集复制失败"
if launch_isolated; then
    wait_migration_if_needed
    mem_checkpoint "启动后（数据集）"

    h1 "弹窗开合（$SMOKE 次）"
    START_MS="$(bash "$STRESS_ROOT/perf/collect.sh" begin)"
    if APP="$APP" LOG="$LOG" bash "$STRESS_ROOT/perf/collect.sh" smoke "$SMOKE" >>"$REPORT" 2>&1; then
        log "弹窗开合完成"
    else
        fail "弹窗开合失败"
    fi
    if APP="$APP" LOG="$LOG" bash "$STRESS_ROOT/perf/collect.sh" analyze "$START_MS" >"$RUN_DIR/perf.md" 2>&1; then
        log "perf 门禁通过（$RUN_DIR/perf.md）"
        tail -n 20 "$RUN_DIR/perf.md" >>"$REPORT"
    else
        fail "perf 门禁未通过（$RUN_DIR/perf.md）"
    fi
    mem_checkpoint "弹窗开合后"

    h1 "节奏捕获（0.7s × $PACED 条）"
    BEFORE="$(db_count "$SCRATCH_DATA/history.db")"
    for i in $(seq 1 "$PACED"); do
        printf 'CA-PACE-%s-%05d' "$RUN_ID" "$i" | pbcopy
        sleep 0.7
    done
    PACED_LAST="$(printf 'CA-PACE-%s-%05d' "$RUN_ID" "$PACED")"
    sleep 1
    AFTER="$(db_count "$SCRATCH_DATA/history.db")"
    PACED_DELTA=$((AFTER - BEFORE))
    NEWEST="$(sql_scalar "$SCRATCH_DATA/history.db" "SELECT text FROM clipboard_history WHERE entry_type = 0 ORDER BY id DESC LIMIT 1;")"
    log "节奏捕获增量：$PACED_DELTA（期望 $PACED）"
    if [ "$PACED_DELTA" -ne "$PACED" ]; then
        fail "节奏捕获增量异常，检查忽略规则/前台应用（前台可能命中忽略名单）"
    fi
    if [ "$NEWEST" != "$PACED_LAST" ]; then
        fail "最新条目不是最后一条节奏标记：$NEWEST"
    fi

    h1 "捕获风暴（50ms × $CAPTURE 条，验证 500ms 轮询合并）"
    BURST_BEFORE="$(db_count "$SCRATCH_DATA/history.db")"
    BURST_START="$(date +%s)"
    for i in $(seq 1 "$CAPTURE"); do
        printf 'CA-BURST-%s-%05d' "$RUN_ID" "$i" | pbcopy
        sleep 0.05
    done
    BURST_LAST="$(printf 'CA-BURST-%s-%05d' "$RUN_ID" "$CAPTURE")"
    sleep 2
    BURST_DURATION=$(( $(date +%s) - BURST_START ))
    BURST_MAX=$(( BURST_DURATION * 2 + 4 ))
    mem_checkpoint "捕获风暴后"
    quit_isolated
    AFTER="$(db_count "$SCRATCH_DATA/history.db")"
    BURST_DELTA=$((AFTER - BURST_BEFORE))
    NEWEST="$(sql_scalar "$SCRATCH_DATA/history.db" "SELECT text FROM clipboard_history WHERE entry_type = 0 ORDER BY id DESC LIMIT 1;")"
    log "风暴捕获增量：$BURST_DELTA（时长 ${BURST_DURATION}s，轮询上限约 $BURST_MAX）"
    if [ "$BURST_DELTA" -lt 1 ] || [ "$BURST_DELTA" -gt "$BURST_MAX" ]; then
        fail "风暴捕获增量超出 500ms 轮询上限：$BURST_DELTA（上限 $BURST_MAX）"
    fi
    if [ "$NEWEST" != "$BURST_LAST" ]; then
        fail "最新条目不是最后一条风暴标记：$NEWEST"
    fi
    run_invariants "$SCRATCH_DATA/history.db" rest || fail "捕获风暴后不变量检查失败"
else
    fail "Session B 启动失败"
fi

h1 "日志与崩溃"
PANICS="$(tail -c +$((RUN_LOG_OFFSET + 1)) "$LOG" 2>/dev/null | grep -c 'panic' || true)"
ERRORS="$(tail -c +$((RUN_LOG_OFFSET + 1)) "$LOG" 2>/dev/null | grep -c 'ERROR' || true)"
log "日志：panic=$PANICS ERROR=$ERRORS"
[ "$PANICS" -eq 0 ] || fail "日志出现 panic"
bash "$STRESS_ROOT/scripts/stress/crash_scan.sh" --since-epoch "$RUN_START_EPOCH" --report "$REPORT" || fail "指定窗口内存在崩溃报告"

h1 "产物"
log "运行目录：$RUN_DIR"
log "报告：$REPORT"

summary
