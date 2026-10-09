import { parseArgs } from "node:util";
import { connect, ownedTarget } from "./performance/cdp";
import {
  fixtureOrigin,
  summarize,
  frames,
  javascriptBytes,
  type ResourceSize,
} from "./performance/metrics";

const { values } = parseArgs({
  options: {
    url: {
      type: "string",
      default: "http://iris-performance.localhost:5246/workspace?review",
    },
    cdp: { type: "string", default: "http://127.0.0.1:9222" },
    out: { type: "string" },
  },
});
if (!values.out) throw new Error("Pass --out <synthetic-results.json>");
const address = values.url!;
const origin = fixtureOrigin(address);
const targets = await fetch(new URL("/json/list", values.cdp!), {
  signal: AbortSignal.timeout(10000),
}).then((r) => r.json());
const target = ownedTarget(targets, address);
// Direct page WebSocket avoids Playwright's attachment to unrelated targets.
const cdp = await connect(target.webSocketDebuggerUrl);
const workers = new Map<string, string>();
const errors: string[] = [];
let countRequests = false,
  warmRequests = 0;
cdp.onEvent((method, params) => {
  if (
    method === "Target.attachedToTarget" &&
    params.targetInfo.type === "worker"
  ) {
    workers.set(params.sessionId, params.targetInfo.url);
    void Promise.all([
      cdp.call("Network.enable", {}, params.sessionId),
      cdp.call("Runtime.enable", {}, params.sessionId),
    ]).catch((error) => errors.push(error.message));
  }
  if (method === "Target.detachedFromTarget") workers.delete(params.sessionId);
  if (method === "Runtime.exceptionThrown")
    errors.push(params.exceptionDetails.text);
  if (countRequests && method === "Network.requestWillBeSent") warmRequests++;
});
async function evaluate<T = any>(
  expression: string,
  sessionId?: string,
): Promise<T> {
  const result = await cdp.call(
    "Runtime.evaluate",
    { expression, returnByValue: true, awaitPromise: true },
    sessionId,
  );
  if (result.exceptionDetails)
    throw new Error(
      result.exceptionDetails.exception?.description ??
        result.exceptionDetails.text,
    );
  return result.result.value;
}
async function wait(expression: string) {
  const deadline = Date.now() + 10000;
  do {
    try {
      if (await evaluate(expression)) return;
    } catch (error) {
      if (
        !/execution context.*destroyed|Cannot find (default execution )?context/i.test(
          String(error),
        )
      )
        throw error;
    }
    await Bun.sleep(30);
  } while (Date.now() < deadline);
  throw new Error("Owned fixture condition timed out: " + expression);
}
async function navigate(url: string) {
  const result = await cdp.call("Page.navigate", { url });
  if (result.errorText) throw new Error(result.errorText);
  await wait(
    `location.href === ${JSON.stringify(url)} && document.readyState === 'complete'`,
  );
  if (url !== "about:blank")
    await wait(`!!document.querySelector('#svelte-announcer')`);
}
const button = (label: string, scope = "document") =>
  `[...${scope}.querySelectorAll('button')].find(b => b.textContent.trim() === ${JSON.stringify(label)})`;
