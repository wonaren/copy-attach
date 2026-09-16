# CopyAttach perf baseline (measured)

Produced by `perf/analyze.py`. All gates in "Instrument validation" PASS (verdict
VALID), so the numbers are trustworthy to the extent of the instrument's own
validation. See `docs/perf-instrumentation.md`.

Session: release build. Popup held open, 12 real clipboard captures. 151
records, 0 malformed.

## Headline: event-driven refresh

The UI used to discover a capture by polling the backend every 500 ms. It now
blocks on a Rust condvar that the capture path signals, so "captured" -> "known
to the UI" is bounded by scheduling, not by a timer period.

| chain | before | after |
|---|---|---|
| capture -> UI noticed (`capture->ui_observed`) | p50 134,688 us / p95 521,611 us | **p50 323 us / p95 463 us** |
| capture -> list published (incl. rebuild) | (bounded by the same 500 ms poll) | p50 13,791 us / p95 15,069 us |

`capture->ui_observed` p95 falls ~99.9% (521.6 ms -> 0.46 ms). Once the change is
known, rebuilding the snapshot and publishing the list costs ~13.8 ms p50, so
the user-perceived end-to-end is now ~14 ms p50 rather than up to ~500 ms.

## Latency (microseconds)

| cat/name | n | p50 | p95 |
|---|---|---|---|
| swift/popup.show | 1 | 85705 | 85705 |
| swift/popup.reload | 13 | 13210 | 14695 |
| swift/snapshot.decode | 13 | 12770 | 14188 |
| swift/snapshot.decode.strings | 13 | 406 | 443 |
| swift/snapshot.decode.format_preview | 13 | 12161 | 13478 |
| rust/snapshot.pack | 13 | 133 | 234 |
| rust/db.write | 12 | 662 | 885 |

`snapshot.decode` splits into 0.4 ms of String construction and 12.2 ms of
`formatDisplayPreview` (the display-string computation Rust does not perform).
This is the remaining, now-dominant cost of a list reload.

## Not measured

Search, arrow navigation, preview, drag, and paste require real input events.
The host environment could not synthesize them (no Accessibility grant for
System Events), so no numbers are reported for them rather than guessed.

## Bugs found by the instrument during this work

1. **Non-atomic log appends corrupted the trace.** Swift used
   `FileHandle.seekToEnd()+write` (not atomic) and Rust emitted a record as two
   `write_all` calls (line, then newline); a Rust human log line was four
   separate writes. Under concurrent writers this overwrote bytes, once
   silently deleting a `capture.text` record. All writers now use one O_APPEND
   write, and the analyzer rejects any torn/interleaved line instead of
   mis-parsing it (gate G5).
2. **`wall` and `t` described different instants.** `wall` was stamped at span
   END while `t` was the span START, so for long spans the two clock fields
   disagreed by the span duration. Gate G4 caught it (R^2 0.9899 with a
   ~3000 ms residual step equal to the waiter timeout); both languages now
   stamp `wall` at span start.
