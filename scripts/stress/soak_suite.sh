#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

HOURS=8
INTERVAL=300
OPS=4
RESTART_EVERY=7200
DB="${DB:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --hours) HOURS="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --ops) OPS="$2"; shift 2 ;;
        --restart-every) RESTART_EVERY="$2"; shift 2 ;;
        --db) DB="$2"; shift 2 ;;
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

DURATION="$(python3 -c "print(max(1, int(float('$HOURS') * 3600)))")"
DEADLINE=$((RUN_START_EPOCH + DURATION))

backup_real_db || fail "真实库备份失败"
if [ -z "$DB" ]; then
    DB="$RUN_DIR/dataset.db"
    cargo build --release --features stress-test --bin stress-gen >>"$REPORT" 2>&1
    "$STRESS_ROOT/target/release/stress-gen" --count 1000 --text-ratio 0.6 --seed 51 \
        --db-path "$DB" --threshold "$(app_threshold)" --report >>"$REPORT" 2>&1
fi

copy_db_into_scratch "$DB"
launch_isolated
wait_migration_if_needed

MEM_CSV="$RUN_DIR/mem.csv"
: > "$MEM_CSV"
mem_row() {
    local label="$1"
    local line written resident
    line="$(vmmap_writable "$ISOLATED_PID")"
    written="$(echo "$line" | sed -n 's/.*written=\([0-9.]*[KMGT]\).*/\1/p')"
    resident="$(echo "$line" | sed -n 's/.*resident=\([0-9.]*[KMGT]\).*/\1/p')"
    echo "$(date +%s),$written,$resident" >> "$MEM_CSV"
    {
        echo "### $label"
        echo '```'
        echo "$line"
        echo "threads=$(ps -o thcount= -p "$ISOLATED_PID" 2>/dev/null | tr -d ' ')"
        echo "fds=$(lsof -p "$ISOLATED_PID" 2>/dev/null | wc -l | tr -d ' ')"
        echo "rss=$(ps -o rss= -p "$ISOLATED_PID" 2>/dev/null | tr -d ' ')"
        echo "cpu=$(ps -o %cpu= -p "$ISOLATED_PID" 2>/dev/null | tr -d ' ')"
        echo '```'
    } >> "$REPORT"
    log "内存 $label：$line"
}

h1 "S7 长跑：$(printf '%.2f' "$HOURS") 小时，间隔 ${INTERVAL}s，开合 ${OPS} 次/轮，重启间隔 ${RESTART_EVERY}s"
mem_row "启动"
CYCLE=0
NEXT_MEM=$((RUN_START_EPOCH + 3600))
NEXT_RESTART=$((RUN_START_EPOCH + RESTART_EVERY))

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    CYCLE=$((CYCLE + 1))
    if ! kill -0 "$ISOLATED_PID" 2>/dev/null; then
        fail "第 $CYCLE 轮前隔离实例已退出"
        break
    fi

    for i in $(seq 1 5); do
        printf 'CA-SOAK-%s-%05d-%02d' "$RUN_ID" "$CYCLE" "$i" | pbcopy
        sleep 0.7
    done

    if [ "$OPS" -gt 0 ]; then
        for _ in $(seq 1 "$OPS"); do
            open "$APP"
            sleep 1.2
        done
    fi

    NOW="$(date +%s)"
    ROWS="$(db_count "$SCRATCH_DATA/history.db")"
    log "轮次 $CYCLE：rows=$ROWS remaining=$((DEADLINE - NOW))s"

    if [ "$NOW" -ge "$NEXT_MEM" ]; then
        mem_row "第 $(( (NOW - RUN_START_EPOCH) / 3600 ))h"
        SNAP="$RUN_DIR/soak_snapshot.db"
        rm -f "$SNAP"
        sqlite3 "$SCRATCH_DATA/history.db" ".backup '$SNAP'"
        run_invariants "$SNAP" rest || fail "第 $CYCLE 轮不变量失败"
        NEXT_MEM=$((NOW + 3600))
    fi

    if [ "$RESTART_EVERY" -gt 0 ] && [ "$NOW" -ge "$NEXT_RESTART" ]; then
        h1 "重启持久化检查（第 $CYCLE 轮）"
        ROWS_BEFORE_RESTART="$(db_count "$SCRATCH_DATA/history.db")"
        quit_isolated
        launch_isolated
        wait_migration_if_needed
        ROWS_AFTER_RESTART="$(db_count "$SCRATCH_DATA/history.db")"
        log "重启前后行数：$ROWS_BEFORE_RESTART → $ROWS_AFTER_RESTART"
        if [ "$ROWS_AFTER_RESTART" -lt "$ROWS_BEFORE_RESTART" ]; then
            fail "重启后行数减少"
        fi
        NEXT_RESTART=$((NOW + RESTART_EVERY))
    fi

    REMAINING=$((DEADLINE - $(date +%s)))
    [ "$REMAINING" -gt 0 ] || break
    [ "$REMAINING" -lt "$INTERVAL" ] && SLEEP_FOR="$REMAINING" || SLEEP_FOR="$INTERVAL"
    sleep "$SLEEP_FOR"
