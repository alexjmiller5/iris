import { chromium, expect } from "@playwright/test";
import { regressionHub } from "./workspace-regression-hub";
import { disposableOrigin, workspacePage } from "./test-origin";
const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-incoming.localhost:5232/workspace?review";
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source)
  throw Error(
    "Usage: bun scripts/test-incoming-references.ts <life-data-checkout>",
  );
const { server, db } = await regressionHub(source, origin);
const ddl =
  "CREATE TABLE entries(id TEXT PRIMARY KEY, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT, name TEXT, detail TEXT, owner TEXT, related TEXT)";
db.db.exec(ddl);
db.db
  .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
  .run("2026-01-01T00:00:00.000Z", ddl);
db.db
  .exec(`INSERT INTO catalog_tables(id,kind,display) VALUES ('entries','table','name');
 INSERT INTO catalog_properties(id,tbl,col,label,sort,type,ref_table) VALUES
 ('entries.name','entries','name','Name',0,'text',NULL),('entries.detail','entries','detail','Detail',1,'text',NULL),
 ('entries.owner','entries','owner','Owner',2,'ref','widgets'),('entries.related','entries','related','Related',3,'multi_ref','widgets');`);
for (let i = 0; i < 25; i++)
  db.db
    .query(
      "INSERT INTO entries(id,name,detail,owner,related,deleted_at,updated_at,hub_at) VALUES (?,?,?,?,?,?,?,?)",
    )
    .run(
      "e" + String(i).padStart(2, "0"),
      "Entry " + String(i).padStart(2, "0"),
      "Full detail " + i,
      "fixture-record",
      '["fixture-record","second-record","fixture-record"]',
      i === 24 ? "2026-01-01T00:00:00.000Z" : null,
      "2026-01-01T00:00:00.000Z",
      "2026-01-01T00:00:00.000Z",
    );
const browser = await chromium.connectOverCDP(
  process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
);
const page = workspacePage(
  browser.contexts().flatMap((c) => c.pages()),
  url,
);
if (!page) throw Error("Open the reserved incoming relationship fixture first");
let accept = false,
  dialogs = 0;
