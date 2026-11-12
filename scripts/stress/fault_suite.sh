#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SKIP_DISK=0
DB="${DB:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --db) DB="$2"; shift 2 ;;
        --skip-disk) SKIP_DISK=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

MOUNT_DIR=""
RAM_DEV=""

fault_cleanup() {
    if [ -n "$MOUNT_DIR" ]; then
        umount "$MOUNT_DIR" 2>/dev/null || true
        MOUNT_DIR=""
    fi
    if [ -n "$RAM_DEV" ]; then
        hdiutil detach "$RAM_DEV" >/dev/null 2>&1 || true
        RAM_DEV=""
    fi
    cleanup_all
}

trap fault_cleanup EXIT INT TERM

report_header
RUN_START_EPOCH="$(date +%s)"
RUN_LOG_OFFSET="$(log_size)"
WAS_RUNNING=0
if [ -n "$(app_pid)" ]; then WAS_RUNNING=1; fi
save_clipboard_text

backup_real_db || fail "真实库备份失败"
if [ -z "$DB" ]; then
    DB="$RUN_DIR/dataset.db"
    cargo build --release --features stress-test --bin stress-gen >>"$REPORT" 2>&1
    "$STRESS_ROOT/target/release/stress-gen" --count 300 --text-ratio 0.5 --seed 31 \
        --db-path "$DB" --threshold "$(app_threshold)" --report >>"$REPORT" 2>&1
fi

launch_raw() {
    quit_app
    local offset
    offset="$(log_size)"
    COPYATTACH_DATA_DIR="$SCRATCH_DATA" COPYATTACH_PERF=1 "$BIN" >>"$LOG" 2>&1 &
    ISOLATED_PID=$!
    LAUNCH_LOG_OFFSET="$offset"
}

h1 "S6.1 只读数据库：显式失败 + 自动恢复"
copy_db_into_scratch "$DB"
chmod 444 "$SCRATCH_DATA/history.db"
chmod 555 "$SCRATCH_DATA"
launch_raw
if wait_log_line "$LAUNCH_LOG_OFFSET" "unusable in this environment (attempt 1)" 20; then
    log "只读库被显式拒绝，进入退避（进程 $ISOLATED_PID 存活）"
else
    fail "只读库未产生明确的不可用日志"
fi
if kill -0 "$ISOLATED_PID" 2>/dev/null; then
    log "只读故障下进程存活"
else
    fail "只读故障下进程退出"
fi
chmod 755 "$SCRATCH_DATA"
chmod 644 "$SCRATCH_DATA/history.db"
if wait_log_line "$LAUNCH_LOG_OFFSET" "backoff reset" 90; then
    log "恢复写权限后自动恢复（backoff reset）"
else
    fail "恢复写权限后未自动恢复"
fi
printf 'CA-FAULT-RO-%s' "$RUN_ID" | pbcopy
sleep 1.5
NEWEST="$(sql_scalar "$SCRATCH_DATA/history.db" "SELECT text FROM clipboard_history WHERE entry_type = 0 ORDER BY id DESC LIMIT 1;")"
if [ "$NEWEST" = "CA-FAULT-RO-$RUN_ID" ]; then
    log "恢复后捕获落库"
else
    fail "恢复后捕获未落库：$NEWEST"
fi
quit_isolated
run_invariants "$SCRATCH_DATA/history.db" rest || fail "只读恢复后不变量失败"

h1 "S6.2 损坏数据库：弹窗 + 备份并重建"
copy_db_into_scratch "$DB"
python3 - "$SCRATCH_DATA/history.db" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r+b") as fh:
    fh.seek(0)
    fh.write(b"not a sqlite database" * 512)
PY
launch_raw
if wait_log_line "$LAUNCH_LOG_OFFSET" "database is not usable, init aborted" 20; then
    log "损坏库被识别为 corrupt"
else
    fail "损坏库未被识别为 corrupt"
