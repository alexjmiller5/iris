// Loading placeholders, blank empty values and column wrapping on the sample workspace.
// Usage: `IRIS_DEV_NO_HMR=1 bun run dev -- --port 5261`, then a disposable Chrome with a
// fresh --user-data-dir and --remote-debugging-port=9333, then
//   IRIS_TEST_CDP=http://127.0.0.1:9333 IRIS_TEST_URL=http://127.0.0.1:5261/workspace \
//   IRIS_TEST_SHOTS=<dir> bun scripts/test-grid-presentation.ts
import { chromium, expect as base } from "@playwright/test";

const cdp = process.env.IRIS_TEST_CDP ?? "http://127.0.0.1:9333";
const url = process.env.IRIS_TEST_URL ?? "http://127.0.0.1:5261/workspace";
const shots = process.env.IRIS_TEST_SHOTS;
const browser = await chromium.connectOverCDP(cdp);
const context = browser.contexts()[0] ?? (await browser.newContext());
const page = await context.newPage();
page.setDefaultTimeout(180_000);
const expect = base.configure({ timeout: 180_000 });
const LONG = "A synthetic note whose title keeps going well past the width of its column";

const shot = async (name: string) => {
  if (shots) await page.screenshot({ path: `${shots}/${name}.png` });
};
const rows = () => page.locator('[role="grid"] [role="row"][aria-rowindex]');
const guidance = () => page.getByText("Connect to your hub in the sidebar", { exact: false });

// Held worker replies: the page stays in its loading state until release().
await page.addInitScript(() => {
  const state = window as any;
  state.held = [];
  state.hold = null;
  state.release = () => {
    state.hold = null;
    state.held.splice(0).forEach((deliver: () => void) => deliver());
  };
  const Original = window.Worker;
  window.Worker = class extends Original {
    requests = new Map<number, any>();
    postMessage(request: any, ...args: any[]) {
      this.requests.set(request.id, request);
      return super.postMessage(request, ...(args as [any]));
    }
    set onmessage(handler: any) {
      super.onmessage = (event) => {
        const request = this.requests.get(event.data.id);
        this.requests.delete(event.data.id);
        const deliver = () => handler?.(event);
        if (request?.method === state.hold) {
          state.hold = null;
          state.held.push(deliver);
        } else deliver();
      };
    }
  };
});
const hold = (method: string) => page.evaluate((m) => ((window as any).hold = m), method);
const held = () => page.waitForFunction(() => (window as any).held.length > 0);
const release = () => page.evaluate(() => (window as any).release());

/** The stored definition of the applied view, read through the core like any client. */
async function saved(view: string) {
  return page.evaluate(async (id) => {
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const db = new WorkspaceDatabase();
    try {
      await db.request("open", { demo: true });
      const list = await db.request("listViews", { table: "notes" });
      return list.views.find((v) => v.id === id)?.definition ?? null;
    } finally {
      db.close();
    }
  }, view);
}

let failures = 0;
async function check(name: string, body: () => Promise<void>) {
  try {
    await body();
    console.log(`ok - ${name}`);
  } catch (error) {
    failures++;
    console.log(`not ok - ${name}\n${error}`);
    await shot(`failed-${name.replace(/\W+/g, "-")}`);
  }
}

