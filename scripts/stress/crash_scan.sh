#!/bin/bash
set -euo pipefail

HOURS=24
SINCE_EPOCH=""
REPORT=""
FAIL_ON_FOUND=1

while [ $# -gt 0 ]; do
    case "$1" in
        --since-epoch) SINCE_EPOCH="$2"; shift 2 ;;
        --hours) HOURS="$2"; shift 2 ;;
        --report) REPORT="$2"; shift 2 ;;
        --no-fail) FAIL_ON_FOUND=0; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$SINCE_EPOCH" ]; then
    SINCE_EPOCH=$(( $(date +%s) - HOURS * 3600 ))
fi

python3 - "$SINCE_EPOCH" "$REPORT" "$FAIL_ON_FOUND" <<'PY'
import glob
import json
import os
import sys

since = int(sys.argv[1])
report = sys.argv[2] or None
fail_on_found = sys.argv[3] == "1"
reports = sorted(glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/CopyAttach-*.ips")))

found = []
for path in reports:
    if os.path.getmtime(path) < since:
        continue
    try:
        with open(path) as fh:
            header = json.loads(fh.readline())
            payload = json.load(fh)
        t = payload.get("threads", [])
        index = payload.get("faultingThread", -1)
        thread = t[index] if 0 <= index < len(t) else {}
        frames = thread.get("frames", [])
        top = " <- ".join(str(f.get("symbol") or f.get("imageOffset", "?")) for f in frames[:5])
        found.append({
            "file": path,
            "time": payload.get("captureTime") or header.get("timestamp"),
            "pid": payload.get("pid"),
            "launch": payload.get("procLaunch"),
            "exception": payload.get("exception", {}).get("type"),
            "signal": payload.get("exception", {}).get("signal"),
            "thread": thread.get("name") or thread.get("queue"),
            "top": top,
        })
    except Exception as exc:
        found.append({"file": path, "error": str(exc)})

lines = ["", "### Crash reports", ""]
if not found:
    lines.append("PASS 指定窗口内无 CopyAttach 崩溃报告")
else:
    for item in found:
        if "error" in item:
            lines.append(f"- PARSE-ERROR {item['file']}: {item['error']}")
        else:
            lines.append(
                f"- CRASH {item['time']} pid={item['pid']} launch={item['launch']} "
                f"{item['exception']}/{item['signal']} thread={item['thread']}"
            )
            lines.append(f"  - {item['top']}")
            lines.append(f"  - {item['file']}")

text = "\n".join(lines) + "\n"
print(text)
if report:
    with open(report, "a") as fh:
        fh.write(text)

sys.exit(1 if (found and fail_on_found) else 0)
PY
