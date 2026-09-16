#!/usr/bin/env python3
"""Analyzer for CopyAttach perf traces (the __CA_PERF__ channel).

Reads a raw log, validates the instrument, computes latency distributions, and
prints a markdown report. Stdlib only.

Two views of the same file:
  * validation view  - everything in the log for the dominant pid. The
    instrument's self-check, probes, and overhead sample happen once at launch,
    so they must NOT be dropped by an interaction-session filter.
  * measurement view - only records at/after --session-start. A measurement
    session is one interaction window; mixing sessions would blend populations.

Validation gates (fail loudly; exit 2 if any fails without --no-strict):
  G1  self-check verdict present and passing
  G2  both probe writers reach the file (Swift and Rust)
  G3  the unconditional self-check overhead is bounded
  G4  the monotonic clock tracks wall clock (slope ~1, high R^2)
  G5  every record parses against the declared format version
  G6  Rust and Swift stamps share one clock domain (cross-language alignment)
  G7  the enabled hot path's measured formatting cost is bounded
"""

import argparse
import json
import math
import re
import sys
from collections import defaultdict

MAGIC = "__CA_PERF__"
SUPPORTED_VERSIONS = {1}

# Values must not swallow the line's trailing newline.
KEY_RE = re.compile(r"([a-z_]+)=([^ \n]*)")

# A record must contain exactly one magic token and start with it. Anything else
# is a torn/interleaved append (two writers racing on the same file) which would
# otherwise be silently mis-parsed into plausible-looking numbers.
MAGIC_COUNT_RE = re.compile(MAGIC)

# Duration spans we report on, in report order.
SPAN_ORDER = [
    ("swift", "popup.show"),
    ("swift", "popup.visible_setup"),
    ("swift", "popup.reload"),
    ("swift", "snapshot.decode"),
    ("swift", "search.end_to_end"),
    ("swift", "search.filter"),
    ("swift", "thumb.decode_total"),
    ("swift", "thumb.ffi_read"),
    ("swift", "thumb.imageio"),
    ("swift", "preview.open"),
    ("swift", "preview.load_full_text"),
    ("swift", "paste.menu_to_keystroke"),
    ("swift", "drag.materialize"),
    ("swift", "undo.perform"),
    ("swift", "popup.close"),
    ("rust", "snapshot.pack"),
    ("rust", "search.query"),
    ("rust", "thumb.load_db"),
    ("rust", "db.write"),
    ("rust", "paste.prepare"),
    ("rust", "paste.load_text"),
    ("rust", "paste.load_image_blobs"),
    ("rust", "paste.write_temp_png"),
    ("rust", "preview.decode"),
    ("rust", "image.thumbnail_phase1"),
    ("rust", "image.encode_png"),
]


def torn(line):
    """True when a line is not exactly one record starting at column 0."""
    n = len(MAGIC_COUNT_RE.findall(line))
    if n == 0:
        return False
    return n > 1 or not line.startswith(MAGIC)


def parse_line(line):
    idx = line.find(MAGIC)
    if idx < 0:
        return None
    body = line[idx + len(MAGIC):]
    rec = {}
    for key, val in KEY_RE.findall(body):
        rec[key] = val
    if "v" not in rec or "kind" not in rec or "cat" not in rec or "name" not in rec:
        return None
    return rec


def load(path, session_byte=0):
    """Parse the log.

    Torn lines before session_byte are historical (written by a build that had
    the non-atomic append defect); they are counted separately so a clean
    measurement window is not invalidated by an old, already-fixed fault. Torn
    lines inside the window always fail the parse gate.
    """
    records = []
    malformed = 0
    torn_lines = 0
    torn_historical = 0
    total_lines = 0
    offset = 0
    with open(path, "rb") as fh:
        for raw in fh:
            line_offset = offset
            offset += len(raw)
            total_lines += 1
            line = raw.decode("utf-8", errors="replace")
            if MAGIC not in line:
                continue
            if torn(line):
                if line_offset < session_byte:
                    torn_historical += 1
                else:
                    torn_lines += 1
                    malformed += 1
                continue
            rec = parse_line(line)
            if rec is None:
                malformed += 1
                continue
            try:
                rec["v"] = int(rec["v"])
                rec["pid"] = int(rec["pid"])
                rec["t"] = int(rec["t"])
                rec["wall"] = int(rec["wall"])
                rec["tid"] = int(rec["tid"], 16)
                rec["dur_us"] = int(rec["dur_us"]) if "dur_us" in rec else None
                rec["val"] = int(rec["val"]) if "val" in rec else None
            except (ValueError, KeyError):
                malformed += 1
                continue
            records.append(rec)
    return records, malformed, total_lines, torn_lines, torn_historical


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    if len(sorted_vals) == 1:
        return float(sorted_vals[0])
    k = (len(sorted_vals) - 1) * (p / 100.0)
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return float(sorted_vals[int(k)])
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def summarize(values):
    vals = sorted(values)
    if not vals:
        return {"n": 0, "p50": None, "p95": None, "p99": None, "max": None, "mean": None}
    return {
        "n": len(vals),
        "p50": pct(vals, 50),
        "p95": pct(vals, 95),
        "p99": pct(vals, 99),
        "max": float(vals[-1]),
        "mean": sum(vals) / len(vals),
    }


