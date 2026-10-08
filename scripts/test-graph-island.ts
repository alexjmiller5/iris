import { chromium, expect } from "@playwright/test";
import { disposableOrigin, workspacePage } from "./test-origin";

const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-graph.localhost:5199/workspace?review";
disposableOrigin(url);
const html = await Bun.file(
  new URL(
    "../packages/LifeKit/Sources/LifeKit/Resources/graph.html",
    import.meta.url,
  ),
).text();
const browser = await chromium.connectOverCDP(
  process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
);
try {
  const page = workspacePage(
    browser.contexts().flatMap((c) => c.pages()),
    url,
  );
  if (!page) throw Error("Open the dedicated graph test page");
  await page.addInitScript(() => {
    const host = window as any;
    host.events = [];
    host.webkit = {
      messageHandlers: {
        lifeGraph: {
          postMessage(message: unknown) {
            host.events.push(message);
          },
        },
      },
    };
  });
  await page.route(url, (route) =>
    route.fulfill({ body: html, contentType: "text/html" }),
  );
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(url);
  await page.evaluate(() =>
    (window as any).LifeGraph.render({
      tables: ["history", "notes", "topics", "views"].map((id) => ({
        id,
        kind: "table",
      })),
      properties: [
        { tbl: "notes", col: "topic", type: "ref", ref_table: "topics" },
      ],
      groups: {},
    }),
  );
  const canvas = page.getByRole("region", { name: "Scrollable table graph" });
  const diagram = canvas.locator(":scope > svg");
  await expect
    .poll(
      () => canvas.evaluate((node) => node.scrollWidth <= node.clientWidth + 1),
      {
        message:
          "The initial phone overview must include every column without horizontal clipping",
      },
    )
    .toBe(true);
  const initial = (await diagram.boundingBox())!.width;
  await page.getByRole("button", { name: "Zoom in", exact: true }).click();
  await expect
    .poll(async () => (await diagram.boundingBox())!.width)
    .toBeGreaterThan(initial);
  expect((await page.getByRole("button", { name: /^history \d+ columns?$/ }).boundingBox())!.height,
    "One zoom step must make table targets readable and tappable").toBeGreaterThanOrEqual(44);
  await page.getByRole("button", { name: "Fit graph", exact: true }).click();
  await expect
    .poll(() =>
      canvas.evaluate((node) => node.scrollWidth <= node.clientWidth + 1),
    )
    .toBe(true);
  await page
    .getByRole("button", { name: /^topics \d+ columns?$/ })
    .click();
  await expect
    .poll(() => page.evaluate(() => (window as any).events.at(-1)))
    .toEqual({ type: "openTable", table: "topics" });
  await page.setViewportSize({ width: 320, height: 740 });
  await expect
    .poll(() =>
      canvas.evaluate((node) => node.scrollWidth <= node.clientWidth + 1),
    )
    .toBe(true);
  for (const name of ["Zoom in", "Zoom out", "Fit graph"]) {
    const bounds = (await page
      .getByRole("button", { name, exact: true })
      .boundingBox())!;
    expect(bounds.width).toBeGreaterThanOrEqual(44);
    expect(bounds.height).toBeGreaterThanOrEqual(44);
  }
  expect(
    await page.evaluate(async () => {
      try {
        await fetch("https://example.com/forbidden");
        return false;
      } catch {
        return true;
      }
    }),
  ).toBe(true);
  if (process.env.LIFE_UI_GRAPH_SCREENSHOT)
    await page.screenshot({ path: process.env.LIFE_UI_GRAPH_SCREENSHOT });
  console.log(
    "PASS: phone graph overview, zoom, fit, resize, table navigation, touch targets and network isolation",
  );
} finally {
  await browser.close();
}
