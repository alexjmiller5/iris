import { chromium, expect, type Page } from "@playwright/test";
import { workspacePage } from "./test-origin";

// Dedicated synthetic origin. Never clear storage on a configured or shared workspace.
const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-export.localhost:5256/workspace?review";
const target = new URL(url);
if (
  target.origin !== "http://life-ui-export.localhost:5256" ||
  target.pathname !== "/workspace" ||
  !target.searchParams.has("review")
)
  throw new Error("Export acceptance requires the reserved disposable origin.");
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
let page: Page | undefined;
const markdown = "# Exact source\r\n\r\n<tag> _雪_  \n";
try {
  page = workspacePage(
    browser.contexts().flatMap((context) => context.pages()),
    url,
  );
  if (!page) throw new Error("Open an owned export test tab first.");
  page.setDefaultTimeout(7000);
  await page.goto(new URL("/", url).href);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Storage.clearDataForOrigin", {
    origin: target.origin,
    storageTypes: "all",
  });
  await cdp.detach();
  await page.addInitScript(() => {
    const state = window as any;
    state.holdRows = false;
    state.heldRows = [];
    state.holdSnapshots = false;
    state.heldSnapshots = [];
    state.releaseSnapshots = () => {
      state.holdSnapshots = false;
      state.heldSnapshots.splice(0).forEach((deliver: () => void) => deliver());
    };
    state.releaseRows = () => {
      state.holdRows = false;
      state.heldRows.splice(0).forEach((deliver: () => void) => deliver());
    };
    state.exports = [];
    const create = URL.createObjectURL.bind(URL);
    URL.createObjectURL = (blob: Blob) => {
      state.exports.push(blob.text());
      return create(blob);
    };
    const Original = window.Worker;
    window.Worker = class extends Original {
      requests = new Map<number, string>();
      postMessage(message: any, ...args: any[]) {
        if (["rows", "snapshot"].includes(message.method))
          this.requests.set(message.id, message.method);
        return super.postMessage(message, ...(args as [any]));
      }
      set onmessage(handler: any) {
        super.onmessage = (event) => {
          const method = this.requests.get(event.data.id);
          this.requests.delete(event.data.id);
          const deliver = () => handler.call(this, event);
          if (method === "rows" && state.holdRows) state.heldRows.push(deliver);
          else if (method === "snapshot" && state.holdSnapshots)
            state.heldSnapshots.push(deliver);
          else deliver();
        };
      }
    };
  });
  await page.goto(url);
  await page
    .getByRole("button", { name: "Try sample workspace", exact: true })
    .click();
  await page
    .getByRole("button", { name: "A place to start", exact: true })
    .waitFor();
  await page.evaluate(async (body) => {
    // Supported write API, synthetic sample workspace only. No production SQL seam.
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const other = new WorkspaceDatabase();
    try {
      await other.request("open", { demo: true });
      await other.request("write", {
        table: "notes",
        patch: { title: "=2+2", body },
      });
    } finally {
      other.close();
    }
  }, markdown);
  const action = page.getByRole("button", {
    name: "Export loaded rows",
    exact: true,
  });
  const disclosure = page.getByRole("button", { name: "Export", exact: true });
  await expect(disclosure).toBeVisible();
  expect((await disclosure.locator("..").boundingBox())?.width).toBeLessThan(
    160,
  );
  await expect(action).toBeHidden();
  if (process.env.LIFE_UI_TEST_SCREENSHOTS) {
    await page.screenshot({
      path: `${process.env.LIFE_UI_TEST_SCREENSHOTS}/export-collapsed.png`,
      fullPage: true,
    });
  }
  await page.setViewportSize({ width: 390, height: 844 });
  const narrow = await disclosure.locator("..").boundingBox();
  expect(narrow?.width).toBeLessThan(160);
  expect(narrow!.x).toBeGreaterThanOrEqual(0);
  expect(narrow!.x + narrow!.width).toBeLessThanOrEqual(390);
  await page.setViewportSize({ width: 1280, height: 900 });
  const formatControl = page.getByRole("combobox", {
    name: "Export format",
    exact: true,
  });
  await expect(formatControl).toBeHidden();
  await disclosure.focus();
  await disclosure.press("Enter");
  await expect(action).toBeVisible();
  if (process.env.LIFE_UI_TEST_SCREENSHOTS) {
    await page.screenshot({
      path: `${process.env.LIFE_UI_TEST_SCREENSHOTS}/export-expanded.png`,
      fullPage: true,
    });
  }
  await formatControl.focus();
  await formatControl.press("Escape");
  await expect(action).toBeHidden();
  await expect(disclosure).toBeFocused();
  await disclosure.press("Space");
  await expect(action).toBeVisible();
  await expect(action).toBeEnabled();
  await page.getByRole("button", { name: "=2+2", exact: true }).waitFor();
  await expect(
    page.getByText("2 loaded rows. Table completeness and freshness unknown.", {
      exact: true,
    }),
  ).toBeVisible();
  // Start a real cell draft without committing it. Export must read persisted row state.
  const cell = page.getByRole("gridcell", { name: "Title: =2+2", exact: true });
  await cell.focus();
  await cell.press("Enter");
  await page
    .getByRole("group", { name: "Edit Title", exact: true })
    .getByRole("textbox")
    .fill("UNSAVED TITLE");
  const download = page.waitForEvent("download");
  await action.click();
  expect((await download).suggestedFilename()).toBe(
    "notes-loaded-unknown-full.json",
  );
  const exported = JSON.parse(
    await page.evaluate(async () => await (window as any).exports.at(-1)),
  );
  expect(exported.scope).toEqual({ kind: "loaded", rowCount: 2 });
  expect(exported.completeness).toMatchObject({
    rows: "unknown",
    columns: "full",
  });
  expect(exported.acquisition).toMatchObject({
    source: "local-replica",
    freshness: "unknown",
    lastSync: null,
    skippedTables: [],
  });
  expect(Number.isFinite(Date.parse(exported.acquisition.capturedAt))).toBe(
    true,
  );
  expect(exported.properties.find((p: any) => p.col === "body").type).toBe(
    "markdown",
  );
  expect(exported.rows.find((row: any) => row.title === "=2+2").body).toBe(
    markdown,
  );
  expect(exported.rows.some((row: any) => row.title === "UNSAVED TITLE")).toBe(
    false,
  );
  await expect(
    page
      .getByRole("group", { name: "Edit Title", exact: true })
      .getByRole("textbox"),
  ).toHaveValue("UNSAVED TITLE");
  await page.getByRole("button", { name: "Discard", exact: true }).click();
  // A loading search cannot reuse the previous page under the new context.
  await page.evaluate(() => {
    (window as any).holdRows = true;
  });
  await page
    .getByRole("textbox", { name: "Search records", exact: true })
    .fill("=2+2");
  await page.waitForFunction(() => (window as any).heldRows.length > 0);
  await expect(action).toBeDisabled();
  // A broadcast refresh overlaps the pending rows; its status/catalog reply is held.
  await page.evaluate(async () => {
    (window as any).holdSnapshots = true;
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const other = new WorkspaceDatabase();
    try {
      await other.request("open", { demo: true });
      await other.request("write", {
        table: "notes",
        patch: { title: "Unrelated fixture", body: "" },
      });
    } finally {
      other.close();
    }
  });
  await page.waitForFunction(() => (window as any).heldSnapshots.length > 0);
  await page.evaluate(async () => {
    (window as any).releaseRows();
    await new Promise((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(resolve)),
    );
  });
  await expect(action).toBeDisabled();
  await page.evaluate(() => (window as any).releaseSnapshots());
  await expect(action).toBeEnabled();
  await expect(
    page.getByText("1 loaded row. Table completeness and freshness unknown.", {
      exact: true,
    }),
  ).toBeVisible();
  await page
    .getByRole("combobox", { name: "Export format", exact: true })
    .selectOption("csv");
  const csvDownload = page.waitForEvent("download");
  await action.click();
  expect((await csvDownload).suggestedFilename()).toBe(
    "notes-loaded-unknown-full.csv",
  );
  const csv = await page.evaluate(
    async () => await (window as any).exports.at(-1),
  );
  expect(csv).toContain('"\'=2+2"');
  expect(csv).toContain(markdown.replaceAll('"', '""'));
  // Sidecar belongs to the clicked capture even if the workspace navigates afterwards.
  await page
    .getByRole("textbox", { name: "Search records", exact: true })
    .fill("missing fixture");
  await expect(
    page.getByText("0 loaded rows. Table completeness and freshness unknown.", {
      exact: true,
    }),
  ).toBeVisible();
  const metadataDownload = page.waitForEvent("download");
  await page
    .getByRole("button", { name: "Download CSV metadata", exact: true })
    .click();
  expect((await metadataDownload).suggestedFilename()).toBe(
    "notes-loaded-unknown-full.metadata.json",
  );
  const metadata = JSON.parse(
    await page.evaluate(async () => await (window as any).exports.at(-1)),
  );
  expect(metadata.scope).toEqual({ kind: "loaded", rowCount: 1 });
  expect(metadata.csv.lossless).toBe(false);
  expect(metadata.table).toBe("notes");
  // Switching tables must never relabel the old rows with the new table/catalog.
  await page.evaluate(() => {
    (window as any).holdRows = true;
  });
  await page
    .getByRole("navigation", { name: "Tables", exact: true })
    .getByRole("button", { name: "views", exact: true })
    .click();
  await page.waitForFunction(() => (window as any).heldRows.length > 0);
  await expect(action).toBeDisabled();
  await page.evaluate(() => (window as any).releaseRows());
  await expect(action).toBeEnabled();
  await page
    .getByRole("combobox", { name: "Export format", exact: true })
    .selectOption("json");
  const tableDownload = page.waitForEvent("download");
  await action.click();
  expect((await tableDownload).suggestedFilename()).toBe(
    "views-loaded-unknown-full.json",
  );
  const views = JSON.parse(
    await page.evaluate(async () => await (window as any).exports.at(-1)),
  );
  expect(views.table).toBe("views");
  expect(views.rows).toEqual([]);
  expect(views.properties.every((p: any) => p.tbl === "views")).toBe(true);
  console.log(
    "PASS: mounted export downloads exact stored Markdown and explicit metadata; loading blocks export; CSV sidecar retains its clicked capture.",
  );
} finally {
  if (page) {
    await page.goto(new URL("/", url).href);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Storage.clearDataForOrigin", {
      origin: target.origin,
      storageTypes: "all",
    });
    await cdp.detach();
    await page.goto(url);
  }
  await browser.close();
}
