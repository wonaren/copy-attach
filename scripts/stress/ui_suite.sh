#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DB=""
ROUNDS=5

while [ $# -gt 0 ]; do
    case "$1" in
        --db) DB="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$DB" ]; then
    DB="$RUN_DIR/dataset.db"
    cargo build --release --features stress-test --bin stress-gen >>"$REPORT" 2>&1
    "$STRESS_ROOT/target/release/stress-gen" --count 300 --text-ratio 0.5 --seed 11 \
        --db-path "$DB" --threshold "$(app_threshold)" --report >>"$REPORT" 2>&1
fi

trap cleanup_all EXIT INT TERM
report_header
RUN_START_EPOCH="$(date +%s)"
WAS_RUNNING=0
if [ -n "$(app_pid)" ]; then WAS_RUNNING=1; fi
save_clipboard_text

copy_db_into_scratch "$DB"
launch_isolated
wait_migration_if_needed

PID="$ISOLATED_PID"
SESSION="stress_$PID"
DBF="$SCRATCH_DATA/history.db"

cua() { cua-driver call "$@" 2>&1; }

window_ids() {
    cua list_windows "{\"pid\":$PID}" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in d.get("windows",[]):
    if w.get("is_on_screen"):
        print(w["window_id"])
'
}

popup_id() {
    cua list_windows "{\"pid\":$PID}" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in d.get("windows",[]):
    if w.get("is_on_screen") and abs(w["bounds"]["width"]-500)<2 and abs(w["bounds"]["height"]-720)<20:
        print(w["window_id"]); break
'
}

wait_popup() {
    local deadline=$((SECONDS + 6))
    while [ "$SECONDS" -lt "$deadline" ]; do
        WID="$(popup_id)"
        [ -n "$WID" ] && return 0
        sleep 0.2
    done
    return 1
}

wait_popup_closed() {
    local deadline=$((SECONDS + 6))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ -z "$(popup_id)" ] && return 0
        sleep 0.2
    done
    return 1
}

preview_open() {
    cua list_windows "{\"pid\":$PID}" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in d.get("windows",[]):
    if w.get("is_on_screen") and w["bounds"]["width"] > 1000:
        print(w["window_id"]); break
'
}

ensure_open() {
    if [ -z "$(popup_id)" ]; then
        sleep 0.4
        open "$APP"
    fi
    wait_popup || fail "弹窗未打开"
}

ensure_closed() {
    local i
    for i in 1 2 3; do
        [ -z "$(popup_id)" ] && return 0
        set +e
        cua press_key "{\"target\":{\"kind\":\"window\",\"pid\":$PID,\"window_id\":$WID},\"key\":\"escape\",\"delivery_mode\":\"foreground\",\"session\":\"$SESSION\"}" >/dev/null 2>&1
        set -e
        sleep 0.5
    done
    [ -z "$(popup_id)" ]
}

snapshot_markdown() {
    cua get_window_state "{\"pid\":$PID,\"window_id\":$WID,\"tree_format\":\"markdown\",\"include_screenshot\":false,\"session\":\"$SESSION\"}"
}

search_token() {
    cua get_window_state "{\"pid\":$PID,\"window_id\":$WID,\"tree_format\":\"elements\",\"include_screenshot\":false,\"session\":\"$SESSION\"}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for e in d.get("elements",[]):
    if e.get("role")=="AXTextField":
        print(e["element_token"]); break
'
}

cua_action() {
    local label="$1"; shift
    local out rc
    set +e
    out="$("$@" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        fail "$label 调用失败 rc=$rc: $(echo "$out" | python3 -c 'import sys;print(" ".join(sys.stdin.read().split())[:300])')"
    fi
    return 0
}

hotkey() {
    local keys="$1"
    cua_action "hotkey $keys" cua hotkey "{\"target\":{\"kind\":\"window\",\"pid\":$PID,\"window_id\":$WID},\"keys\":$keys,\"delivery_mode\":\"foreground\",\"session\":\"$SESSION\"}"
}

press() {
    cua_action "press $1" cua press_key "{\"target\":{\"kind\":\"window\",\"pid\":$PID,\"window_id\":$WID},\"key\":\"$1\",\"delivery_mode\":\"foreground\",\"session\":\"$SESSION\"}"
}

