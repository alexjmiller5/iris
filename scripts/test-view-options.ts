// View settings on a synthetic hub: the Today day boundary with the app's own
// rollover timer, timezone and foreground refresh; filter group rules switching
// between numeric and boolean properties; row actions with dynamic choices and the
// displayed-revision guard. Open the reserved review page in a disposable Chrome, then
//   LIFE_UI_TEST_CDP=<endpoint> bun scripts/test-view-options.ts <life-data-checkout> [all|rollover|options|actions]
import { chromium, expect as base } from "@playwright/test";
import { installCoreSchemas, logDDL, regressionHub } from "./workspace-regression-hub";
import { disposableOrigin, workspacePage } from "./test-origin";

const expect = base.configure({ timeout: 15000 });
const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-markdown.localhost:5198/workspace?review";
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source) throw Error("Provide the Life Data source checkout");
const mode = process.argv[3] ?? "all";
const shots = process.env.LIFE_UI_TEST_SHOTS;
const { server, db, auth } = await regressionHub(source, origin);
await installCoreSchemas(db, source, ["saved-views", "view-defaults"]);
for (const ddl of [
  "ALTER TABLE widgets ADD COLUMN due TEXT",
  "ALTER TABLE widgets ADD COLUMN done INTEGER",
  "ALTER TABLE widgets ADD COLUMN related TEXT",
])
  logDDL(db, ddl);
db.db.exec(`INSERT INTO catalog_properties(id,tbl,col,type,label,ref_table) VALUES
  ('widgets.due','widgets','due','date','Due',NULL),
  ('widgets.done','widgets','done','bool','Done',NULL),
  ('widgets.related','widgets','related','ref','Related','widgets');
  UPDATE widgets SET due='2026-06-01' WHERE id='fixture-record';
  UPDATE widgets SET due='2026-06-02' WHERE id='second-record';`);