try {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto(url);
  const sample = page.getByRole("button", { name: "Try sample workspace" });
  await expect(sample).toBeEnabled();
  // Synthetic rows only, written through the ordinary writer: one long title, one empty status.
  await page.evaluate(async (title) => {
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const db = new WorkspaceDatabase();
    try {
      await db.request("open", { demo: true });
      const existing = await db.request("rows", {
        view: { table: "notes", filters: [{ column: "title", op: "eq", value: title }] },
      });
      if (!existing.length)
        await db.request("write", { table: "notes", patch: { title, status: null } });
    } finally {
      db.close();
    }
  }, LONG);

  await check("opening shows placeholders, never the empty-workspace guidance", async () => {
    await page.evaluate(() => {
      const w = window as any;
      w.bad = [];
      const tick = () => {
        const main = document.querySelector("main.records")?.textContent ?? "";
        if (main.includes("Connect to your hub in the sidebar") || main.includes("No records yet"))
          w.bad.push(main.slice(0, 80));
        if ([...document.querySelectorAll("h1")].some((h) => h.textContent?.trim() === "Welcome"))
          w.bad.push("Welcome heading");
        if (!document.querySelector('[role="grid"] [role="row"][aria-rowindex]'))
          requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    await hold("snapshot");
    await sample.click();
    await held();
    await expect(page.locator('[aria-busy="true"]', { hasText: "Loading tables" })).toBeVisible();
    await expect(page.locator('[aria-busy="true"]', { hasText: "Opening workspace" })).toBeVisible();
    await expect(guidance()).toHaveCount(0);
    await shot("01-opening-placeholders");
    await release();
    await expect(rows().first()).toBeVisible();
    expect(await page.evaluate(() => (window as any).bad)).toEqual([]);
  });
  const view = await page.getByLabel("View", { exact: true }).inputValue();
  // A previous run's layout is reset through the ordinary writer.
  await page.evaluate(async (id) => {
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const db = new WorkspaceDatabase();
    try {
      await db.request("open", { demo: true });
      const applied = (await db.request("listViews", { table: "notes" })).views.find(
        (v) => v.id === id,
      )!;
      await db.request("saveView", {
        table: "notes",
        name: applied.name,
        definition: { version: 2 },
        id,
        expectedUpdatedAt: applied.updated_at!,
      });
    } finally {
      db.close();
    }
  }, view);
  await page.reload();
  await sample.click();
  await expect(rows().first()).toBeVisible();

  await check("a table's rows show grid placeholders until they load", async () => {
    await hold("rows");
    await page
      .getByRole("navigation", { name: "Tables", exact: true })
      .getByRole("button", { name: "views", exact: true })
      .click();
    await held();
    await expect(page.locator(".grid-scroll [aria-busy='true']")).toContainText("Loading records");
    await expect(page.getByText("No records yet", { exact: false })).toHaveCount(0);
    await shot("02-rows-placeholders");
    await release();
    await expect(page.locator(".grid-scroll [aria-busy='true']")).toHaveCount(0);
    await page
      .getByRole("navigation", { name: "Tables", exact: true })
      .getByRole("button", { name: "notes", exact: true })
      .click();
    await expect(rows().first()).toBeVisible();
  });

  const longRow = () => rows().filter({ hasText: LONG.slice(0, 30) });
  await check("an empty value is a blank cell, not placeholder text", async () => {
    const status = longRow().locator('[data-column="status"]');
    await expect(status).toHaveText("");
    await expect(longRow()).not.toContainText("Not set");
    await expect(longRow()).not.toContainText("Empty");
  });

  await check("Wrap text grows the row and saves with the view; Undo reverts it", async () => {
    const before = (await longRow().boundingBox())!.height;
    await page.getByRole("button", { name: "Record column options", exact: true }).click();
    const item = page.getByRole("menuitemcheckbox", { name: "Wrap text" });
    await expect(item).toHaveAttribute("aria-checked", "false");
    await item.click();
    await expect.poll(async () => (await longRow().boundingBox())!.height).toBeGreaterThan(before);
    await expect.poll(async () => (await saved(view))?.wrap).toEqual(["title"]);
    await shot("03-wrapped-title");
    await page.getByRole("button", { name: "Record column options", exact: true }).click();
    await expect(item).toHaveAttribute("aria-checked", "true");
    await page.keyboard.press("Escape");
    await page.locator("main.records h1").click();
    await page.keyboard.press("ControlOrMeta+z");
    await expect.poll(async () => (await saved(view))?.wrap).toBeUndefined();
    await expect.poll(async () => (await longRow().boundingBox())!.height).toBe(before);
  });

  await check("Wrap all columns wraps every shown column and clears them together", async () => {
    await page.getByText("Columns", { exact: true }).click();
    const all = page.getByRole("checkbox", { name: "Wrap all columns" });
    await all.check();
    await expect
      .poll(async () => (await saved(view))?.wrap)
      .toEqual(["title", "status", "related"]);
    await shot("04-wrap-all");
    await all.uncheck();
    await expect.poll(async () => (await saved(view))?.wrap).toBeUndefined();
    await page.getByText("Columns", { exact: true }).click();
  });
} finally {
  await page.close();
  await browser.close();
}
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);