def chain_latencies(records, start_name, end_name):
    """Pair each start marker with the next end marker after it, per pid."""
    by_pid = defaultdict(list)
    for r in records:
        by_pid[r["pid"]].append(r)
    out = []
    for recs in by_pid.values():
        pending = None
        for r in sorted(recs, key=lambda r: r["t"]):
            if r["name"] == start_name:
                pending = r["t"]
            elif r["name"] == end_name and pending is not None:
                out.append((r["t"] - pending) / 1000.0)  # ns -> us
                pending = None
    return out


def clock_gate(records, pid):
    recs = sorted((r for r in records if r["pid"] == pid), key=lambda r: r["t"])
    if len(recs) < 10:
        return None
    ts = [r["t"] for r in recs]
    ws = [r["wall"] for r in recs]
    n = len(ts)
    mt = sum(ts) / n
    mw = sum(ws) / n
    cov = sum((ts[i] - mt) * (ws[i] - mw) for i in range(n))
    vart = sum((t - mt) ** 2 for t in ts)
    varw = sum((w - mw) ** 2 for w in ws)
    if vart == 0 or varw == 0:
        return None
    slope = cov / vart  # wall_ms per t_ns
    r = cov / math.sqrt(vart * varw)
    return {"slope_ratio": slope / 1e-6, "r2": r * r, "n": n}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?", default="/tmp/copyattach_debug.log")
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--no-strict", action="store_true")
    ap.add_argument("--session-start", type=int, default=None,
                    help="measurement window: records with wall >= this unix-ms")
    ap.add_argument("--session-byte", type=int, default=0,
                    help="log byte offset at session start; torn lines before it "
                         "are reported as historical rather than failing the gate")
    args = ap.parse_args()

    all_records, malformed, total_lines, torn_lines, torn_historical = load(
        args.log, args.session_byte)
    window = all_records
    if args.session_start is not None:
        window = [r for r in all_records if r["wall"] >= args.session_start]

    gates = []

    def gate(name, ok, detail):
        gates.append({"name": name, "ok": bool(ok), "detail": detail})

    gate("G5_records_parse", malformed == 0,
         "%d records parsed, %d malformed in window (%d torn/interleaved), "
         "%d torn before window (historical), %d log lines"
         % (len(all_records), malformed, torn_lines, torn_historical, total_lines))

    versions = sorted({r["v"] for r in all_records})
    gate("G5b_known_version", bool(versions) and all(v in SUPPORTED_VERSIONS for v in versions),
         "versions seen: %s" % (versions or "none"))

    # Dominant pid: the process with the most records in the measurement window,
    # falling back to the whole log when the window is empty.
    def dominant(recs):
        counts = defaultdict(int)
        for r in recs:
            counts[r["pid"]] += 1
        return max(counts, key=counts.get) if counts else None

    pid = dominant(window) or dominant(all_records)

    # Validation records: everything for the dominant pid, ignoring the session
    # filter (launch-time self-check must always be visible).
    vrecs = [r for r in all_records if pid is None or r["pid"] == pid]

    verdicts = [r for r in vrecs if r["cat"] == "perfcheck" and r["name"] == "verdict"]
    last_verdict = verdicts[-1] if verdicts else None
    gate("G1_selfcheck",
         last_verdict is not None and last_verdict.get("val") == 1,
         ("verdict=%s data=%s" % (last_verdict.get("val"), last_verdict.get("data")))
         if last_verdict else "no self-check verdict record for pid %s" % pid)

    probe_names = {r["name"] for r in vrecs if r["cat"] == "probe"}
    gate("G2_channel", {"swift_probe", "rust_probe"} <= probe_names,
         "probe writers seen: %s" % sorted(probe_names))

    # G6: cross-language clock alignment from the raw stamps.
    swift_probes = {r.get("data"): r for r in vrecs
                    if r["cat"] == "probe" and r["name"] == "swift_probe"}
    rust_probes = {r.get("data"): r for r in vrecs
                   if r["cat"] == "probe" and r["name"] == "rust_probe"}
    shared = [t for t in swift_probes if t and t in rust_probes]
    if not shared:
        gate("G6_clock_alignment", False, "no token present in both probe writers")
    else:
        tok = shared[-1]
        delta_us = (rust_probes[tok]["t"] - swift_probes[tok]["t"]) / 1000.0
        gate("G6_clock_alignment", -1000.0 <= delta_us <= 2000.0,
             "Rust minus Swift stamp delta %.1f us" % delta_us)

    overhead = [r for r in vrecs if r["cat"] in ("probe", "perfcheck")]
    gate("G3_overhead_bounded", len(overhead) <= 8,
         "%d unconditional records for pid %s (expected <= 8 per launch)"
         % (len(overhead), pid))

    fmt_costs = [r for r in vrecs
                 if r["cat"] == "perfcheck" and r["name"] == "format_cost_ns"]
    if fmt_costs:
        cost = fmt_costs[-1]["val"]
        gate("G7_format_cost", cost is not None and cost < 20_000,
             "%s ns/record to format a trace record" % cost)
    else:
        gate("G7_format_cost", False, "no format-cost sample recorded")

    disabled_costs = [r for r in vrecs
                      if r["cat"] == "perfcheck" and r["name"] == "disabled_start_cost_ns"]
    if disabled_costs:
        dcost = disabled_costs[-1]["val"]
        gate("G8_disabled_inert", dcost is not None and dcost < 100,
             "disabled PerfSpan.start costs %s ns/call" % dcost)
    else:
        gate("G8_disabled_inert", False, "no disabled-path cost sample recorded")

    clk = clock_gate(vrecs, pid) if pid is not None else None
    if clk is None:
        gate("G4_clock", False, "not enough records on the dominant pid")
    else:
        ok = 0.90 <= clk["slope_ratio"] <= 1.10 and clk["r2"] >= 0.99
        gate("G4_clock", ok, "slope ratio %.4f, R^2 %.6f over %d samples"
             % (clk["slope_ratio"], clk["r2"], clk["n"]))

    # ---- Measurement view -------------------------------------------------
    by_span = defaultdict(list)
    for r in window:
        if r["kind"] == "e" and r["dur_us"] is not None:
            by_span[(r["cat"], r["name"])].append(r["dur_us"])
    spans = {"%s/%s" % k: summarize(v) for k, v in by_span.items()}

    counters = defaultdict(list)
    for r in window:
        if r["kind"] == "c" and r["val"] is not None:
            counters["%s/%s" % (r["cat"], r["name"])].append(r["val"])

    chains = {
        "open->content_appear": summarize(
            chain_latencies(window, "popup.show_begin", "popup.content_appear")),
        "nav.input->nav.applied": summarize(chain_latencies(window, "nav.input", "nav.applied")),
        "capture->ui_observed": summarize(
            chain_latencies(window, "capture.text", "capture.ui_observed")
            + chain_latencies(window, "capture.image_phase1", "capture.ui_observed")),
        "capture->list_published": summarize(
            chain_latencies(window, "capture.text", "list.published")
            + chain_latencies(window, "capture.image_phase1", "list.published")),
    }

    data_spans = defaultdict(list)
    for r in window:
        if r["kind"] == "e" and r["dur_us"] is not None and r.get("data"):
            data_spans[("%s/%s" % (r["cat"], r["name"]), r["data"])].append(r["dur_us"])

    all_ok = all(g["ok"] for g in gates)

    print("# CopyAttach perf report")
    print()
    print("Log: %s" % args.log)
    print("Dominant pid: %s   Records: %d   Malformed: %d" % (pid, len(window), malformed))
    if args.session_start is not None:
        print("Measurement window: wall >= %d" % args.session_start)
    print()
    print("## Instrument validation")
    print()
    print("| gate | result | detail |")
    print("|---|---|---|")
    for g in gates:
        print("| %s | %s | %s |" % (g["name"], "PASS" if g["ok"] else "FAIL", g["detail"]))
    print()
    print("Verdict: **%s**" % ("VALID" if all_ok else "INVALID"))
    print()
    print("## Latency distributions (microseconds)")
    print()
    print("| cat/name | n | p50 | p95 | p99 | max | mean |")
    print("|---|---|---|---|---|---|---|")
    seen = set()
    for cat, name in SPAN_ORDER:
        key = "%s/%s" % (cat, name)
        seen.add(key)
        s = spans.get(key)
        if s and s["n"]:
            print("| %s | %d | %.0f | %.0f | %.0f | %.0f | %.0f |"
                  % (key, s["n"], s["p50"], s["p95"], s["p99"], s["max"], s["mean"]))
    for key in sorted(spans):
        if key in seen:
            continue
        s = spans[key]
        print("| %s | %d | %.0f | %.0f | %.0f | %.0f | %.0f |"
              % (key, s["n"], s["p50"], s["p95"], s["p99"], s["max"], s["mean"]))
    print()
    print("## Derived chains (microseconds)")
    print()
    print("| chain | n | p50 | p95 | p99 | max |")
    print("|---|---|---|---|---|---|")
    for key, s in chains.items():
        if s["n"]:
            print("| %s | %d | %.0f | %.0f | %.0f | %.0f |"
                  % (key, s["n"], s["p50"], s["p95"], s["p99"], s["max"]))
        else:
            print("| %s | 0 | - | - | - | - |" % key)
    print()
    print("## Counters")
    print()
    for key in sorted(counters):
        s = summarize(counters[key])
        print("- %s: n=%d p50=%.0f max=%.0f" % (key, s["n"], s["p50"], s["max"]))
    print()
    if data_spans:
        print("## Scenario-split spans (microseconds)")
        print()
        print("| cat/name | scenario | n | p50 | p95 | max |")
        print("|---|---|---|---|---|---|")
        for (key, scen) in sorted(data_spans):
            s = summarize(data_spans[(key, scen)])
            print("| %s | %s | %d | %.0f | %.0f | %.0f |"
                  % (key, scen, s["n"], s["p50"], s["p95"], s["max"]))
        print()

    budgets = [
        ("hotkey -> popup content mounted", "chain", "open->content_appear", 150_000),
        ("popup open (show)", "span", "swift/popup.show", 100_000),
        ("popup open -> list data (empty start)", "counter", "swift/popup.first_data_us", 500_000),
        ("list reload (request -> publish)", "span", "swift/popup.reload", 100_000),
        ("search ascii (key -> results)", "scen", "swift/search.end_to_end|ascii", 120_000),
        ("search cjk (key -> results)", "scen", "swift/search.end_to_end|cjk", 200_000),
        ("arrow key -> selection applied", "chain", "nav.input->nav.applied", 30_000),
        ("thumbnail decode", "span", "swift/thumb.decode_total", 50_000),
        ("preview open", "span", "swift/preview.open", 150_000),
        ("preview full-text load", "span", "swift/preview.load_full_text", 50_000),
        ("paste (menu -> keystroke)", "span", "swift/paste.menu_to_keystroke", 150_000),
        ("capture -> ui noticed", "chain", "capture->ui_observed", 300_000),
        ("capture -> list published (rendered)", "chain", "capture->list_published", 300_000),
    ]

    def budget_stats(kind, key):
        if kind == "span":
            return spans.get(key)
        if kind == "counter":
            return summarize(counters[key]) if key in counters else None
        if kind == "chain":
            return chains.get(key)
        if kind == "scen":
            base, scen = key.split("|")
            vals = data_spans.get((base, scen))
            return summarize(vals) if vals else None
        return None

    print("## Latency budgets (p95 vs threshold)")
    print()
    print("| budget | p95 | threshold | status | n |")
    print("|---|---|---|---|---|")
    budget_rows = []
    for label, kind, key, threshold in budgets:
        s = budget_stats(kind, key)
        if s is None or not s.get("n"):
            print("| %s | - | %.0f us | NOT MEASURED | 0 |" % (label, threshold))
            continue
        p95 = s["p95"]
        status = "OK" if p95 <= threshold else "OVER"
        budget_rows.append({"budget": label, "p95_us": p95,
                            "threshold_us": threshold, "status": status, "n": s["n"]})
        print("| %s | %.0f us | %.0f us | %s | %d |"
              % (label, p95, threshold, status, s["n"]))
    print()

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump({"gates": gates, "spans": spans, "chains": chains,
                       "counters": {k: summarize(v) for k, v in counters.items()},
                       "budgets": budget_rows,
                       "records": len(window), "malformed": malformed,
                       "pid": pid, "valid": all_ok,
                       "session_start": args.session_start}, fh, indent=2)
        print("JSON written to %s" % args.json_out)

    if not all_ok and not args.no_strict:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
