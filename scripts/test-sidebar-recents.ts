import { chromium, expect, type Page } from "@playwright/test";
import { resolve } from "node:path";
import { mkdir } from "node:fs/promises";
import { disposableOrigin, recordReady, workspacePage } from "./test-origin";
import { regressionHub } from "./workspace-regression-hub";

const url =
  process.env.IRIS_TEST_URL ??
  "http://iris-recents.localhost:5236/workspace?review";
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source)
  throw Error(
    "Usage: bun scripts/test-sidebar-recents.ts <soma-checkout>",
  );
const { server, db, auth } = await regressionHub(source, origin);
const schema = await Bun.file(
  resolve(import.meta.dir, "../packages/core/schema/saved-views.json"),
).json();
for (const ddl of [
  "ALTER TABLE catalog_properties ADD COLUMN source TEXT",
  "ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT",
  "CREATE TABLE projects (id TEXT PRIMARY KEY,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT,headline TEXT,detail TEXT)",
  ...schema.ddl,
]) {
  db.db.exec(ddl);
  db.db
    .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
    .run("2026-01-01T00:00:00.000Z", ddl);
}
for (const [table, records] of [
  ["catalog_tables", [schema.table]],
  ["catalog_properties", schema.properties],
] as const) {
  for (const record of records) {
    const columns = Object.keys(record);
    db.db
      .query(
        `INSERT INTO ${table} (${columns.map((c) => '"' + c + '"').join(",")}) VALUES (${columns.map(() => "?").join(",")})`,
      )
      .run(...Object.values(record));
  }
}
db.db.exec(`
	INSERT INTO catalog_tables(id,kind,display) VALUES ('projects','table','headline');
	INSERT INTO catalog_properties(id,tbl,col,label,sort,type) VALUES
	('projects.headline','projects','headline','Headline',0,'text'),
	('projects.detail','projects','detail','Detail',1,'text');
	INSERT INTO projects(id,headline,detail,updated_at,hub_at) VALUES ('project-record','Project signal','Hidden detail','2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z');
	UPDATE widgets SET body='# Astronomía\n\nA telescope observes nebulas.' WHERE id='fixture-record';
`);
for (const [id, table, name, definition] of [
  ["widget-view", "widgets", "Pinned", { version: 1, columns: ["title"] }],
  [
    "project-view",
    "projects",
    "Pinned",
    {
      version: 1,
      columns: ["headline"],
      filters: [{ column: "headline", op: "eq", value: "Project signal" }],
    },
  ],
  ["future-view", "widgets", "Future view", { version: 99 }],
  [
    "delete-view",
    "projects",
    "Disposable view",
    { version: 1, columns: ["headline"] },
  ],
] as const)
  db.db
    .query("INSERT INTO views(id,tbl,name,definition) VALUES (?,?,?,?)")
    .run(id, table, name, JSON.stringify(definition));
db.db.exec(
  "INSERT INTO catalog_tables(id,kind,display) VALUES ('catalog_tables','system','id')",
);
console.log("CONNECT");
const browser = await chromium.connectOverCDP(
  process.env.IRIS_TEST_CDP ?? "http://127.0.0.1:9222",
  { timeout: 30000 },
);
const page = workspacePage(
  browser.contexts().flatMap((c) => c.pages()),
  url,
);
if (!page) throw Error("Open the reserved recents fixture page first");
page.setDefaultTimeout(10000);
page.on("console", (m) => {
  if (m.type() === "error") console.error("CONSOLE:", m.text());
});
page.on("requestfailed", (r) =>
  console.error("REQUEST FAILED:", new URL(r.url()).pathname, r.failure()),
);
let accept = true,
  dialogs = 0;
