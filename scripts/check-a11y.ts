// Keyboard-only accessibility pass over every web view of the synthetic sample
// workspace, in light and dark. Each state is reached with Tab, Enter, Space and
// Escape only; every focused control must show a focus ring, Escape must hand
// focus back, and axe-core must report no serious or critical violation.
//   bun scripts/check-a11y.ts            (starts its own dev server and headless Chrome)
//   bun scripts/check-a11y.ts <life-data-checkout>
//                                        also walks a workspace connected to a synthetic
//                                        hub: sync pill states, notifications, usage,
//                                        attachments and rejected edits
//   LIFE_UI_TEST_SHOTS=<dir>             keeps a screenshot per step
//   LIFE_UI_TEST_URL=<origin>/workspace  uses an already running dev server
import { chromium, type Locator, type Page } from "@playwright/test";
import { servicesHub } from "./services-hub";
import { mkdirSync, readFileSync } from "node:fs";
import { createServer } from "node:net";

const root = new URL("..", import.meta.url).pathname;
const axe = readFileSync(`${root}node_modules/axe-core/axe.min.js`, "utf8");
const shots = process.env.LIFE_UI_TEST_SHOTS;
const source = process.argv[2];
if (shots) mkdirSync(shots, { recursive: true });

async function freePort() {
  const server = createServer();
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  const { port } = server.address() as { port: number };
  await new Promise((done) => server.close(done));
  return port;
}

let dev: ReturnType<typeof Bun.spawn> | undefined;
let url = process.env.LIFE_UI_TEST_URL;
if (!url) {
  const port = await freePort();
  dev = Bun.spawn(["bun", "run", "--cwd", "apps/web", "dev", "--", "--port", String(port), "--strictPort"], {
    cwd: root,
    env: { ...process.env, LIFE_UI_DEV_NO_HMR: "1" },
    stdout: "ignore",
    stderr: "ignore",
  });
  url = `http://127.0.0.1:${port}/workspace`;
  const deadline = Date.now() + 120_000;
  while ((await fetch(url).then((r) => r.status).catch(() => 0)) !== 200) {
    if (Date.now() > deadline) throw new Error(`Dev server did not start at ${url}`);
    await Bun.sleep(500);
  }
}

const failures: string[] = [];
const fail = (message: string) => {
  failures.push(message);
  console.log(`not ok - ${message}`);
};