const sampleButton = button("Try sample workspace");
const notesButton = button(
  "notes",
  `document.querySelector('nav[aria-label="Tables"]')`,
);
async function paintedRows(buttonExpression: string): Promise<number> {
  await wait(`!!(${buttonExpression}) && !(${buttonExpression}).disabled`);
  const point = await evaluate<{ x: number; y: number }>(`(async () => {
    const button = ${buttonExpression};
    button.scrollIntoView({ block: 'nearest' });
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
    const rect = button.getBoundingClientRect();
    const x = rect.x + rect.width / 2, y = rect.y + rect.height / 2;
    if (!button.contains(document.elementFromPoint(x, y))) throw Error('Fixture button is obscured');
    const selector = '[role="gridcell"][data-column="title"]';
    const before = document.querySelector(selector);
    delete window.irisPerformancePaint;
    button.addEventListener('click', () => {
      const start = performance.now();
      const observer = new MutationObserver(() => {
        const cell = document.querySelector(selector);
        if (!cell || cell === before || !cell.getClientRects().length) return;
        observer.disconnect();
        requestAnimationFrame(() => requestAnimationFrame(() => {
          window.irisPerformancePaint = performance.now() - start;
        }));
      });
      observer.observe(document.body, { childList: true, subtree: true, attributes: true });
      setTimeout(() => observer.disconnect(), 10000);
    }, { once: true, capture: true });
    return {x, y};
  })()`);
  await cdp.call("Input.dispatchMouseEvent", {
    type: "mousePressed",
    ...point,
    button: "left",
    clickCount: 1,
  });
  await cdp.call("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    ...point,
    button: "left",
    clickCount: 1,
  });
  await wait(`typeof window.irisPerformancePaint === 'number'`);
  return evaluate<number>("window.irisPerformancePaint");
}
const resourceExpression = `performance.getEntriesByType('resource').map(r => ({name:r.name,transferSize:r.transferSize,encodedBodySize:r.encodedBodySize,decodedBodySize:r.decodedBodySize}))`;
try {
  await cdp.call("Page.enable");
  await cdp.call("Runtime.enable");
  await cdp.call("Network.enable");
  await cdp.call("Target.setAutoAttach", {
    autoAttach: true,
    waitForDebuggerOnStart: false,
    flatten: true,
  });
  await cdp.call("Emulation.setDeviceMetricsOverride", {
    width: 1280,
    height: 800,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await cdp.call("Page.bringToFront");
  const response = await fetch(address, { signal: AbortSignal.timeout(10000) });
  if (
    response.headers.get("x-iris-performance") !== "production-fixture" ||
    response.headers.get("cache-control") !== "no-store"
  )
    throw new Error("Use the no-store production fixture server");
  await navigate("about:blank");
  await cdp.call("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.call("Network.setCacheDisabled", { cacheDisabled: true });
  const cold: {
    navigationToFcpMs: number;
    sampleOpenToRowsMs: number;
    js: ReturnType<typeof javascriptBytes>;
    resources: ResourceSize[];
  }[] = [];
  for (let i = 0; i < 6; i++) {
    await navigate(address);
    if (
      await evaluate(`!!document.querySelector('script[src*="@vite/client"]')`)
    )
      throw new Error("Measure a production build, not Vite dev");
    const sampleOpenToRowsMs = await paintedRows(sampleButton);
    if (workers.size !== 1)
      throw new Error("Expected exactly one live workspace Worker");
    const sizes = [
      ...(await evaluate<ResourceSize[]>(resourceExpression)),
      ...(
        await Promise.all(
          [...workers.keys()].map((id) =>
            evaluate<ResourceSize[]>(resourceExpression, id),
          ),
        )
      ).flat(),
    ];
    const navigationToFcpMs = await evaluate<number | null>(
      `performance.getEntriesByName('first-contentful-paint')[0]?.startTime ?? null`,
    );
    if (navigationToFcpMs === null)
      throw new Error("Browser did not provide FCP");
    const workerUrls = await Promise.all(
      [...workers.keys()].map((id) => evaluate<string>("location.href", id)),
    );
    let js;
    try {
      js = javascriptBytes(sizes, workerUrls);
    } catch (error) {
      console.error(
        "Incomplete synthetic resource evidence",
        JSON.stringify({ workers: workerUrls, sizes }),
      );
      throw error;
    }
    cold.push({ navigationToFcpMs, sampleOpenToRowsMs, js, resources: sizes });
    if (i < 5) await navigate("about:blank");
  }
  countRequests = true;
  const warm: number[] = [];
  for (let i = 0; i < 10; i++) warm.push(await paintedRows(notesButton));
  countRequests = false;
  if (warmRequests)
    throw new Error(
      "Warm local navigation unexpectedly made a network request",
    );
  await navigate(origin + "/performance-grid");
  await wait(
    `!!document.querySelector('[data-iris-performance="10000"] [data-row="r0"][data-column="title"]')`,
  );
  const scrolling = await evaluate<{
    timestamps: number[];
    maxCells: number;
    scrollHeight: number;
    viewportHeight: number;
  }>(`(async () => {
    if (document.visibilityState !== 'visible') throw Error('Foreground tab required');
    const element = document.querySelector('.grid-scroll');
    const timestamps = []; let maxCells = 0;
    const distance = element.scrollHeight - element.clientHeight;
    if (distance <= 0) throw Error('Grid is not scrollable');
    await new Promise(resolve => {
      function frame(now) {
        if (document.visibilityState !== 'visible') { resolve(); return; }
        timestamps.push(now);
        const elapsed = now - timestamps[0];
        element.scrollTop = distance * Math.min(1, elapsed / 5000);
        maxCells = Math.max(maxCells, element.querySelectorAll('[role="gridcell"]').length);
        if (elapsed < 5000) requestAnimationFrame(frame); else resolve();
      }
      requestAnimationFrame(frame);
    });
    if (timestamps.at(-1) - timestamps[0] < 5000) throw Error('Foreground measurement interrupted');
    return { timestamps, maxCells, scrollHeight: element.scrollHeight, viewportHeight: element.clientHeight };
  })()`);
  await wait(
    `(() => { const cell = document.querySelector('[data-row="r9999"][data-column="title"]'); if (!cell) return false; const box = cell.getBoundingClientRect(); return box.bottom > 0 && box.top < innerHeight; })()`,
  );
  if (errors.length) throw new Error(`Browser errors: ${errors.join("; ")}`);
  const report = {
    schemaVersion: 1,
    measuredAt: new Date().toISOString(),
    sourceCommit: (await Bun.$`git rev-parse HEAD`.quiet().text()).trim(),
    build:
      "production with temporary performance-grid route; chunk graph may differ from a normal build",
    browser: await evaluate<string>("navigator.userAgent"),
    viewport: { width: 1280, height: 800 },
    physicalIPhoneAcceptance: "not measured",
    limits: {
      replicaFirstPaintMs: 100,
      initialJavascriptKB: 500,
      scrollFps: 60,
      gridRows: 10000,
    },
    boundaries: {
      cold: "Production workspace, no-store fixture responses including Worker dependencies, new Worker each navigation. One synthetic OPFS sample row; no hub/sync. First run creates the sample and is separate.",
      rowPaint:
        "Click capture to fresh row DOM plus two animation frames; upper-bound paint opportunity proxy, not compositor timestamp. Instrumentation overhead is included.",
      warm: "Ten Notes table reselections with same Worker/OPFS; fresh query/grid, zero network requests.",
      javascript:
        "Document and dedicated Worker Resource Timing through first rows. WASM/CSS excluded. Transfer including headers, encoded body and decoded body separate. Fixture serves uncompressed no-store assets.",
      scroll:
        "Production RecordGrid, 10000 synthetic in-memory rows,5s programmatic scroll. rAF cadence includes stalls; no database paging or physical touch.",
    },
    firstSampleCreation: cold[0],
    coldReplicaReopen: {
      samples: cold.slice(1),
      navigationToFcpMs: summarize(
        cold.slice(1).map((v) => v.navigationToFcpMs),
      ),
      sampleOpenToRowsMs: summarize(
        cold.slice(1).map((v) => v.sampleOpenToRowsMs),
      ),
    },
    warmLocalTableReselect: {
      samplesMs: warm,
      durationMs: summarize(warm),
      networkRequests: warmRequests,
    },
    scroll: { ...scrolling, ...frames(scrolling.timestamps) },
  };
  await Bun.write(values.out, JSON.stringify(report, null, 2) + "\n");
  console.log(
    JSON.stringify(
      {
        cold: report.coldReplicaReopen.sampleOpenToRowsMs,
        warm: report.warmLocalTableReselect.durationMs,
        js: cold.at(-1)!.js,
        scroll: frames(scrolling.timestamps),
        physicalIPhoneAcceptance: report.physicalIPhoneAcceptance,
      },
      null,
      2,
    ),
  );
} finally {
  try {
    await navigate("about:blank");
    await cdp.call("Storage.clearDataForOrigin", {
      origin,
      storageTypes: "all",
    });
  } finally {
    cdp.close();
  }
}
