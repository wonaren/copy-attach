# CopyAttach perf baseline (measured)

Produced by `perf/analyze.py`. Every gate in section "Instrument validation"
passed (verdict VALID); the numbers below are therefore trustworthy to the
extent of the instrument's own validation (see docs/perf-instrumentation.md).

Session: release build, real clipboard captures + 6 real popup open/close cycles
+ live captures while the popup was open. 130 records, 0 malformed.

## Instrument validation

All gates PASS: G1 selfcheck, G2 channel, G3 overhead, G4 clock, G5 parse,
G6 cross-language clock alignment, G7 format cost (348 ns), G8 disabled path
(0 ns/call).

## Latency (microseconds)

| cat/name | n | p50 | p95 |
|---|---|---|---|
| swift/popup.show | 7 | 32759 | 79287 |
| swift/popup.visible_setup | 7 | 35 | 71 |
| swift/popup.reload | 10 | 17508 | 90227 |
| swift/snapshot.decode | 10 | 16154 | 18479 |
| swift/popup.close | 7 | 9176 | 14945 |
| rust/snapshot.pack | 10 | 124 | 162 |
| rust/db.write | 23 | 580 | 1191 |

## Chains (microseconds)

| chain | n | p50 | p95 |
|---|---|---|---|
| open->content_appear | 7 | 36762 | 84467 |
| capture->ui_observed | 9 | 134688 | 521611 |

## Findings

1. **Capture -> UI is the dominant perceived lag.** The backend lands a capture
   in `rust/db.write` p95 1.2 ms, but the UI observes it at p50 135 ms / p95
   522 ms. The gap is UI polling, not backend work. This is the root of the
   "copy, open popup, content still missing" experience.
2. **Swift snapshot decode is ~130x the Rust serialization.** `rust/snapshot.pack`
   is p50 124 us for ~950 rows; `swift/snapshot.decode` is p50 16.2 ms.
3. **Full snapshot is rebuilt on every history change** (~248 KB packed), even
   though one row changed.
4. **Thumbnail wall time is queueing, not decoding** (see docs:
   `thumb.queue_wait` vs `imageio`).

## Not measured

Search, arrow navigation, preview, drag, and paste require real input events.
The host environment could not synthesize them (no Accessibility grant for
System Events), so no numbers are reported for them rather than guessed.
Please run a session with real input to fill these in.
