#!/bin/bash
# CopyAttach perf-session collector.
#
# Drives one measurement session against the instrumented build and prints the
# session window the analyzer needs. Deliberately thin: it isolates a session
# (log offset + wall-clock window), launches the app with tracing enabled, and
# proves the trace is live before returning. It does NOT synthesize complex
# input; the person (or CI) performing the interaction drives that, and the
# analyzer reads whatever landed in the window.
#
# Usage:
#   perf/collect.sh launch                 # (re)start app with tracing on
#   perf/collect.sh quit                   # stop the app
#   perf/collect.sh begin                  # print session start wall-ms
#   perf/collect.sh analyze [start_ms]     # run the analyzer over the window
#   perf/collect.sh toggle                 # open/close popup via the real reopen path
#   perf/collect.sh smoke [n]              # toggle the popup n times (default 5)
#
# Environment:
#   APP       path to the .app (default ./CopyAttach.app)
#   LOG       trace log path (default /tmp/copyattach_debug.log)
#
# NOTE: launching the app writes to ~/Library/Application Support/CopyAttach,
# so this must run with access to it (the app itself is not sandboxed; only a
# restricted launcher would be). Never override HOME (keychain access breaks).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$ROOT/CopyAttach.app}"
LOG="${LOG:-/tmp/copyattach_debug.log}"
BIN="$APP/Contents/MacOS/CopyAttach"

wall_ms() { python3 -c "import time;print(int(time.time()*1000))"; }

# Wait for a self-check verdict record emitted by a SPECIFIC pid, so a stale
# verdict from a previous session can never be mistaken for this one.
wait_for_verdict() {
    local want_pid="$1"
    local deadline=$(( $(date +%s) + 25 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local rec
        rec=$(grep -a "pid=$want_pid " "$LOG" 2>/dev/null | grep "name=verdict" | tail -1 || true)
        if [ -n "$rec" ]; then
            echo "self-check record (pid=$want_pid): $rec"
            if echo "$rec" | grep -q "val=1"; then
                echo "instrument self-check: PASS"
                return 0
            fi
            echo "instrument self-check: FAIL" >&2
            return 3
        fi
        sleep 0.25
    done
    echo "timed out waiting for self-check verdict from pid=$want_pid" >&2
    return 4
}

cmd_launch() {
    if pgrep -f "$BIN" >/dev/null 2>&1; then
        echo "app already running; use quit first" >&2
        exit 1
    fi
    [ -x "$BIN" ] || { echo "missing binary: $BIN" >&2; exit 1; }
    # Also persist the preference: the self-healing single-instance path (and
    # any later `open`) re-reads it, whereas a direct-launch env var lives only
    # in that one process. HOME is left untouched (keychain!).
    defaults write com.example.copyattach PerfTracing -bool true
    # Launch the binary directly so it inherits COPYATTACH_PERF; `open` does not
    # forward the shell environment.
    COPYATTACH_PERF=1 nohup "$BIN" >/dev/null 2>&1 &
    local pid=$!
    echo "launched pid $pid"
    sleep 0.5
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "process exited immediately (duplicate instance or crash)" >&2
        exit 5
    fi
    wait_for_verdict "$pid"
}

cmd_quit() {
    pkill -f "$BIN" 2>/dev/null || true
    sleep 1
    echo "stopped"
}

cmd_begin() { echo "$(wall_ms)"; }

cmd_toggle() {
    # Re-opening the running app fires applicationShouldHandleReopen -> the real
    # togglePopup() path. No synthetic key events, no extra code path.
    open "$APP"
}

cmd_smoke() {
    local n="${1:-5}"
    local i=0
    while [ "$i" -lt "$n" ]; do
        open "$APP"
        sleep 1.2
        i=$((i + 1))
    done
    echo "completed $n popup toggles"
}

cmd_analyze() {
    local start="${1:-0}"
    python3 "$ROOT/perf/analyze.py" "$LOG" --session-start "$start"
}

case "${1:-}" in
    launch) cmd_launch ;;
    quit) cmd_quit ;;
    begin) cmd_begin ;;
    toggle) cmd_toggle ;;
    smoke) shift; cmd_smoke "$@" ;;
    analyze) shift; cmd_analyze "$@" ;;
    *) sed -n "2,22p" "$0"; exit 1 ;;
esac