db_count_live() {
    sql_scalar "$DBF" "SELECT COUNT(*) FROM clipboard_history h WHERE NOT EXISTS (SELECT 1 FROM clipboard_deleted d WHERE d.row_id=h.id);"
}

db_count_deleted() {
    sql_scalar "$DBF" "SELECT COUNT(*) FROM clipboard_deleted;"
}

top_entry_id() {
    sql_scalar "$DBF" "SELECT entry_id FROM clipboard_history h WHERE NOT EXISTS (SELECT 1 FROM clipboard_deleted d WHERE d.row_id=h.id) ORDER BY timestamp DESC, id DESC LIMIT 1;"
}

favorite_state() {
    sql_scalar "$DBF" "SELECT COUNT(*) FROM clipboard_favorites WHERE entry_id=$1;"
}

for round in $(seq 1 "$ROUNDS"); do
    h1 "UI round $round"
    ensure_open
    WID="$(popup_id)"
    if [ -z "$WID" ]; then
        fail "弹窗 window_id 缺失"
        continue
    fi

    TOKEN="$(search_token)"
    if [ -z "$TOKEN" ]; then
        fail "找不到搜索框"
    else
        cua_action "type_text" cua type_text "{\"element_token\":\"$TOKEN\",\"text\":\"zzz\",\"delivery_mode\":\"foreground\",\"session\":\"$SESSION\"}"
        sleep 0.6
        if snapshot_markdown | grep -q "无匹配结果"; then
            log "搜索无结果状态正确"
        else
            fail "搜索未进入无匹配结果状态"
        fi
        press escape
        sleep 0.6
        if [ -z "$(popup_id)" ]; then
            log "Esc 关闭弹窗"
        else
            fail "Esc 未关闭弹窗"
        fi
    fi
    ensure_open
    WID="$(popup_id)"

    TOP="$(top_entry_id)"
    BEFORE_FAV="$(favorite_state "$TOP")"
    hotkey '["option","p"]'
    sleep 0.5
    AFTER_FAV="$(favorite_state "$TOP")"
    if [ "$BEFORE_FAV" != "$AFTER_FAV" ]; then
        log "收藏切换生效（entry_id=$TOP $BEFORE_FAV→$AFTER_FAV）"
    else
        fail "收藏未切换（entry_id=$TOP）"
    fi

    LIVE="$(db_count_live)"
    DELETED="$(db_count_deleted)"
    hotkey '["ctrl","backspace"]'
    sleep 0.6
    LIVE2="$(db_count_live)"
    DELETED2="$(db_count_deleted)"
    if [ "$LIVE2" -eq $((LIVE - 1)) ] && [ "$DELETED2" -eq $((DELETED + 1)) ]; then
        log "删除生效（live $LIVE→$LIVE2）"
    else
        fail "删除未生效（live $LIVE→$LIVE2 deleted $DELETED→$DELETED2）"
    fi
    hotkey '["cmd","z"]'
    sleep 0.6
    LIVE3="$(db_count_live)"
    DELETED3="$(db_count_deleted)"
    if [ "$LIVE3" -eq "$LIVE" ] && [ "$DELETED3" -eq "$DELETED" ]; then
        log "撤销生效（live 恢复 $LIVE3）"
    else
        fail "撤销未恢复（live $LIVE3 deleted $DELETED3）"
    fi

    press space
    sleep 0.8
    if [ -n "$(preview_open)" ]; then
        log "Space 打开预览"
    else
        fail "Space 未打开预览"
    fi
    press escape
    sleep 0.6
    if [ -z "$(preview_open)" ]; then
        log "Esc 关闭预览"
    else
        fail "Esc 未关闭预览"
    fi

    press down
    sleep 0.3
    hotkey '["cmd","c"]'
    sleep 0.5
    if snapshot_markdown | grep -q "已选"; then
        log "⌘C 进入队列模式"
    else
        fail "⌘C 未进入队列模式"
    fi
    press escape
    sleep 0.5
    ensure_closed || fail "轮次结束时弹窗未关闭"
done

h1 "汇总"
mem_checkpoint "UI 轮次后"
quit_isolated
run_invariants "$DBF" rest || fail "UI 操作后不变量检查失败"
bash "$STRESS_ROOT/scripts/stress/crash_scan.sh" --since-epoch "$RUN_START_EPOCH" --report "$REPORT" || fail "指定窗口内存在崩溃报告"
log "报告：$REPORT"
summary
