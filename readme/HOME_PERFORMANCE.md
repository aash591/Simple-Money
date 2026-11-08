# Home performance

Measured on 2026-11-01 with the connected RMX5061 at 120 Hz (8.33 ms per frame),
using a profile APK and the disposable profile ledger. Production data was not
used. These are single-device measurements, not guarantees for every phone.

The first four measurements below used the original fixture's fixed dates;
the current month could therefore have an empty spending card. The harness now
shifts the disposable ledger into the current month and asserts nonzero spending
before measuring, to exercise the donut chart as well.

| Scenario | Frames | Over budget (build or raster) | Build p99 | Raster p99 | Raster max |
| --- | ---: | ---: | ---: | ---: | ---: |
| Before, 180 rows, warmed | 3,464 | 1 | 0.74 ms | 5.65 ms | 10.37 ms |
| After, 180 rows, warmed | 3,493 | 0 | 1.67 ms | 4.42 ms | 5.91 ms |
| After, approximately 20,000 rows, first scroll | 1,304 | 5 | 2.55 ms | 5.52 ms | 10.09 ms |
| After, approximately 20,000 rows, warmed | 3,492 | 0 | 1.70 ms | 4.55 ms | 5.64 ms |
| After, populated current month, approximately 20,000 rows, first scroll | 1,311 | 7 | 3.41 ms | 5.90 ms | 11.19 ms |
| After, populated current month, approximately 20,000 rows, warmed | 3,480 | 0 | 1.78 ms | 4.75 ms | 5.95 ms |
| Resting tab pill without path clips, populated, approximately 20,000 rows, first scroll | 1,308 | 4 | 2.75 ms | 5.52 ms | 7.39 ms |
| Resting tab pill without path clips, populated, approximately 20,000 rows, warmed | 3,481 | 0 | 1.64 ms | 4.58 ms | 6.47 ms |

The sample-ledger raster tail improved; build timings did not improve in that
run, but remained below budget. First-use work still caused occasional slow
frames. The benchmark uses `fullyLive` frame policy and includes settling frames
between flings, so its frame count is not a count of continuously moving frames.

## Changes

- Mount Transactions, Budgets and More on first visit, retaining them afterward.
- Serialize/coalesce Home reloads, skip incomplete saves, and avoid rebuilding
  existing cards just to start a background refresh.
- Add the transaction date/order index with a v35-to-v36 migration.
- Compute six month-end balances from one grouped movement query instead of six
  overlapping history scans; accumulate native currencies before conversion.
- Reuse donut labels, icons and center content throughout animation frames.
- Cache the navigation shadow separately, including its full blur overflow.
- Draw the resting tab pill over the plain tabs instead of cutting them out
  with a path clip, and clip the highlighted tabs with a rounded-rect clip.
  The cut-out path is still used while a press makes the pill see-through.

The glass shader, colors, spacing, chart geometry, gesture handling and animation
durations are unchanged. Existing card keep-alive behavior is preserved.

## Where raster time goes

Turning each effect off in turn (180-row ledger, warm scroll, raster p50 of
3.48 ms) showed the bar's two glass passes cost about 0.8 ms, its shadow and
the card clips about 0.2 ms each. The blur and the lens can't share one pass
without changing the look: grouped backdrops would hand the lens an unblurred
snapshot, and a composed filter misaligns the shader.

## Verification

86 targeted tests passed, covering Home/navigation, layout, budgets, privacy,
currency totals, account upgrades and period animations. Static analysis of the
changed production files and new test/harness files passed.

New regression checks cover v35 index migration and its query plan, balance
equivalence across month boundaries/archived accounts/currencies/future entries,
donut animation content reuse, and lazy-tab state retention. A temporary pixel
comparison against the original navigation bar and donut passed in light and
dark themes using Flutter's test renderer (the glass fallback, not the device
shader). The duplicate baseline widgets were then removed.

## Reproduce

From `app`, run:

```sh
flutter drive --profile --driver=test_driver/integration_test.dart --target=integration_test/home_scroll_perf_test.dart
flutter drive --profile --driver=test_driver/integration_test.dart --target=integration_test/home_scroll_perf_test.dart --dart-define=BIG_LEDGER=true
```

The harness reports first-scroll and warm-scroll timings separately and writes
structured results through the integration driver. `BIG_LEDGER` expands only
the separate profile application's database and persists between profile runs.
Use a fresh disposable profile ledger when comparing small-ledger runs again.
The harness refuses non-profile runs and records the actual transaction count.