page.on("dialog", (dialog) => {
  dialogs++;
  return accept ? dialog.accept() : dialog.dismiss();
});
page.on("pageerror", (error) => console.error("PAGE ERROR:", error.message));
await page.addInitScript(() => {
  const state = window as any;
  state.activeWorkers = new Set();
  state.hold = null;
  state.held = [];
  state.calls = [];
  state.release = () => {
    state.hold = null;
    state.held.splice(0).forEach((f: () => void) => f());
  };
  const Original = window.Worker;
  window.Worker = class extends Original {
    requests = new Map<number, any>();
    constructor(...args: ConstructorParameters<typeof Worker>) {
      super(...args);
      state.activeWorkers.add(this);
    }
    terminate() {
      state.activeWorkers.delete(this);
      super.terminate();
    }
    postMessage(request: any, ...args: any[]) {
      this.requests.set(request.id, request);
      state.calls.push(request);
      super.postMessage(request, ...(args as [any]));
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
const recents = page.getByRole("navigation", {
  name: "Recent destinations",
  exact: true,
});
const tables = page.getByRole("navigation", { name: "Tables", exact: true });
const editor = page.getByRole("complementary", {
  name: "Record editor",
  exact: true,
});
// Recent destinations are named by their visible title and context.
const recent = (label: string) =>
  recents
    .locator(".destination")
    .filter({
      has: page.locator("strong", {
        hasText: new RegExp(`^${label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`),
      }),
    })
    .first();
async function closeFixture() {
  accept = true;
  await page!.evaluate(() => (window as any).release?.());
  const leave = page!.getByRole("button", {
    name: "Switch workspace",
    exact: true,
  });
  if (await leave.count()) await leave.click();
  await page!.waitForFunction(
    () => !(window as any).activeWorkers?.size,
    undefined,
    { timeout: 15000 },
  );
}
async function ready() {
  await expect(page!.getByRole("button", { name: /Find records/ })).toBeEnabled(
    { timeout: 30000 },
  );
}
try {
  await closeFixture();
  await page.goto(new URL("/", url).href);
  await expect(
    page.getByRole("button", { name: "Open my workspace", exact: true }),
  ).toBeEnabled({ timeout: 30000 });
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.detach();
  await page.goto(url);
  await page
    .getByRole("button", { name: "Open my workspace", exact: true })
    .click();
  await ready();
  await page.getByText("Connect to a hub", { exact: true }).click();
  await page.getByLabel("Hub address").fill(server.url.href.replace(/\/$/, ""));
  await page.getByText("Use a device token", { exact: true }).click();
  await page.getByLabel("Device token").fill("fixture");
  await page.getByRole("button",{name:"Connect",exact:true}).click();
  await tables
    .getByRole("button", { name: "widgets", exact: true })
    .click({ timeout: 30000 });
  await expect(
    page.getByRole("button", { name: "Fixture record", exact: true }),
  ).toBeVisible({ timeout: 30000 });
  await expect(recents).toBeVisible();
  await expect(recent("widgets")).toBeEnabled();
  console.log("PASS: successful table navigation records a destination");
  await expect(
    page.getByRole("button", { name: "Fixture record", exact: true }),
  ).toBeVisible();
  const title = () =>
    editor.getByRole("textbox", { name: "Title", exact: true });
  const saveStatus = page.locator('[aria-label="Record save status"]');
  const query = () => new URL(page.url()).searchParams;
  const stored = () =>
    page.evaluate(
      () =>
        JSON.parse(
          localStorage.getItem("iris:recents:workspace") ?? '{"entries":[]}',
        ).entries,
    );
  async function settled() {
    await expect(recents.getByText("Loading…", { exact: true })).toHaveCount(0);
  }
  async function navigateTable(name: string) {
    await tables.getByRole("button", { name, exact: true }).click();
    await expect.poll(() => query().get("table")).toBe(name);
    await expect
      .poll(async () => (await stored())[0])
      .toEqual({ table: name, view: null, row: null });
    await settled();
  }
  async function home() {
    accept = true;
    await page.evaluate(() => (window as any).release());
    if (await editor.isVisible())
      await page
        .getByRole("button", { name: "Close record", exact: true })
        .click();
    await navigateTable("widgets");
  }
  async function run(name: string, action: () => Promise<void>) {
    if (
      process.env.IRIS_RECENTS_CASE &&
      !name.includes(process.env.IRIS_RECENTS_CASE)
    )
      return;
    console.log("RUN:", name);
    await home();
    await action();
    console.log("PASS:", name);
  }
  async function external(change: "rename" | "trash" | "deleteView") {
    await page.evaluate(async (change) => {
      const { WorkspaceDatabase } = await import("/src/lib/database.ts");
      const db = new WorkspaceDatabase();
      try {
        await db.request("open");
        if (change === "deleteView") {
          const { views } = await db.request("listViews", {
            table: "projects",
          });
          const view = views.find((v: any) => v.id === "delete-view");
          await db.request("deleteView", {
            id: view.id,
            expectedUpdatedAt: view.updated_at,
          });
        } else {
          const rows = await db.request("rows", {
            view: {
              table: "widgets",
              filters: [{ column: "id", op: "eq", value: "fixture-record" }],
              limit: 1,
            },
          });
          await db.request("write", {
            table: "widgets",
            patch:
              change === "rename"
                ? { id: "fixture-record", title: "Current record label" }
                : { id: "fixture-record", deleted_at: true },
            expectedUpdatedAt: rows[0].updated_at,
          });
        }
      } finally {
        db.close();
      }
    }, change);
  }
  await run(
    "table view and full record navigate by stable IDs; rename resolves current labels",
    async () => {
      await page
        .getByRole("combobox", { name: "View", exact: true })
        .selectOption("widget-view");
      await expect(recent("Pinned")).toBeEnabled();
      await page
        .getByRole("button", { name: "Fixture record", exact: true })
        .click();
      await expect(recent("Fixture record")).toBeEnabled();
      await expect(
        editor.getByLabel("Quantity", { exact: true }),
      ).toHaveValue("42");
      expect((await stored()).slice(0, 3)).toEqual([
        { table: "widgets", view: "widget-view", row: "fixture-record" },
        { table: "widgets", view: "widget-view", row: null },
        { table: "widgets", view: null, row: null },
      ]);
      await tables
        .getByRole("button", { name: "projects", exact: true })
        .click();
      await settled();
      await external("rename");
      await expect(recent("Current record label")).toBeEnabled();
      await recent("Current record label").click();
      await expect(title()).toHaveValue("Current record label");
      await expect.poll(() => query().get("view")).toBe("widget-view");
      await expect.poll(() => query().get("row")).toBe("fixture-record");
    },
  );
  await run(
    "cancelled discard retains draft URL and recency; accepted navigation completes",
    async () => {
      await navigateTable("projects");
      await home();
      await page
        .getByRole("button", {
          name: /^(Fixture record|Current record label)$/,
          exact: true,
        })
        .click();
      await settled();
      await title().fill("Unsaved draft");
      const before = await stored(),
        address = page.url(),
        confirmations = dialogs;
      accept = false;
      await recent("projects").click();
      await expect.poll(() => dialogs).toBe(confirmations + 1);
      await expect(title()).toHaveValue("Unsaved draft");
      expect(page.url()).toBe(address);
      expect(await stored()).toEqual(before);
      accept = true;
      await recent("projects").click();
      await expect(editor).not.toBeVisible();
      await expect.poll(() => query().get("table")).toBe("projects");
      expect((await stored())[0]).toEqual({
        table: "projects",
        view: null,
        row: null,
      });
    },
  );
  await run(
    "autosaves do not recreate a removed recent and a pending receipt leaves navigation open",
    async () => {
      await navigateTable("projects");
      await home();
      await page
        .getByRole("button", {
          name: /^(Fixture record|Current record label)$/,
          exact: true,
        })
        .click();
      await recordReady(page);
      await settled();
      const label = await title().inputValue();
      await recents
        .getByRole("button", {
          name: `Remove ${label} from recents`,
          exact: true,
        })
        .first()
        .click();
      await settled();
      const before = await stored();
      await page.evaluate(() => ((window as any).hold = "write"));
      await title().fill("Saved without bump");
      await page.evaluate(() =>
        (document.activeElement as HTMLElement | null)?.blur(),
      );
      await page.waitForFunction(() => (window as any).held.length === 1);
      // Leaving saves pending edits first and a held write still lands, so navigation stays open.
      await expect(recent("projects")).toBeEnabled();
      expect(query().get("row")).toBe("fixture-record");
      await page.evaluate(() => (window as any).release());
      await expect(saveStatus).toHaveAttribute("data-state", "saved");
      await settled();
      expect(await stored()).toEqual(before);
      expect(
        (await stored()).some(
          (d: any) => d.row === "fixture-record" && d.view === null,
        ),
      ).toBe(false);
    },
  );
  await run(
    "late recent lookup cannot replace a newer navigation or reorder history",
    async () => {
      await navigateTable("projects");
      await home();
      await page.evaluate(() => ((window as any).hold = "snapshot"));
      await recent("projects").click();
      await page.waitForFunction(() => (window as any).held.length === 1);
      await navigateTable("widgets");
      const before = await stored();
      await page.evaluate(() => (window as any).release());
      await page.waitForFunction(() =>
        [...(window as any).activeWorkers].every(
          (worker: any) => worker.requests.size === 0,
        ),
      );
      await settled();
      await expect(
        page.getByRole("heading", { name: "widgets", exact: true }),
      ).toBeVisible();
      await expect.poll(() => query().get("table")).toBe("widgets");
      expect(await stored()).toEqual(before);
    },
  );
  await run(
    "system catalog is grouped separately, opens read-only and remains in recents",
    async () => {
      const metadata = await page.evaluate(async () => {
        const { WorkspaceDatabase } = await import("/src/lib/database.ts");
        const database = new WorkspaceDatabase();
        try {
          await database.request("open");
          return (await database.request("snapshot")).catalog.tables;
        } finally {
          database.close();
        }
      });
      expect(
        metadata.find((t: any) => t.id === "catalog_tables")?.readOnly,
      ).toBe(true);
      expect(metadata.find((t: any) => t.id === "widgets")?.readOnly).toBe(
        false,
      );

      await expect(
        tables.getByRole("button", { name: "catalog_tables", exact: true }),
      ).toHaveCount(0);
      const system = page.getByRole("navigation", {
        name: "System tables",
        exact: true,
      });
      if (!(await system.isVisible()))
        await page
          .locator("summary")
          .filter({ hasText: /^System tables$/ })
          .click();
      await system
        .getByRole("button", { name: "catalog_tables", exact: true })
        .click();
      await expect(
        page.getByRole("button", { name: "New record", exact: true }),
      ).toBeDisabled();
      await expect(recent("catalog_tables")).toBeEnabled();
      await navigateTable("widgets");
      await recent("catalog_tables").click();
      await expect(
        page.getByRole("heading", { name: "catalog_tables", exact: true }),
      ).toBeVisible();
      await page
        .getByRole("main")
        .getByRole("button", { name: "widgets", exact: true })
        .click();
      await expect(editor.locator("#field-display")).toBeDisabled();
      await expect(
        editor.getByRole("button", { name: "Move to trash", exact: true }),
      ).toBeDisabled();
    },
  );
  await run(
    "removed saved view stays disabled with reason and explicit Remove",
    async () => {
      await tables
        .getByRole("button", { name: "projects", exact: true })
        .click();
      await page
        .getByRole("combobox", { name: "View", exact: true })
        .selectOption("delete-view");
      await expect(recent("Disposable view")).toBeEnabled();
      await home();
      await external("deleteView");
      await expect(
        recents.getByText(/linked view is not available/),
      ).toBeVisible();
      await expect(recent("delete-view")).toBeDisabled();
      const before = page.url();
      await recents
        .getByRole("button", {
          name: "Remove delete-view from recents",
          exact: true,
        })
        .click();
      await expect(recent("delete-view")).toHaveCount(0);
      expect(page.url()).toBe(before);
    },
  );
  await run(
    "trashed record remains marked and opens only the read-only Restore path",
    async () => {
      await page
        .getByRole("main")
        .getByRole("button", { name: "Saved without bump", exact: true })
        .click();
      await settled();
      await home();
      await external("trash");
      await expect(recent("Saved without bump")).toContainText("Trash");
      await recent("Saved without bump").click();
      await expect(title()).toBeDisabled();
      await expect(
        editor.getByRole("button", { name: "Restore record", exact: true }),
      ).toBeEnabled();
      expect(query().get("row")).toBe("fixture-record");
    },
  );
  await run(
    "storage failures remain visible while navigation works in memory",
    async () => {
      await page.evaluate(() => {
        const original = Storage.prototype.setItem;
        (window as any).restoreStorage = () =>
          (Storage.prototype.setItem = original);
        Storage.prototype.setItem = function (key, value) {
          if (key.startsWith("iris:recents:")) throw Error("Quota exceeded");
          return original.call(this, key, value);
        };
      });
      try {
        await tables
          .getByRole("button", { name: "projects", exact: true })
          .click();
        await expect(
          page
            .getByRole("status")
            .filter({ hasText: "Recents could not be saved" }),
        ).toBeVisible();
        await expect(recent("projects")).toBeEnabled();
        expect(query().get("table")).toBe("projects");
      } finally {
        await page.evaluate(() => (window as any).restoreStorage());
      }
    },
  );
  await run(
    "storage read failure is visible after successful workspace navigation",
    async () => {
      await navigateTable("projects");
      await home();
      const before = await stored();
      await closeFixture();
      await page.evaluate(() => {
        const original = Storage.prototype.getItem;
        (window as any).restoreRead = () =>
          (Storage.prototype.getItem = original);
        Storage.prototype.getItem = function (key) {
          if (key.startsWith("iris:recents:")) throw Error("Storage denied");
          return original.call(this, key);
        };
      });
      try {
        await page
          .getByRole("button", { name: "Open my workspace", exact: true })
          .click();
        await ready();
        await settled();
        await expect(
          page
            .getByRole("status")
            .filter({ hasText: "Recents could not be read" }),
        ).toBeVisible();
        await expect(recent("widgets")).toBeEnabled();
      } finally {
        await page.evaluate(() => (window as any).restoreRead());
      }
      expect(await stored()).toEqual(before);
    },
  );
  await run(
    "reopen restores capped ID-only preferences and unavailable partial entries are removable",
    async () => {
      await closeFixture();
      await page.goto(url);
      const entries = Array.from({ length: 10 }, (_, i) => ({
        table: "widgets",
        view: null,
        row: `missing/${i}+?`,
      }));
      await page.evaluate(
        (entries) =>
          localStorage.setItem(
            "iris:recents:workspace",
            JSON.stringify({ version: 1, entries }),
          ),
        entries,
      );
      await page
        .getByRole("button", { name: "Open my workspace", exact: true })
        .click();
      await ready();
      await settled();
      await expect(
        recents.locator(".destination"),
      ).toHaveCount(8);
      await expect(recent("missing/0+?")).toBeDisabled();
      await expect(
        recents.getByText(/outside this replica/).first(),
      ).toBeVisible();
      await recents
        .getByRole("button", {
          name: "Remove missing/0+? from recents",
          exact: true,
        })
        .click();
      await expect(recent("missing/0+?")).toHaveCount(0);
      for (const item of await stored())
        expect(Object.keys(item).sort()).toEqual(["row", "table", "view"]);
    },
  );
  await run(
    "sample and account histories stay separate across workspace switches",
    async () => {
      const account = await stored();
      await closeFixture();
      await page.goto(url);
      await page
        .getByRole("button", { name: "Try sample workspace", exact: true })
        .click();
      await ready();
      await settled();
      expect(await stored()).toEqual(account);
      await expect(recent("widgets")).toHaveCount(0);
      const demo = await page.evaluate(
        () =>
          JSON.parse(
            localStorage.getItem("iris:recents:demo") ?? '{"entries":[]}',
          ).entries,
      );
      expect(demo.length).toBeGreaterThan(0);
      await closeFixture();
      await page.goto(url);
      await page
        .getByRole("button", { name: "Open my workspace", exact: true })
        .click();
      await ready();
      await settled();
      await expect(recent("widgets")).toBeEnabled();
      expect(
        (await stored()).every((d: any) =>
          ["widgets", "projects"].includes(d.table),
        ),
      ).toBe(true);
    },
  );
  await run("sidebar fits desktop and 390px light/dark layouts", async () => {
    const screenshots = process.env.IRIS_TEST_SCREENSHOTS;
    if (screenshots) await mkdir(screenshots, { recursive: true });
    for (const [width, colorScheme] of [
      [1440, "light"],
      [390, "dark"],
    ] as const) {
      await page.setViewportSize({ width, height: 1000 });
      await page.emulateMedia({ colorScheme });
      if (screenshots)
        await page.screenshot({
          path: resolve(screenshots, `recents-${width}.png`),
          fullPage: true,
        });
      console.log(
        "LAYOUT",
        width,
        await page.evaluate(() => ({
          width: innerWidth,
          scroll: document.documentElement.scrollWidth,
          overflow: [...document.querySelectorAll("body *")]
            .filter((el) => el.getBoundingClientRect().right > innerWidth + 1)
            .slice(0, 12)
            .map((el) => ({
              tag: el.tagName,
              cls: el.className,
              right: el.getBoundingClientRect().right,
            })),
        })),
      );
      expect(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
      ).toBe(true);
    }
  });
} catch (error) {
  console.error("STATE:", await page.locator("body").innerText());
  throw error;
} finally {
  await closeFixture();
  await page.goto(url);
  await expect(
    page.getByRole("button", { name: "Open my workspace", exact: true }),
  ).toBeEnabled({ timeout: 30000 });
  await browser.close();
  server.stop(true);
  db.db.close();
  auth.db.close();
}