page.on("pageerror", (e) => console.error("PAGE ERROR", e.message));
page.on("dialog", (d) => {
  dialogs++;
  return accept ? d.accept() : d.dismiss();
});
const failures: string[] = [];
try {
  page.setDefaultTimeout(8000);
  await page.setViewportSize({ width: 1280, height: 960 });
  await page.goto(origin);
  await expect(
    page.getByRole("button", { name: "Open my workspace", exact: true }),
  ).toBeEnabled({ timeout: 30000 });
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.detach();
  await page.addInitScript(() => {
    const state = window as any;
    state.incomingReads = [];
    state.holdIncoming = false;
    state.heldIncoming = [];
    state.failIncoming = false;
    state.failReferenceOpen = false;
    state.releaseIncoming = () => {
      state.holdIncoming = false;
      state.heldIncoming.splice(0).forEach((deliver: any) => deliver());
    };
    const Original = window.Worker;
    window.Worker = class extends Original {
      requests = new Map<number, any>();
      postMessage(message: any, ...args: any[]) {
        this.requests.set(message.id, message);
        if (message.method === "referencedBy")
          state.incomingReads.push(message.args);
        return super.postMessage(message, ...(args as [any]));
      }
      set onmessage(handler: any) {
        super.onmessage = (event) => {
          const request = this.requests.get(event.data.id);
          this.requests.delete(event.data.id);
          const incoming = request?.method === "referencedBy";
          const failOpen =
            state.failReferenceOpen &&
            request?.method === "rows" &&
            request.args?.view?.table === "entries" &&
            request.args.view.filters?.some((f: any) => f.column === "id");
          const deliver = () =>
            handler.call(
              this,
              failOpen || (incoming && state.failIncoming)
                ? {
                    data: {
                      ...event.data,
                      error: {
                        message: failOpen
                          ? "Related record unavailable"
                          : "Relationship source unavailable",
                      },
                    },
                  }
                : event,
            );
          if (incoming && state.holdIncoming) state.heldIncoming.push(deliver);
          else deliver();
        };
      }
    };
  });
  await page.goto(url);
  await page
    .getByRole("button", { name: "Open my workspace", exact: true })
    .click();
  await page
    .getByText("Connect to a hub", { exact: true })
    .click({ timeout: 30000 });
  await page.getByLabel("Hub address").fill(server.url.href.replace(/\/$/, ""));
  const manual = page.getByText("Use a device token", { exact: true });
  if (await manual.count()) await manual.click();
  await page.getByLabel("Device token", { exact: true }).fill("fixture");
  const sync = page.getByRole("button", { name: "Connect", exact: true });
  await sync.click();
  await expect(sync).toBeEnabled({ timeout: 20000 });
  const editor = page.getByRole("complementary", {
    name: "Record editor",
    exact: true,
  });
  const panel = editor.getByRole("region", {
    name: "Referenced by",
    exact: true,
  });
  const group = (name: string) =>
    panel.getByRole("group", { name: "entries / " + name, exact: true });
  async function target(name = "Fixture record") {
    accept = true;
    await page.evaluate(() => (window as any).releaseIncoming());
    if (await editor.isVisible())
      await editor
        .getByRole("button", { name: "Close record", exact: true })
        .click();
    await page.getByRole("button", { name: "widgets", exact: true }).click();
    await page.getByRole("button", { name, exact: true }).click();
    await expect(panel).toBeVisible();
    accept = false;
  }
  async function check(name: string, run: () => Promise<void>) {
    if (
      process.env.LIFE_UI_INCOMING_CASE &&
      !name.includes(process.env.LIFE_UI_INCOMING_CASE)
    )
      return;
    try {
      await target();
      await run();
      console.log("PASS: " + name);
    } catch (e) {
      failures.push(name);
      console.error("FAIL: " + name + "\n" + e);
    } finally {
      await page.evaluate(() => {
        const s = window as any;
        s.failIncoming = false;
        s.failReferenceOpen = false;
        s.releaseIncoming();
      });
    }
  }
  await check(
    "metadata is lazy and group pages are bounded, deduplicated and live-only",
    async () => {
      expect(await page.evaluate(() => (window as any).incomingReads)).toEqual(
        [],
      );
      await group("Owner").locator("summary").click();
      await expect(
        group("Owner").getByRole("button", { name: /^Open Entry/ }),
      ).toHaveCount(20);
      await group("Owner")
        .getByRole("button", { name: "Load more", exact: true })
        .click();
      await expect(
        group("Owner").getByRole("button", { name: /^Open Entry/ }),
      ).toHaveCount(24);
      await expect(
        group("Owner").getByRole("button", { name: "Load more", exact: true }),
      ).toHaveCount(0);
      await group("Related").locator("summary").click();
      await group("Related")
        .getByRole("button", { name: "Load more", exact: true })
        .click();
      await expect(
        group("Related").getByRole("button", { name: /^Open Entry/ }),
      ).toHaveCount(24);
      const reads = await page.evaluate(() => (window as any).incomingReads);
      expect(reads.map((r: any) => r.offset)).toEqual([0, 20, 0, 20]);
      expect(
        reads.every((r: any) => r.limit === 20 && r.rowId === "fixture-record"),
      ).toBe(true);
      await expect(page.locator('[data-pending="0"]')).toBeVisible();
    },
  );
  await check(
    "incoming navigation preserves a cancelled draft and opens a fresh full source record",
    async () => {
      await group("Owner").locator("summary").click();
      await editor
        .getByRole("textbox", { name: "Title", exact: true })
        .fill("Keep this draft");
      const priorDialogs = dialogs;
      await group("Owner")
        .getByRole("button", { name: "Open Entry 00", exact: true })
        .click();
      await expect.poll(() => dialogs).toBe(priorDialogs + 1);
      await expect(
        group("Owner").getByRole("button", {
          name: "Open Entry 00",
          exact: true,
        }),
      ).toBeEnabled();
      await expect(
        editor.getByRole("textbox", { name: "Title", exact: true }),
      ).toHaveValue("Keep this draft");
      accept = true;
      await group("Owner")
        .getByRole("button", { name: "Open Entry 00", exact: true })
        .click();
      await expect(editor.getByLabel("Name", { exact: true })).toHaveValue(
        "Entry 00",
      );
      await expect(editor.getByLabel("Detail", { exact: true })).toHaveValue(
        "Full detail 0",
      );
      await expect(page.locator('[data-pending="0"]')).toBeVisible();
    },
  );
  await check(
    "a failed group offers retry without removing another group",
    async () => {
      await page.evaluate(() => ((window as any).failIncoming = true));
      await group("Owner").locator("summary").click();
      await expect(group("Owner").getByRole("alert")).toHaveText(
        "Relationship source unavailable",
      );
      await page.evaluate(() => ((window as any).failIncoming = false));
      await group("Related").locator("summary").click();
      await expect(
        group("Related").getByRole("button", { name: /^Open Entry/ }),
      ).toHaveCount(20);
      await group("Owner")
        .getByRole("button", { name: "Retry", exact: true })
        .click();
      await expect(
        group("Owner").getByRole("button", { name: /^Open Entry/ }),
      ).toHaveCount(20);
    },
  );
  await check(
    "late group replies cannot populate a different record",
    async () => {
      await page.evaluate(() => ((window as any).holdIncoming = true));
      await group("Owner").locator("summary").click();
      await page.waitForFunction(
        () => (window as any).heldIncoming.length === 1,
      );
      await editor
        .getByRole("button", { name: "Close record", exact: true })
        .click();
      await page
        .getByRole("button", { name: "Second record", exact: true })
        .click();
      await page.evaluate(() => (window as any).releaseIncoming());
      await group("Owner").locator("summary").click();
      await expect(
        group("Owner").getByText("No local records reference this record.", {
          exact: true,
        }),
      ).toBeVisible();
      await expect(
        group("Owner").getByRole("button", { name: /^Open Entry/ }),
      ).toHaveCount(0);
    },
  );
  await check(
    "relationships fit narrow screens and remain keyboard accessible",
    async () => {
      await group("Owner").locator("summary").click();
      await page.setViewportSize({ width: 390, height: 900 });
      await panel.scrollIntoViewIfNeeded();
      await page.screenshot({ path: "/tmp/life-ui-incoming-390.png" });
      await page.emulateMedia({ colorScheme: "dark" });
      await page.screenshot({ path: "/tmp/life-ui-incoming-390-dark.png" });
      await page.emulateMedia({ colorScheme: "light" });
      expect(
        await page.evaluate(() => document.documentElement.scrollWidth),
      ).toBeLessThanOrEqual(390);
      const button = group("Owner").getByRole("button", {
        name: "Open Entry 00",
        exact: true,
      });
      await button.focus();
      await page.keyboard.press("Enter");
      await expect(editor.getByLabel("Detail", { exact: true })).toHaveValue(
        "Full detail 0",
      );
      await page.setViewportSize({ width: 1280, height: 960 });
    },
  );
  await check(
    "failed relationship navigation is visible above a narrow-screen draft",
    async () => {
      await group("Owner").locator("summary").click();
      await editor
        .getByRole("textbox", { name: "Title", exact: true })
        .fill("Keep after failure");
      await page.setViewportSize({ width: 390, height: 900 });
      await page.evaluate(() => ((window as any).failReferenceOpen = true));
      await group("Owner")
        .getByRole("button", { name: "Open Entry 00", exact: true })
        .click();
      await expect(
        editor.getByText("Related record unavailable", { exact: true }),
      ).toBeVisible();
      await editor
        .getByText("Related record unavailable", { exact: true })
        .scrollIntoViewIfNeeded();
      await expect(
        editor.getByText("Related record unavailable", { exact: true }),
      ).toBeInViewport();
      await expect(
        editor.getByRole("textbox", { name: "Title", exact: true }),
      ).toHaveValue("Keep after failure");
      await page.setViewportSize({ width: 1280, height: 960 });
    },
  );
  await check(
    "catalog edits refresh incoming group names without discarding the record draft",
    async () => {
      await group("Owner").locator("summary").click();
      await editor
        .getByRole("textbox", { name: "Title", exact: true })
        .fill("Keep during metadata sync");
      const revision = new Date().toISOString();
      db.db
        .query(
          "UPDATE catalog_properties SET label=?,updated_at=?,hub_at=? WHERE id=?",
        )
        .run("Guardian", revision, revision, "entries.owner");
      await sync.click();
      await expect(sync).toBeEnabled({ timeout: 20000 });
      await expect(group("Guardian")).toBeVisible();
      await expect(group("Owner")).toHaveCount(0);
      await expect(
        editor.getByRole("textbox", { name: "Title", exact: true }),
      ).toHaveValue("Keep during metadata sync");
      const restored = new Date().toISOString();
      db.db
        .query(
          "UPDATE catalog_properties SET label=?,updated_at=?,hub_at=? WHERE id=?",
        )
        .run("Owner", restored, restored, "entries.owner");
      await sync.click();
      await expect(sync).toBeEnabled({ timeout: 20000 });
      await expect(group("Owner")).toBeVisible();
    },
  );
  await check(
    "a newly partial replica updates the open relationship warning",
    async () => {
      await group("Owner").locator("summary").click();
      await expect(
        group("Owner").getByRole("button", { name: /^Open Entry/ }),
      ).toHaveCount(20);
      await page.getByLabel("Automatic sync row limit").fill("5");
      await sync.click();
      await expect(sync).toBeEnabled({ timeout: 20000 });
      // Keep this record open while the replica's coverage changes.
      const summary = group("Owner").locator("summary");
      if (
        !(await group("Owner").evaluate((e) => (e as HTMLDetailsElement).open))
      )
        await summary.click();
      await expect(
        group("Owner").getByText(
          "Local relationships may be incomplete. Some tables are not fully downloaded.",
          { exact: true },
        ),
      ).toBeVisible();
      await page.getByLabel("Automatic sync row limit").fill("50000");
      await sync.click();
      await expect(sync).toBeEnabled({ timeout: 20000 });
      if (
        !(await group("Owner").evaluate((e) => (e as HTMLDetailsElement).open))
      )
        await summary.click();
      await expect(
        group("Owner").getByText(
          "Local relationships may be incomplete. Some tables are not fully downloaded.",
          { exact: true },
        ),
      ).toHaveCount(0);
    },
  );
  await check(
    "new records have no incoming panel until their first save",
    async () => {
      await editor
        .getByRole("button", { name: "Close record", exact: true })
        .click();
      await page
        .getByRole("button", { name: "New record", exact: true })
        .click();
      await expect(editor).toBeVisible();
      await expect(panel).toHaveCount(0);
    },
  );
  if (failures.length) throw Error(failures.join("; "));
} catch (e) {
  console.error("VISIBLE PAGE", await page.locator("body").innerText());
  throw e;
} finally {
  accept = true;
  await page
    .evaluate(() => (window as any).releaseIncoming?.())
    .catch(() => {});
  const exit = page.getByRole("button", {
    name: "Switch workspace",
    exact: true,
  });
  if (await exit.isVisible()) await exit.click().catch(() => {});
  await expect
    .poll(() => page.workers().length)
    .toBe(0)
    .catch(() => {});
  await page.goto(url).catch(() => {});
  await browser.close();
  server.stop(true);
  db.db.close();
}
