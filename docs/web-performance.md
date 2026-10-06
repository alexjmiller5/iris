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
