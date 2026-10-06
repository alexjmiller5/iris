# Browser performance measurement

The acceptance targets remain: first paint from the replica under 100 ms,
initial JavaScript under 500 KB, and 60 fps scrolling a 10,000-row grid on
physical iPhone Safari. Desktop measurements and viewport emulation do not
complete that acceptance.

## Reproduce with synthetic data

Use an isolated checkout, the locked Bun dependencies and an idle browser.
Do not run a native build or another browser driver during timed samples.

```sh
bun test scripts/performance
bun scripts/build-web-performance.ts
bun scripts/serve-web-performance.ts
```

The build script temporarily adds `/performance-grid`, importing the actual
`RecordGrid` component with 10,000 synthetic in-memory rows. It refuses an
existing route and removes its source in `finally`. The resulting local build
is a measurement artifact; **never deploy it**. A normal production build without
the fixture source produces the regular application.
Adding the route can change bundler chunk sharing, so label these results as a
fixture build. Confirm final transfer acceptance against an ordinary production
build as well.

The loopback-only fixture server presents HTTPS to production SSR to satisfy
the unchanged HTTPS-redirect hook. The browser uses its localhost secure context
for OPFS. Every response, including Worker dependencies, is uncompressed and
`no-store`; this measures cold resource loading without flushing another
origin's cache. It does not test the deployed edge, TLS or compression behavior.

In a separately managed Chrome with CDP enabled, create your own window/tab
at `http://life-ui-performance.localhost:5246/workspace?review`. Coordinate use
of a shared browser before starting. The runner requires exactly one matching
tab and never creates or closes another session's tabs.

From the repository root:

```sh
bun scripts/measure-web-performance.ts --out /tmp/life-ui-performance.json
```

`--cdp` selects the existing Chrome endpoint (default `http://127.0.0.1:9222`).
The fixture origin is deliberately fixed, and all storage clearing is restricted
to that origin. The app's separate sample workspace never connects to a hub.
The driver connects directly to the exact owned page's WebSocket and attaches
only its child Workers, avoiding browser-wide Playwright initialization. Calls
and page conditions have ten-second deadlines. It never modifies global Chrome
configuration or attaches to other sessions' pages.
The runner empties its synthetic origin before/after, returns its tab to
`about:blank`, and disconnects from CDP. Close your owned tab/group and stop the
preview server after the run. No live account, token, imported rows or remote
service is needed.

## What each number means

| Measurement | Included | Excluded / limitation |
| --- | --- | --- |
| Navigation to FCP | Production document and application shell | Does not imply a replica row is visible |
| Initial sample creation | Explicit sample-open click, Worker/WASM, OPFS initialization, one synthetic row, render | Reported separately from existing replica reads |
| Cold replica reopen | Five full page navigations, new Worker, existing one-row OPFS sample, explicit click to fresh row | All fixture HTTP responses no-store; OS/disk caches are not flushed |
| Warm local table reselect | Ten fresh Notes queries/grid replacements through the same Worker/OPFS instance | One-row sample, zero network; not a 10k-row database query |
| Initial JS | Document and dedicated Worker Resource Timing entries through first rows | WASM/CSS excluded from JS; raw entries retained; preview compression is not hosting compression |
| 10k grid scroll | Actual production RecordGrid, all 10k synthetic rows in memory, five-second traversal | No database paging, no physical touch, no Safari claim |

The row timer starts in a capture listener on the actual click, so driver IPC
is excluded. It waits for a fresh visible row element and two animation frames.
This gives an upper-bound paint opportunity proxy; it is not a compositor's
actual presentation timestamp. Raw timings, median, p95 and max are retained.
Never substitute shell FCP or a native model's database-query duration for it.

JavaScript reports three distinct quantities: header-inclusive transfer bytes,
encoded response-body bytes, and decoded response-body bytes. Resource Timing
includes worker imports and preserves cached responses rather than counting
their zero transfer as a zero-size bundle. Missing size evidence fails the run.
Report both encoded and decoded totals against the 500 KB target until the
budget's intended compression basis is explicitly resolved. Do not change the
limit or hide Worker code. WASM remains visible in raw resources as a separate
startup cost.

