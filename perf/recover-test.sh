#!/bin/bash
# GUI recovery end-to-end test.
set -u
ROOT="$PWD"
APP="$ROOT/CopyAttach.app"
BIN="$APP/Contents/MacOS/CopyAttach"
LOG=/tmp/copyattach_debug.log
TESTDIR="$ROOT/.perf-recover-db"
REALDB="$HOME/Library/Application Support/CopyAttach/history.db"

echo "REAL_DB_BEFORE: size=$(stat -f%z "$REALDB") mtime=$(stat -f%m "$REALDB") perms=$(stat -f%p "$REALDB")"
pkill -f "$BIN" 2>/dev/null; sleep 2

rm -rf "$TESTDIR"; mkdir -p "$TESTDIR"
sqlite3 "$TESTDIR/history.db" "CREATE TABLE seed(x INTEGER);" >/dev/null 2>&1
chmod 444 "$TESTDIR/history.db"
echo "TEST_DB_READONLY: perms=$(stat -f%p "$TESTDIR/history.db")"

MARK=$(stat -f%z "$LOG" 2>/dev/null || echo 0)
echo "LOG_MARK=$MARK"
echo "=== launch (direct, env reaches process; real HOME kept) ==="
COPYATTACH_DATA_DIR="$TESTDIR" nohup "$BIN" >/dev/null 2>&1 &

for i in $(seq 1 20); do
  if tail -c +$((MARK+1)) "$LOG" | grep -aqE "unusable in this environment|failed to create"; then break; fi
  sleep 1
done
echo "--- phase 1: failure + backoff (waited ${i}s) ---"
tail -c +$((MARK+1)) "$LOG" | grep -aE "unusable in this environment|failed to create|retry in|failed attempt" | sed "s/.*+0800 //"

sleep 10
echo "--- phase 2: subsequent attempts ---"
tail -c +$((MARK+1)) "$LOG" | grep -aE "attempt [0-9]+" | sed "s/.*+0800 //"

echo "=== restoring write permission ==="
chmod 644 "$TESTDIR/history.db"
echo "TEST_DB_RESTORED: perms=$(stat -f%p "$TESTDIR/history.db")"

RECOVERED=0
for i in $(seq 1 90); do
  if tail -c +$((MARK+1)) "$LOG" | grep -aq "backoff reset"; then RECOVERED=1; break; fi
  sleep 1
done
echo "RECOVERED=$RECOVERED after ${i}s"
echo "--- full init/backoff timeline ---"
tail -c +$((MARK+1)) "$LOG" | grep -aE "unusable in this environment|failed to create|retry in|failed attempt|backoff reset|starting Rust" | sed "s/.*+0800 //"

if [ "$RECOVERED" = "1" ]; then
  printf "post-recovery-capture-%s" "$(date +%s)" | pbcopy
  sleep 2
  echo "db.write after recovery: $(tail -c +$((MARK+1)) "$LOG" | grep -ac "name=db.write")"
fi

echo "app alive: $(pgrep -f "$BIN" | wc -l | tr -d " ")"
pkill -f "$BIN" 2>/dev/null; sleep 1
rm -rf "$TESTDIR"
echo "REAL_DB_AFTER: size=$(stat -f%z "$REALDB") mtime=$(stat -f%m "$REALDB") perms=$(stat -f%p "$REALDB")"
echo "DONE"