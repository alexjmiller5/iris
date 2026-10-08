// Notion-style filters and sorts on the sample workspace, in a real browser.
// Usage: `bun run dev -- --port 5261`, then a disposable Chrome with a fresh
// --user-data-dir and --remote-debugging-port=9333, then
//   LIFE_UI_TEST_CDP=http://127.0.0.1:9333 LIFE_UI_TEST_URL=http://127.0.0.1:5261/workspace \
//   LIFE_UI_TEST_SHOTS=<dir> bun scripts/test-filter-bar.ts
import { chromium, expect as base, type Page } from "@playwright/test";

const cdp = process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9333";
const url = process.env.LIFE_UI_TEST_URL ?? "http://127.0.0.1:5261/workspace";
const shots = process.env.LIFE_UI_TEST_SHOTS;
const browser = await chromium.connectOverCDP(cdp);
const context = browser.contexts()[0] ?? (await browser.newContext());
const page = await context.newPage();
page.setDefaultTimeout(180_000);
const expect = base.configure({ timeout: 180_000 });

const shot = async (name: string) => {
  if (shots) await page.screenshot({ path: `${shots}/${name}.png` });
};
const rows = () => page.locator('[role="grid"] [role="row"][aria-rowindex]');
const editor = () => page.getByRole("dialog", { name: "Edit filter" });
const chips = () => page.getByRole("group", { name: "Sort and filters" });

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
async function open(target: Page) {
  const sample = target.getByRole("button", { name: "Try sample workspace" });
  if (await sample.isVisible().catch(() => false)) await sample.click();
  await expect(target.getByLabel("View", { exact: true })).toBeVisible();
  await expect(rows().first()).toBeVisible();
  await target.waitForURL(/[?&]view=/);
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
  await open(page);
  const view = await page.getByLabel("View", { exact: true }).inputValue();

  await check("a table without a saved view opens on a created default view", async () => {
    expect(view).not.toBe("");
    expect(await saved(view)).not.toBeNull();
    await shot("02-default-view");
  });

  // Synthetic rows only, written through the ordinary writer; a previous run's
  // view settings are reset the same way.
  await page.evaluate(async (id) => {
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const db = new WorkspaceDatabase();
    try {
      await db.request("open", { demo: true });
      const existing = await db.request("rows", {
        view: { table: "notes", filters: [{ column: "title", op: "eq", value: "Ready one" }] },
      });
      if (!existing.length)
        for (const [title, status] of [
          ["Ready one", "Ready"],
          ["Ready two", "Ready"],
          ["Second draft", "Draft"],
        ])
          await db.request("write", { table: "notes", patch: { title, status } });
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
  await open(page);
  await expect.poll(() => rows().count()).toBeGreaterThanOrEqual(4);
  const [all, ready] = await page.evaluate(async () => {
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const db = new WorkspaceDatabase();
    try {
      await db.request("open", { demo: true });
      const count = async (filters: unknown[]) =>
        (await db.request("rows", { view: { table: "notes", filters, limit: 200 } })).length;
      return [await count([]), await count([{ column: "status", op: "eq", value: "Ready" }])];
    } finally {
      db.close();
    }
  });
  expect(ready).toBeGreaterThan(0);
  expect(ready).toBeLessThan(all);

  await check("Filter, property, value: the grid narrows with no Apply", async () => {
    await page.getByRole("button", { name: "Filter", exact: true }).click();
    await expect(page.getByLabel("Filter by property")).toBeFocused();
    await page.keyboard.type("Stat");
    await page.keyboard.press("Enter");
    await expect(editor()).toBeVisible();
    await shot("03-chip-editor");
    const option = editor().getByRole("checkbox", { name: "Ready" });
    await option.focus();
    await page.keyboard.press("Space");
    await expect(rows()).toHaveCount(ready);
    await page.keyboard.press("Escape");
    await expect(editor()).toBeHidden();
    await expect(chips().getByRole("button", { name: "Status: Ready", exact: true })).toBeFocused();
    await expect
      .poll(async () => (await saved(view))?.filters)
      .toEqual([{ column: "status", op: "eq", value: "Ready" }]);
    await shot("04-filtered");
  });

  await check("a reload shows the saved filter", async () => {
    await page.reload();
    await open(page);
    await expect(chips().getByRole("button", { name: "Status: Ready", exact: true })).toBeVisible();
    await expect(rows()).toHaveCount(ready);
  });

  await check("sorts apply instantly, reorder by keyboard and save on close", async () => {
    await page.getByRole("button", { name: "Sort", exact: true }).click();
    const menu = page.getByRole("dialog", { name: "Sort" });
    await menu.getByLabel("Add sort").selectOption("title");
    await menu.getByLabel("Sort 1 direction").selectOption("desc");
    await expect(rows().first()).toContainText("Ready two");
    await menu.getByLabel("Add sort").selectOption("status");
    await menu.getByRole("button", { name: /Reorder Status sort/ }).focus();
    await page.keyboard.press("ArrowUp");
    await expect(menu.getByLabel("Sort 1 property")).toHaveValue("status");
    await shot("05-sort-menu");
    await page.keyboard.press("Escape");
    await expect
      .poll(async () => (await saved(view))?.sort)
      .toEqual([
        { column: "status", direction: "asc" },
        { column: "title", direction: "desc" },
      ]);
    await page.reload();
    await open(page);
    await expect(chips().getByRole("button", { name: /2\s+sorts/ })).toBeVisible();
    await expect(rows().first()).toContainText("Ready two");
  });

  await check("a column header sorts the view", async () => {
    await page.getByRole("button", { name: "Record column options" }).click();
    await page.getByRole("menuitem", { name: "Sort ascending" }).click();
    await expect(rows().first()).toContainText("Ready one");
    await expect
      .poll(async () => (await saved(view))?.sort)
      .toEqual([{ column: "title", direction: "asc" }]);
  });

  await check("removing a chip saves, and Cmd-Z restores it", async () => {
    await chips().getByRole("button", { name: "Remove filter: Status: Ready" }).click();
    await expect(rows()).toHaveCount(all);
    await expect.poll(async () => (await saved(view))?.filters).toEqual([]);
    await page.locator("body").click({ position: { x: 5, y: 5 } });
    await page.keyboard.press("ControlOrMeta+z");
    await expect(chips().getByRole("button", { name: "Status: Ready", exact: true })).toBeVisible();
    await expect(rows()).toHaveCount(ready);
    await expect
      .poll(async () => (await saved(view))?.filters)
      .toEqual([{ column: "status", op: "eq", value: "Ready" }]);
    await shot("06-undone");
  });

  await check("a filter group stays reachable from the Filter menu", async () => {
    await page.getByRole("button", { name: /^Filter/ }).first().click();
    await page.getByRole("button", { name: "Add filter group" }).click();
    await expect(editor().getByLabel("Group match")).toBeVisible();
    await editor().getByLabel("Property").first().selectOption("title");
    await editor().getByLabel("Value").first().fill("one");
    await expect(rows()).toHaveCount(1);
    await page.keyboard.press("Escape");
    await expect(chips().getByRole("button", { name: "All of 1 rules", exact: true })).toBeVisible();
    await expect.poll(async () => (await saved(view))?.groups?.length).toBe(1);
    await chips().getByRole("button", { name: "Remove filter: All of 1 rules" }).click();
  });

  await check("at 390px the toolbar wraps and chips scroll in their own row", async () => {
    await page.setViewportSize({ width: 390, height: 844 });
    for (const text of ["e", "o", "a"]) {
      await page.getByRole("button", { name: "Add filter" }).click();
      await page.getByLabel("Filter by property").fill("Title");
      await page.keyboard.press("Enter");
      await editor().getByLabel("Value").fill(text);
      await page.keyboard.press("Escape");
    }
    const layout = await page.evaluate(() => {
      const row = document.querySelector<HTMLElement>(".chips")!;
      return {
        page: document.documentElement.scrollWidth - window.innerWidth,
        chips: row.scrollWidth - row.clientWidth,
      };
    });
    expect(layout.page).toBeLessThanOrEqual(0);
    expect(layout.chips).toBeGreaterThan(0);
    await shot("07-narrow");
    await page.getByRole("button", { name: "Add filter" }).click();
    await shot("08-narrow-picker");
    await page.keyboard.press("Escape");
  });
} finally {
  // Disconnect only; the disposable browser belongs to the caller.
  await page.close();
}
process.exit(failures ? 1 : 0);