fi
REBUILT=0
PID="$ISOLATED_PID"
SESSION="fault_$PID"
WID=""
TOKEN=""
for _ in $(seq 1 30); do
    for W in $(cua-driver call list_windows "{\"pid\":$PID}" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in d.get("windows",[]):
    print(w["window_id"])
' || true); do
        T="$(cua-driver call get_window_state "{\"pid\":$PID,\"window_id\":$W,\"query\":\"备份并重建\",\"tree_format\":\"elements\",\"include_screenshot\":false,\"session\":\"$SESSION\"}" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for e in d.get("elements",[]):
    blob=" ".join(str(e.get(k,"")) for k in ("label","value","title","description"))
    if "备份并重建" in blob:
        print(e["element_token"]); break
' || true)"
        if [ -n "$T" ]; then
            WID="$W"
            TOKEN="$T"
            break 2
        fi
    done
    [ -n "$TOKEN" ] && break
    sleep 0.3
done
if [ -z "$WID" ]; then
    fail "损坏库弹窗未出现或找不到「备份并重建」"
else
    set +e
    cua-driver call click "{\"target\":{\"kind\":\"window\",\"pid\":$PID,\"window_id\":$WID},\"element_token\":\"$TOKEN\",\"session\":\"$SESSION\"}" >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        fail "点击「备份并重建」失败 rc=$rc"
    elif wait_log_line "$LAUNCH_LOG_OFFSET" "Initialization complete" 30; then
        REBUILT=1
        log "重建后初始化完成"
    else
        fail "重建后初始化超时"
    fi
fi
CORRUPT_FILE="$(ls "$SCRATCH_DATA"/history.db.corrupt-* 2>/dev/null | head -1 || true)"
if [ -n "$CORRUPT_FILE" ]; then
    log "损坏文件已保留：$(basename "$CORRUPT_FILE")"
else
    fail "损坏文件未被保留"
fi
quit_isolated
if [ "$REBUILT" -eq 1 ]; then
    run_invariants "$SCRATCH_DATA/history.db" rest || fail "重建后不变量失败"
fi

h1 "S6.3 磁盘写满（RAM 盘）"
if [ "$SKIP_DISK" -eq 1 ]; then
    log "SKIP 按参数跳过"
else
    set +e
    RAM_DEV="$(hdiutil attach -nomount ram://65536 2>/dev/null | awk '{print $1}')"
    if [ -z "$RAM_DEV" ]; then
        set -e
        warn "SKIP 无法创建 RAM 盘（hdiutil）"
    else
        newfs_hfs -v "CAFault" "$RAM_DEV" >/dev/null 2>&1
        MOUNT_DIR="$RUN_DIR/ram"
        mkdir -p "$MOUNT_DIR"
        mount -t hfs "$RAM_DEV" "$MOUNT_DIR" 2>/dev/null
        set -e
        if ! touch "$MOUNT_DIR/.probe" 2>/dev/null; then
            warn "SKIP RAM 盘挂载失败"
        else
            SCRATCH_DATA="$MOUNT_DIR/data"
            mkdir -p "$SCRATCH_DATA"
            copy_db_into_scratch "$DB"
            launch_raw
            wait_migration_if_needed
            dd if=/dev/zero of="$MOUNT_DIR/fill" bs=1m 2>/dev/null || true
            for i in $(seq 1 10); do
                printf 'CA-FAULT-ENOSPC-%s-%02d' "$RUN_ID" "$i" | pbcopy
                sleep 0.7
            done
            if kill -0 "$ISOLATED_PID" 2>/dev/null; then
                log "磁盘写满期间进程存活"
            else
                fail "磁盘写满导致进程退出"
            fi
            rm -f "$MOUNT_DIR/fill"
            BEFORE5="$(db_count "$SCRATCH_DATA/history.db")"
            printf 'CA-FAULT-AFTER-FREE-%s' "$RUN_ID" | pbcopy
            sleep 1.5
            AFTER5="$(db_count "$SCRATCH_DATA/history.db")"
            if [ "$AFTER5" -gt "$BEFORE5" ]; then
                log "释放空间后捕获恢复（$BEFORE5 → $AFTER5）"
            else
                fail "释放空间后捕获未恢复（$BEFORE5 → $AFTER5）"
            fi
            quit_isolated
            run_invariants "$SCRATCH_DATA/history.db" rest || fail "磁盘写满后不变量失败"
            umount "$MOUNT_DIR" 2>/dev/null || true
            MOUNT_DIR=""
            hdiutil detach "$RAM_DEV" >/dev/null 2>&1 || true
            RAM_DEV=""
        fi
    fi
fi

h1 "S6.4 未能自动化的项（人工清单）"
log "更新链路：GitHub 不可达 / 蓝奏云不可达 / 下载中断 / 截断 DMG / 篡改包 / 替换失败"
log "已知失败项：蓝奏云回退路径仅做魔数校验，无签名验证"
log "人工：睡眠唤醒、多显示器不同缩放、无辅助功能权限、secure input、输入法切换、外接键盘小键盘"

h1 "日志与崩溃"
PANICS="$(tail -c +$((RUN_LOG_OFFSET + 1)) "$LOG" 2>/dev/null | grep -c 'panic' || true)"
log "日志：panic=$PANICS"
[ "$PANICS" -eq 0 ] || fail "日志出现 panic"
bash "$STRESS_ROOT/scripts/stress/crash_scan.sh" --since-epoch "$RUN_START_EPOCH" --report "$REPORT" || fail "指定窗口内存在崩溃报告"
log "报告：$REPORT"
summary