/** Keyboard and audit helpers bound to one page and color scheme. */
function tools(page: Page, scheme: string) {
  let step = 0;
  const seen = new Set<string>();
  const audit = async (state: string) => {
    if (!(await page.evaluate(() => "axe" in window))) await page.addScriptTag({ content: axe });
    const { violations } = await page.evaluate(() =>
      (window as unknown as { axe: { run: (c: unknown, o: unknown) => Promise<any> } }).axe.run(document, {
        resultTypes: ["violations"],
      }),
    );
    for (const v of violations as { id: string; impact: string; help: string; nodes: { target: string[]; html: string }[] }[]) {
      const key = `${v.id} ${v.nodes.map((n) => n.target.join(" ")).join()}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const where = v.nodes.map((n) => `${n.target.join(" ")} ${n.html.slice(0, 120)}`).join("\n    ");
      const line = `${scheme} ${state}: [${v.impact}] ${v.id} - ${v.help}\n    ${where}`;
      if (v.impact === "serious" || v.impact === "critical") fail(line);
      else console.log(`note - ${line}`);
    }
    if (shots) await page.screenshot({ path: `${shots}/${scheme}-${String(++step).padStart(2, "0")}-${state}.png` });
    console.log(`ok - ${scheme} ${state} audited`);
  };
  /** The focused element must draw an outline or ring. */
  const ring = async () => {
    const result = await page.evaluate(() => {
      let el = document.activeElement as HTMLElement | null;
      while (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement as HTMLElement;
      if (!el || el === document.body) return null;
      const s = getComputedStyle(el);
      const outline = s.outlineStyle !== "none" && parseFloat(s.outlineWidth) > 0;
      const shadow = s.boxShadow !== "none";
      // Date and time inputs pass focus to their own parts (the picker button),
      // which Chrome rings natively.
      const native = el instanceof HTMLInputElement && /date|time|month|week/.test(el.type);
      const name = el.getAttribute("aria-label") || el.textContent?.trim().slice(0, 40) || el.tagName;
      return { ok: outline || shadow || native, name: `${el.tagName.toLowerCase()} "${name}"` };
    });
    if (result && !result.ok) fail(`${scheme}: no visible focus indicator on ${result.name}`);
  };
  /** Tab (or Shift+Tab) until `target` has focus, checking each stop's ring. */
  const tabTo = async (target: Locator, back = false, limit = 120) => {
    for (let i = 0; i < limit; i++) {
      if (await target.evaluate((el) => el === document.activeElement || el.contains(document.activeElement)).catch(() => false))
        return;
      await page.keyboard.press(back ? "Shift+Tab" : "Tab");
      await ring();
    }
    throw new Error(`${scheme}: ${target} is not reachable with ${back ? "Shift+Tab" : "Tab"}`);
  };
  const focused = (target: Locator) =>
    target.evaluate((el) => el === document.activeElement || el.contains(document.activeElement)).catch(() => false);
  const active = () =>
    page.evaluate(() => {
      const el = document.activeElement as HTMLElement | null;
      return el ? `${el.tagName.toLowerCase()} "${el.getAttribute("aria-label") || el.textContent?.trim().slice(0, 40)}"` : "nothing";
    });
  /** Focus must come back to one of `targets` (a closed popover's anchor). */
  const expectFocus = async (targets: Locator[], what: string) => {
    for (let i = 0; i < 20; i++) {
      for (const t of targets) if (await focused(t)) return;
      await page.waitForTimeout(100);
    }
    fail(`${scheme}: focus did not return to ${what}; it is on ${await active()}`);
  };
  const role = (r: Parameters<Page["getByRole"]>[0], name: string | RegExp) =>
    page.getByRole(r, { name, exact: typeof name === "string" }).first();
  return { audit, ring, tabTo, expectFocus, role };
}

/** One color scheme's walk through every view of the sample workspace. */
async function sampleWalk(page: Page, scheme: string) {
  const { audit, ring, tabTo, expectFocus, role } = tools(page, scheme);
  await page.goto(url!);
  await audit("landing");
  const sample = role("button", "Try sample workspace");
  await sample.waitFor();
  await page.waitForFunction(() =>
    [...document.querySelectorAll("button")].some((b) => b.textContent?.includes("Try sample workspace") && !b.disabled),
  );
  await tabTo(sample);
  await page.keyboard.press("Enter");
  const grid = page.getByRole("grid", { name: "Records" });
  await grid.waitFor({ timeout: 120_000 });
  await page.waitForURL(/[?&]view=/);
  await audit("table");
  // Setup through the core like any client, not the UI: a date so Calendar has
  // something to place.
  await page.evaluate(async () => {
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const db = new WorkspaceDatabase();
    try {
      await db.request("open", { demo: true });
      // Every walk runs in a fresh browser context, so the property is always new.
      await db.request("saveCatalogProperty", {
        table: "notes",
        column: "due",
        expectedUpdatedAt: null,
        fields: { label: "Due", type: "date" },
        addColumn: true,
      });
      const [row] = await db.request("rows", { view: { table: "notes", limit: 1 } });
      const today = new Date().toISOString().slice(0, 10);
      await db.request("write", { table: "notes", patch: { id: row.id, due: today }, expectedUpdatedAt: row.updated_at });
    } finally {
      db.close();
    }
  });
  await page.reload();
  await sample.waitFor();
  await page.waitForFunction(() =>
    [...document.querySelectorAll("button")].some((b) => b.textContent?.includes("Try sample workspace") && !b.disabled),
  );
  await tabTo(sample);
  await page.keyboard.press("Enter");
  await grid.waitFor({ timeout: 120_000 });
  await page.waitForURL(/[?&]view=/);

  // Filter: property search, chip editor, Escape back to the chip.
  const filter = role("button", /^Filter/);
  await page.locator("body").focus();
  await tabTo(filter);
  await page.keyboard.press("Enter");
  await page.getByLabel("Filter by property").waitFor();
  await audit("filter-properties");
  await page.keyboard.type("Stat");
  await page.keyboard.press("Enter");
  const editor = page.getByRole("dialog", { name: "Edit filter" });
  await editor.waitFor();
  await audit("filter-editor");
  // Space checks the sample's own status, so the chip stays and keeps its row.
  await tabTo(editor.getByRole("checkbox", { name: "Draft" }));
  await page.keyboard.press("Space");
  await page.keyboard.press("Escape");
  await editor.waitFor({ state: "hidden" });
  const chips = page.getByRole("group", { name: "Sort and filters" });
  await expectFocus([chips], "the filter chip");

  // Sort popover.
  const sort = role("button", /^Sort/);
  await tabTo(sort);
  await page.keyboard.press("Enter");
  const sortMenu = page.getByRole("dialog", { name: "Sort" });
  await sortMenu.waitFor();
  await audit("sort");
  const addSort = sortMenu.getByLabel("Add sort");
  await tabTo(addSort);
  await addSort.selectOption("title");
  await audit("sort-rule");
  await page.keyboard.press("Escape");
  await expectFocus([sort], "Sort");
  await audit("filter-and-sort-chips");

  // View switcher menu.
  const settings = role("button", "View settings");
  await tabTo(settings, true);
  await page.keyboard.press("Enter");
  await audit("view-menu");
  await page.keyboard.press("Escape");
  await expectFocus([settings], "View settings");

  // Columns, Export and Selection disclosures.
  for (const name of ["Columns", "Export"]) {
    const summary = page.locator("summary", { hasText: name }).first();
    await tabTo(summary);
    await page.keyboard.press("Enter");
    await audit(name.toLowerCase());
    await page.keyboard.press("Enter");
  }

  // Grid: arrows move the cell cursor, Space selects nothing by itself, Enter opens the record.
  await tabTo(grid.locator('td[tabindex="0"]'));
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("ArrowLeft");
  await ring();
  const select = page.getByRole("checkbox", { name: /^Select / }).nth(1);
  await tabTo(select, true);
  await page.keyboard.press("Space");
  const selection = page.locator("summary", { hasText: /Selection/ }).first();
  await tabTo(selection);
  await page.keyboard.press("Enter");
  await audit("bulk-actions");
  await page.keyboard.press("Enter");
  await tabTo(select, true);
  await page.keyboard.press("Space");

  // Record page with properties and the Markdown editor: Cmd/Ctrl+Enter opens it
  // from the grid, Tab reaches every control without a trap, Escape closes it.
  await tabTo(grid.locator('td[tabindex="0"]'));
  await page.keyboard.press("ControlOrMeta+Enter");
  const close = role("button", "Close record");
  await close.waitFor();
  await audit("record");
  await tabTo(close);
  await tabTo(page.locator('.record-panel [contenteditable="true"]').first());
  await page.keyboard.type("Typed by keyboard.");
  await page.locator('[aria-label="Body save status"][data-state="saved"]').waitFor({ state: "attached" });
  await audit("record-markdown");
  // The page-capture viewer: an ordinary note is not a capture, so it explains why.
  const capture = role("button", "View page capture");
  await tabTo(capture);
  await page.keyboard.press("Enter");
  await page.getByRole("dialog", { name: "Page capture" }).waitFor();
  await audit("page-capture");
  await page.keyboard.press("Escape");
  await expectFocus([capture], "View page capture");
  await tabTo(close, true);
  await page.keyboard.press("Enter");
  await close.waitFor({ state: "hidden" });

  // Cmd+K palette, opened from the sidebar button so focus has somewhere to return.
  const findButton = role("button", /^Find records/);
  await tabTo(findButton, true);
  await page.keyboard.press("ControlOrMeta+k");
  const find = page.getByRole("dialog", { name: /Find/ });
  await find.waitFor();
  await page.keyboard.type("place");
  await page.waitForTimeout(500);
  await audit("find");
  await page.keyboard.press("Escape");
  await find.waitFor({ state: "hidden" });
  await expectFocus([findButton], "Find records");

  // Layouts.
  const layout = page.getByRole("combobox", { name: "View layout" });
  for (const name of ["Calendar", "Gallery", "Board", "Table"]) {
    await tabTo(layout, true);
    await layout.selectOption({ label: name });
    await page.waitForTimeout(400);
    if (name !== "Table") await audit(name.toLowerCase());
  }

  // Trash.
  const trash = role("button", "Trash");
  await tabTo(trash);
  await page.keyboard.press("Enter");
  await audit("trash");
  await page.keyboard.press("Enter");

  // Catalog editor dialog.
  const catalog = role("button", "Edit catalog");
  await tabTo(catalog, true);
  await page.keyboard.press("Enter");
  await page.getByRole("dialog").first().waitFor();
  await audit("catalog-editor");
  await page.keyboard.press("Escape");
  await expectFocus([catalog], "Edit catalog");

  // Table graph.
  const graph = role("button", "Table graph");
  await tabTo(graph, true);
  await page.keyboard.press("Enter");
  await audit("table-graph");
  await page.keyboard.press("Enter");

  // Backup, export and restore dialog.
  const backup = role("button", "Backup");
  await tabTo(backup, true);
  await page.keyboard.press("Enter");
  await page.getByRole("dialog").first().waitFor();
  await page.waitForTimeout(500);
  await audit("backup");
  await page.keyboard.press("Escape");
  await expectFocus([backup], "Backup");

  // Collapsed sidebar via Cmd+\.
  await page.locator("body").focus();
  await page.keyboard.press("ControlOrMeta+\\");
  await audit("sidebar-collapsed");
  await page.keyboard.press("ControlOrMeta+\\");

  // Narrow screens.
  await page.setViewportSize({ width: 390, height: 844 });
  await audit("narrow-table");
  await page.setViewportSize({ width: 1280, height: 900 });

  // A personal workspace: hub services and the Connect form.
  const leave = role("button", "Switch workspace");
  await tabTo(leave, true);
  await page.keyboard.press("Enter");
  const mine = role("button", "Open my workspace");
  await mine.waitFor();
  await tabTo(mine);
  await page.keyboard.press("Enter");
  const connect = page.locator("summary", { hasText: "Connect to a hub" });
  await connect.waitFor({ timeout: 120_000 });
  await tabTo(connect, true);
  await page.keyboard.press("Enter");
  await audit("connect");
}

/** A personal workspace connected to a synthetic hub through the keyboard. */
async function hubWalk(page: Page, scheme: string) {
  const { audit, tabTo, expectFocus, role } = tools(page, scheme);
  const fixture = await servicesHub(source!, source!, new URL(url!).origin);
  try {
    // A file property, so the record shows the attachment control.
    const stamp = new Date().toISOString();
    fixture.db.db
      .query("UPDATE catalog_properties SET type='file',updated_at=?,hub_at=? WHERE tbl='widgets' AND col='quantity'")
      .run(stamp, stamp);
    await page.goto(url!);
    const mine = role("button", "Open my workspace");
    await page.waitForFunction(() =>
      [...document.querySelectorAll("button")].some((b) => b.textContent?.includes("Open my workspace") && !b.disabled),
    );
    await tabTo(mine);
    await page.keyboard.press("Enter");
    const connect = page.locator("summary", { hasText: "Connect to a hub" });
    await connect.waitFor({ timeout: 120_000 });
    await tabTo(connect, true);
    await page.keyboard.press("Enter");
    await tabTo(page.getByLabel("Hub address"));
    await page.keyboard.type(fixture.server.url.href.replace(/\/$/, ""));
    const tokenSummary = page.locator("summary", { hasText: "Use a device token" });
    await tabTo(tokenSummary);
    await page.keyboard.press("Enter");
    await tabTo(page.getByLabel("Device token"));
    await page.keyboard.type("fixture");
    await tabTo(role("button", "Connect"));
    await page.keyboard.press("Enter");
    await page.getByRole("heading", { name: "widgets", exact: true }).waitFor({ timeout: 60_000 });
    const pill = page.getByLabel(/^Sync status:/);
    await page.waitForFunction(() => document.querySelector('[aria-label="Sync status: Synced"]'), null, { timeout: 30_000 });
    await audit("hub-synced");

    for (const [name, state] of [[/^Notifications/, "notifications"], ["Settings", "settings-usage"]] as const) {
      const button = role("button", name);
      await tabTo(button, true);
      await page.keyboard.press("Enter");
      await page.getByRole("dialog").first().waitFor();
      await page.waitForTimeout(500);
      await audit(state);
      await page.keyboard.press("Escape");
      await expectFocus([button], state);
    }

    const grid = page.getByRole("grid", { name: "Records" });
    await tabTo(grid.locator('td[tabindex="0"]'));
    await page.keyboard.press("ControlOrMeta+Enter");
    const close = role("button", "Close record");
    await close.waitFor();
    await page.locator('.record-panel input[type="file"]').first().waitFor({ state: "attached" });
    await audit("record-attachment");
    await tabTo(close, true);
    await page.keyboard.press("Enter");
    await close.waitFor({ state: "hidden" });

    // Offline with a pending edit, then the hub refuses it: Offline · 1 pending,
    // then 1 rejected and the rejected-edits inbox.
    // The probe's worker loads before going offline: the dev server serves it.
    await page.evaluate(async () => {
      const { WorkspaceDatabase } = await import("/src/lib/database.ts");
      const db = new WorkspaceDatabase();
      await db.request("open");
      (window as unknown as { probe: typeof db }).probe = db;
    });
    await page.context().setOffline(true);
    await page.evaluate(async () => {
      const db = (window as unknown as { probe: { request: (m: string, a: unknown) => Promise<unknown>; close(): void } }).probe;
      await db.request("write", { table: "widgets", patch: { title: "Refused offline edit" } });
      db.close();
    });
    await page.waitForFunction(() => document.querySelector('[aria-label^="Sync status: Offline"]'), null, { timeout: 30_000 });
    await audit("hub-offline-pending");
    const later = new Date().toISOString();
    fixture.db.db
      .query("UPDATE catalog_properties SET pattern='Allowed',updated_at=?,hub_at=? WHERE tbl='widgets' AND col='title'")
      .run(later, later);
    await page.context().setOffline(false);
    await page.evaluate(() => window.dispatchEvent(new Event("online")));
    await page.waitForFunction(() => document.querySelector('[aria-label$="rejected"]'), null, { timeout: 60_000 });
    await audit("hub-rejected");
    await tabTo(pill, true);
    await page.keyboard.press("Enter");
    const review = role("button", "Review rejected edit");
    await review.waitFor();
    await audit("rejected-edits");
    await tabTo(review);
    await page.keyboard.press("Enter");
    await close.waitFor();
    await audit("rejection-review");
  } finally {
    fixture.server.stop(true);
  }
}

const browser = await chromium.launch({ channel: "chrome", headless: true });
try {
  // Warm up: the first open makes Vite optimize the database worker's
  // dependencies and reload, which must not happen mid-walk.
  const warm = await browser.newPage();
  await warm.goto(url);
  await warm.getByRole("button", { name: "Try sample workspace" }).click({ timeout: 120_000 });
  await warm.getByRole("grid", { name: "Records" }).waitFor({ timeout: 120_000 });
  await warm.waitForTimeout(2000);
  await warm.context().close();
  for (const scheme of ["light", "dark"] as const) {
    const context = await browser.newContext({
      viewport: { width: 1280, height: 900 },
      colorScheme: scheme,
      reducedMotion: scheme === "dark" ? "reduce" : "no-preference",
    });
    const page = await context.newPage();
    page.setDefaultTimeout(30_000);
    page.on("dialog", (dialog) => {
      fail(`${scheme}: unexpected ${dialog.type()} "${dialog.message()}"`);
      void dialog.dismiss();
    });
    try {
      await sampleWalk(page, scheme);
      if (scheme === "dark") {
        const endless = await page.evaluate(
          () => document.getAnimations().filter((a) => a.effect?.getTiming().iterations === Infinity).length,
        );
        if (endless) fail(`dark: ${endless} endless animations run with reduced motion`);
      }
    } catch (error) {
      fail(String(error));
      if (shots) await page.screenshot({ path: `${shots}/${scheme}-failed.png` });
    } finally {
      await context.close();
    }
    if (!source) continue;
    const hub = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: scheme });
    const hubPage = await hub.newPage();
    hubPage.setDefaultTimeout(30_000);
    try {
      await hubWalk(hubPage, `${scheme} hub`);
    } catch (error) {
      fail(String(error));
      if (shots) await hubPage.screenshot({ path: `${shots}/${scheme}-hub-failed.png` });
    } finally {
      await hub.close();
    }
  }
} finally {
  await browser.close();
  dev?.kill();
}
console.log(failures.length ? `${failures.length} accessibility failures` : "accessibility pass: no serious or critical violations");
process.exit(failures.length ? 1 : 0);