The scroll report includes raw rAF timestamps, average cadence, frame interval
median/p95/max, intervals exceeding 16.667 ms, maximum DOM cells, and confirmation
that row 9,999 is visible. It keeps long stalls. A foreground tab is required;
rAF cadence is a diagnostic proxy, not proof that every frame was presented
without blank content. No pass/fail acceptance is inferred from rounding fps.

## Recorded desktop baseline

[Raw samples and resource sizes](performance/2026-10-06-desktop-chrome.json)
were captured on 2026-10-06 at 14:58 UTC from commit
`12d93c67e51a64710725df6a59e2d6611cd0b05c` (production source based on
`5ecf0e469ebbe0b695c293b9f4647408f4240e52`). This is a desktop Chrome 154
baseline at 1280 by 800 on a Mac mini with macOS 26.6, during an exclusively
allocated browser/CPU window with native builds and benchmarks idle.
It does not measure later production changes, physical iPhone Safari or native
app startup. It cannot diagnose native startup latency or the effect of native
read-cancellation changes.

| Measurement | Samples | Median | p95 / maximum |
| --- | ---: | ---: | ---: |
| New sample creation, click to rows | 1 | 115.30 ms | 115.30 ms |
| Existing one-row OPFS replica reopen, click to rows | 5 | 65.60 ms | 65.90 ms |
| Warm local table reselect, click to rows | 10 | 47.95 ms | 49.10 ms |
| Shell navigation to FCP, existing-replica runs | 5 | 80 ms | 96 ms |
| 10k in-memory grid rAF interval | 300 | 16.70 ms | 16.80 / 18.70 ms |

All six startup samples loaded 12 JavaScript resources, including the dedicated
Worker: **427,760 encoded body bytes**, **427,760 decoded body bytes**, and
**431,360 transfer bytes including headers**. The fixture serves uncompressed
responses. Separately, SQLite WASM used 725,083 body bytes and 725,383 transfer
bytes. Both the Worker and WASM are retained in the raw resource records.

The five-second grid traversal recorded 301 rAF callbacks, averaging 60 callbacks
per second across 300 intervals, with at most 34 mounted cells; row 9,999 was
visible at the end. There were 190 intervals strictly above 1000/60 ms. That
strict counter includes ordinary 16.7 ms timestamp quantization, so it is not a
dropped-frame count; the unrounded timestamps and 18.7 ms maximum remain visible.
No claim about compositor presentation or blank-free touch scrolling follows
from the average cadence alone.

Warm reselections made zero network requests. No browser exception was reported.
The direct page WebSocket run completed; the synthetic origin was cleared, its
group closed, and the fixture server stopped afterward. Failed earlier driver
attachments produced no samples and are excluded from this report.

These desktop reopen samples and JS totals fall below the original numerical
limits for their stated boundaries. New sample creation exceeded 100 ms.
Neither result closes the replica-first-paint requirement on physical iPhone:
the one-row click-to-paint proxy, fixture build, and localhost serving policy
still have the limitations above. Ordinary-production transfer verification,
device measurements and actual presented-frame evidence remain open.

## Physical iPhone acceptance

1. Use the same production commit, synthetic fixture and a separately authorized
   test origin reachable from the phone over a secure context. Record iPhone
   model, iOS/Safari version, display refresh rate, viewport, power/thermal state
   and network conditions. No live replica or personal data is needed.
2. Capture Safari Web Inspector's navigation/network/frames timeline. Distinguish
   an empty origin creating its first sample from a reload of an existing local
   sample, and a table selection with the same Worker still open. Take at least
   five cold-reopen and ten warm-query samples. Record both navigation FCP and
   row presentation timing; retain raw traces and the measurement boundaries.
3. Count all initial JS, including Worker imports, through first visible records.
   Report encoded and decoded response bytes separately; also record WASM.
   Test the actual serving compression/cache policy before drawing conclusions
   from the local preview's transfer numbers.
4. Drive a real touch scroll across the 10k fixture and inspect frames/blank
   content at the top, middle and end. Record cadence and stalls over repeated
   five-second traversals. The desktop programmatic scroll is only a baseline.
5. Add the synthetic report and a concise device result here. Compare the original
   limits without changing styles, row counts or thresholds to obtain a pass.
   A regression requires a scoped implementation handoff; this harness changes
   no production UI or database behavior.

Physical iPhone Safari acceptance remains unmeasured.