db.db.query("INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)").run(
  "late-day",
  "Late day",
  "widgets",
  JSON.stringify({
    version: 2,
    filters: [{ column: "due", op: "lte", relative: "today" }],
    timeZone: "America/New_York",
    dayStartMinutes: 180,
  }),
);
const catalogDefault = `catalog-default:v1:${Buffer.from("widgets").toString("hex")}`;
const browser = await chromium.connectOverCDP(
  process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
);
let ownedPage: import("@playwright/test").Page | undefined;
try {
  const page = (ownedPage = workspacePage(
    browser.contexts().flatMap((c) => c.pages()),
    url,
  ));
  if (!page) throw Error("Open the reserved review page first");
  page.setDefaultTimeout(15000);
  await page.bringToFront();
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(new URL("/", url).href);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.detach();
  await page.goto(url);
  await page
    .getByRole("button", { name: "Open my workspace", exact: true })
    .click({ timeout: 30000 });
  await page.getByText("Connect to a hub", { exact: true }).click({ timeout: 30000 });
  await page.getByText("Use a device token", { exact: true }).click();
  await page.getByLabel("Hub address").fill(server.url.href.replace(/\/$/, ""));
  await page.getByLabel("Device token").fill("fixture");
  await page.getByRole("button", { name: "Connect", exact: true }).click();
  await page
    .getByRole("navigation", { name: "Tables" })
    .getByRole("button", { name: "widgets", exact: true })
    .click();
  const views = page.getByRole("combobox", { name: "View", exact: true });
  const menu = page.getByRole("dialog", { name: "View settings", exact: true });
  const settings = async (section: string) => {
    if (!(await menu.isVisible()))
      await page.getByRole("button", { name: "View settings", exact: true }).click();
    const details = menu.locator("details", {
      has: page.locator("summary", { hasText: section }),
    });
    if (!(await details.evaluate((e: HTMLDetailsElement) => e.open)))
      await details.locator("summary").click();
  };
  const rows = (labels: string[]) =>
    expect(page.locator(".record-link")).toHaveText(labels, { timeout: 20000 });
  const set = async (label: string, value: string) => {
    const control = menu.getByLabel(label, { exact: true });
    await control.fill(value);
    await control.dispatchEvent("change");
  };
  const saveAs = async (name: string) => {
    const before = await views.inputValue();
    await menu.getByLabel("View name", { exact: true }).fill(name);
    await menu.getByRole("button", { name: "Save as new view", exact: true }).click();
    await expect(views).not.toHaveValue(before);
    return views.inputValue();
  };
  const shot = async (name: string) => {
    if (shots) await page.screenshot({ path: `${shots}/${name}.png` });
  };
  await expect(views).toHaveValue(catalogDefault);
  await rows(["Fixture record", "Legacy record", "Second record"]);
  if (mode === "all" || mode === "options") {
    await views.selectOption(catalogDefault);
    const editor = page.getByRole("dialog", { name: "Edit filter", exact: true });
    await page.getByRole("button", { name: /^Filter(, \d+ active)?$/ }).click();
    await page.getByRole("button", { name: "Add filter group", exact: true }).click();
    await editor.getByLabel("Property", { exact: true }).selectOption("quantity");
    await editor.getByLabel("Condition", { exact: true }).selectOption("eq");
    await editor.getByLabel("Value", { exact: true }).fill("42");
    await rows(["Fixture record", "Legacy record", "Second record"]);
    await editor.getByLabel("Property", { exact: true }).selectOption("done");
    await expect(editor.getByRole("radio", { name: "Checked", exact: true })).toBeChecked();
    await editor.getByText("Unchecked", { exact: true }).click();
    await expect(editor.getByRole("radio", { name: "Unchecked", exact: true })).toBeChecked();
    await editor.getByRole("button", { name: "Remove group", exact: true }).click();
    await expect(editor).toBeHidden();
    await expect(page.getByRole("button", { name: /^Remove filter/ })).toHaveCount(0);
    console.log("PASS: numeric and boolean group rule property changes stay editable");
  }
  if (mode === "all" || mode === "actions") {
    await views.selectOption(catalogDefault);
    await settings("Row actions");
    await menu.getByRole("button", { name: "Add action", exact: true }).click();
    const add = menu.getByLabel("Add value to action 1", { exact: true });
    const value = (column: string) => menu.locator(`select[id^="action-"][id$="-${column}"]`);
    await add.selectOption("status");
    await expect(value("status").locator('option[value="Dynamic"]')).toHaveCount(1);
    await value("status").selectOption("Dynamic");
    await add.selectOption("tags");
    await expect(value("tags").locator('option[value="Dynamic"]')).toHaveCount(1);
    await value("tags").selectOption(["Dynamic"]);
    await add.selectOption("related");
    await menu.getByLabel("Search Related", { exact: true }).fill("Second");
    await expect(value("related").locator('option[value="second-record"]')).toHaveCount(1);
    await value("related").selectOption("second-record");
    await set("Button label", "Apply choices");
    await expect(value("related").locator('option[value="fixture-record"]')).toHaveCount(0);
    await expect(menu.getByLabel("Search Related", { exact: true })).toHaveValue("Second");
    const actionView = await saveAs("Action choices");
    await page.keyboard.press("Escape");
    // Another device changes the saved action; the grid keeps this tab's displayed revision.
    await expect
      .poll(() => (db.db.query("SELECT definition FROM views WHERE id=?").get(actionView) as any)?.definition, { timeout: 20000 })
      .toContain("Apply choices");
    const stored = JSON.parse((db.db.query("SELECT definition FROM views WHERE id=?").get(actionView) as any).definition);
    const remote = new Date(Date.now() + 1000).toISOString();
    db.db
      .query("UPDATE views SET name=?,definition=?,updated_at=?,hub_at=? WHERE id=?")
      .run(
        "Changed elsewhere",
        JSON.stringify({ ...stored, actions: stored.actions.map((a: any) => ({ ...a, values: { title: "Unexpected external action" } })) }),
        remote,
        remote,
        actionView,
      );
    await expect(views.locator("option", { hasText: "Changed elsewhere" })).toHaveCount(1, { timeout: 20000 });
    await page
      .getByRole("grid", { name: "Records" })
      .getByRole("button", { name: "Apply choices", exact: true })
      .first()
      .click();
    await expect(
      page.getByText("Saved view changed. Reload it before running this action."),
    ).toBeVisible();
    await rows(["Fixture record", "Legacy record", "Second record"]);
    await shot("action-guard");
    console.log(
      "PASS: dynamic action choices, retained reference search and frozen displayed revision guard",
    );
  }
  if (mode === "all" || mode === "rollover") {
    // Date advances with real elapsed time, so the app's actual rollover timer fires.
    // This override is page-local and is discarded by the next navigation; it runs
    // last so the other modes keep the real clock.
    await page.evaluate(() => {
      const NativeDate = Date,
        epoch = NativeDate.parse("2026-06-02T06:59:50Z"),
        start = NativeDate.now();
      const w = window as any;
      w.__viewClockOffset = 0;
      w.Date = class extends NativeDate {
        constructor(...args: any[]) {
          super(...((args.length ? args : [epoch + NativeDate.now() - start + w.__viewClockOffset]) as []));
        }
        static now() {
          return epoch + NativeDate.now() - start + w.__viewClockOffset;
        }
      };
    });
    await views.selectOption("late-day");
    await rows(["Fixture record"]);
    await settings("Today");
    await expect(menu.getByLabel("Day starts at", { exact: true })).toHaveValue("03:00");
    await rows(["Fixture record", "Second record"]);
    await shot("rollover");
    await set("Day starts at", "04:00");
    await rows(["Fixture record"]);
    const copied = await saveAs("Boundary copy");
    expect(copied).not.toBe("late-day");
    await views.selectOption(catalogDefault);
    await expect(menu.getByLabel("Day starts at", { exact: true })).toHaveValue("00:00");
    await views.selectOption(copied);
    await expect(menu.getByLabel("Day starts at", { exact: true })).toHaveValue("04:00");
    await rows(["Fixture record"]);
    await set("Today timezone", "UTC");
    await rows(["Fixture record", "Second record"]);
    await set("Today timezone", "America/New_York");
    await rows(["Fixture record"]);
    await page.evaluate(() => {
      (window as any).__viewClockOffset += 86400000;
      window.dispatchEvent(new Event("focus"));
    });
    await rows(["Fixture record", "Second record"]);
    await page.keyboard.press("Escape");
    console.log(
      "PASS: 02:59/03:00 actual timer, policy/timezone refresh, save/reopen, midnight reset and foreground refresh",
    );
  }
} catch (error) {
  console.error(
    "DIAGNOSTIC",
    await ownedPage?.evaluate(() => ({ url: location.href, body: document.body.innerText.slice(-1800) })).catch(() => null),
  );
  throw error;
} finally {
  if (ownedPage) {
    await ownedPage.goto(new URL("/", url).href).catch(() => {});
    const cleanup = await ownedPage.context().newCDPSession(ownedPage).catch(() => null);
    await cleanup?.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" }).catch(() => {});
    await cleanup?.detach().catch(() => {});
    await ownedPage.goto(url).catch(() => {});
  }
  await browser.close();
  server.stop(true);
  db.db.close();
  auth.db.close();
}