done

h1 "收尾"
mem_row "结束"
quit_isolated
run_invariants "$SCRATCH_DATA/history.db" rest || fail "长跑结束不变量失败"

python3 - "$MEM_CSV" "$REPORT" <<'PY'
import re, sys
path, report = sys.argv[1], sys.argv[2]
def kb(v):
    m = re.match(r"([0-9.]+)([KMGT]?)", v)
    if not m: return 0
    n = float(m.group(1)); u = m.group(2)
    return int(n * {"": 1/1024, "K": 1, "M": 1024, "G": 1024*1024, "T": 1024**3}[u])
rows = []
for line in open(path):
    parts = line.strip().split(",")
    if len(parts) == 3:
        rows.append((int(parts[0]), parts[1], parts[2]))
lines = ["", "### 内存趋势", ""]
if len(rows) >= 2:
    base = rows[1] if len(rows) >= 3 else rows[0]
    w = kb(rows[-1][1]) - kb(base[1])
    r = kb(rows[-1][2]) - kb(base[2])
    lines.append(f"- 基线 written={base[1]} resident={base[2]}")
    lines.append(f"- 结束 written={rows[-1][1]} resident={rows[-1][2]}")
    lines.append(f"- 变化 written={w/1024:.1f}MB resident={r/1024:.1f}MB")
    lines.append(f"- 判定 {'PASS' if w <= 8192 and r <= 8192 else 'FAIL'}（阈值 8MB）")
else:
    lines.append("- 检查点不足，无法判定")
text = "\n".join(lines) + "\n"
print(text)
open(report, "a").write(text)
PY
if grep -q '判定 FAIL' "$REPORT"; then
    fail "长跑内存趋势超出阈值"
fi

TAIL="$RUN_DIR/log_tail.txt"
tail -c +$((RUN_LOG_OFFSET + 1)) "$LOG" 2>/dev/null > "$TAIL" || true
PANICS="$(grep -c 'panic' "$TAIL" || true)"
ERRORS="$(grep -c 'ERROR' "$TAIL" || true)"
FAILEDS="$(grep -c 'failed' "$TAIL" || true)"
TAPDISABLED="$(grep -ic 'tap.*disabled\|tap.*timeout' "$TAIL" || true)"
log "日志：panic=$PANICS ERROR=$ERRORS failed=$FAILEDS tap_disabled=$TAPDISABLED"
[ "$PANICS" -eq 0 ] || fail "日志出现 panic"
bash "$STRESS_ROOT/scripts/stress/crash_scan.sh" --since-epoch "$RUN_START_EPOCH" --report "$REPORT" || fail "指定窗口内存在崩溃报告"
log "报告：$REPORT"
summary
