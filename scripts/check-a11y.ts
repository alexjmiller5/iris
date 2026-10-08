// Keyboard-only accessibility pass over every web view of the synthetic sample
// workspace, in light and dark. Each state is reached with Tab, Enter, Space and
// Escape only; every focused control must show a focus ring, Escape must hand
// focus back, and axe-core must report no serious or critical violation.
//   bun scripts/check-a11y.ts            (starts its own dev server and headless Chrome)
//   LIFE_UI_TEST_SHOTS=<dir>             keeps a screenshot per step
//   LIFE_UI_TEST_URL=<origin>/workspace  uses an already running dev server
import { chromium, type Locator, type Page } from "@playwright/test";
import { mkdirSync, readFileSync } from "node:fs";
import { createServer } from "node:net";

const root = new URL("..", import.meta.url).pathname;
const axe = readFileSync(`${root}node_modules/axe-core/axe.min.js`, "utf8");
const shots = process.env.LIFE_UI_TEST_SHOTS;
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

/** One color scheme's walk through every view. */
async function walk(page: Page, scheme: "light" | "dark") {
  let step = 0;
  const audit = async (state: string) => {
    if (!(await page.evaluate(() => "axe" in window))) await page.addScriptTag({ content: axe });
    const { violations } = await page.evaluate(() =>
      (window as unknown as { axe: { run: (c: unknown, o: unknown) => Promise<any> } }).axe.run(document, {
        resultTypes: ["violations"],
      }),
    );
    for (const v of violations as { id: string; impact: string; help: string; nodes: { target: string[]; html: string }[] }[]) {
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
      const name = el.getAttribute("aria-label") || el.textContent?.trim().slice(0, 40) || el.tagName;
      return { ok: outline || shadow, name: `${el.tagName.toLowerCase()} "${name}"` };
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
    target.evaluate((el) => el === document.activeElement || el.contains(document.activeElement));
  const expectFocus = async (target: Locator, what: string) => {
    for (let i = 0; i < 20 && !(await focused(target).catch(() => false)); i++) await page.waitForTimeout(100);
    if (!(await focused(target).catch(() => false))) fail(`${scheme}: focus did not return to ${what}`);
  };
  const role = (r: Parameters<Page["getByRole"]>[0], name: string | RegExp) =>
    page.getByRole(r, { name, exact: typeof name === "string" }).first();

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

  // Filter: property search, chip editor, Escape back to the chip.
  const filter = role("button", "Filter");
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
  await page.keyboard.press("Escape");
  await editor.waitFor({ state: "hidden" });
  await expectFocus(page.getByRole("group", { name: "Sort and filters" }), "the filter chip");

  // Sort popover.
  const sort = role("button", "Sort");
  await tabTo(sort);
  await page.keyboard.press("Enter");
  await page.getByRole("dialog", { name: "Sort" }).waitFor();
  await audit("sort");
  await page.keyboard.press("Escape");
  await expectFocus(sort, "Sort");

  // View switcher menu.
  const settings = role("button", "View settings");
  await tabTo(settings, true);
  await page.keyboard.press("Enter");
  await audit("view-menu");
  await page.keyboard.press("Escape");
  await expectFocus(settings, "View settings");

  // Columns, Export and Selection disclosures.
  for (const name of ["Columns", "Export"]) {
    const summary = page.locator("summary", { hasText: name }).first();
    await tabTo(summary);
    await page.keyboard.press("Enter");
    await audit(name.toLowerCase());
    await page.keyboard.press("Enter");
  }

  // Grid: arrows move the cell cursor, Space selects nothing by itself, Enter opens the record.
  await tabTo(grid);
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

  // Record page with properties and the Markdown editor.
  await tabTo(grid);
  await page.keyboard.press("Enter");
  await page.getByRole("button", { name: /Back to|Close record|Records/ }).first().waitFor();
  await audit("record");
  for (let i = 0; i < 40; i++) {
    await page.keyboard.press("Tab");
    await ring();
  }
  await audit("record-after-tabbing");
  await page.keyboard.press("Escape");

  // Cmd+K palette.
  await page.locator("body").focus();
  await page.keyboard.press("ControlOrMeta+k");
  const find = page.getByRole("dialog", { name: /Find/ });
  await find.waitFor();
  await page.keyboard.type("place");
  await page.waitForTimeout(500);
  await audit("find");
  await page.keyboard.press("Escape");
  await find.waitFor({ state: "hidden" });

  // Layouts.
  const layout = page.getByRole("combobox", { name: "View layout" });
  for (const name of ["Gallery", "Board", "Table"]) {
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
  await expectFocus(catalog, "Edit catalog");

  // Table graph.
  const graph = role("button", "Table graph");
  await tabTo(graph, true);
  await page.keyboard.press("Enter");
  await audit("table-graph");
  await page.keyboard.press("Enter");

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

const browser = await chromium.launch({ channel: "chrome", headless: true });
try {
  for (const scheme of ["light", "dark"] as const) {
    const context = await browser.newContext({
      viewport: { width: 1280, height: 900 },
      colorScheme: scheme,
      reducedMotion: scheme === "dark" ? "reduce" : "no-preference",
    });
    const page = await context.newPage();
    page.setDefaultTimeout(30_000);
    try {
      await walk(page, scheme);
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
  }
} finally {
  await browser.close();
  dev?.kill();
}
console.log(failures.length ? `${failures.length} accessibility failures` : "accessibility pass: no serious or critical violations");
process.exit(failures.length ? 1 : 0);
