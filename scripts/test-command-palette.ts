import { chromium, expect, type Page } from "@playwright/test";
import { resolve } from "node:path";
import { mkdir } from "node:fs/promises";
import { disposableOrigin, workspacePage } from "./test-origin";
import { regressionHub } from "./workspace-regression-hub";

const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-palette.localhost:5226/workspace?review";
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source)
  throw Error(
    "Usage: bun scripts/test-command-palette.ts <life-data-checkout>",
  );
const { server, db } = await regressionHub(source, origin);
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
for (let i = 0; i < 55; i++)
  db.db
    .query("INSERT INTO widgets(id,title,body) VALUES (?,?,?)")
    .run(`page-${i}`, `Paged ${i}`, "paginationword");

const browser = await chromium.connectOverCDP(
  process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
);
let page: Page | undefined;
let accept = true,
  dialogs = 0;
try {
  page = workspacePage(
    browser.contexts().flatMap((c) => c.pages()),
    url,
  );
  if (!page)
    throw Error("Open the reserved command palette fixture page first");
  const owned = page;
  page.context().on("requestfailed", (request) => {
    if (request.url().startsWith(server.url.origin))
      console.error(
        "FIXTURE REQUEST FAILED:",
        new URL(request.url()).pathname,
        request.failure(),
      );
  });
  page.setDefaultTimeout(8000);
  page.on("dialog", (dialog) => {
    dialogs++;
    return accept ? dialog.accept() : dialog.dismiss();
  });
  page.on("pageerror", (error) => console.error("PAGE ERROR:", error.message));
  page.on("console", (message) => {
    if (message.type() === "error") console.error("BROWSER:", message.text());
  });
  await page.setViewportSize({ width: 1440, height: 1000 });
  if (await page.getByRole("dialog", {name:"Find records",exact:true}).isVisible()) await page.keyboard.press("Escape");
  if (await page.getByRole("button", {name:"Switch workspace",exact:true}).count()) {
    await page.getByRole("button", {name:"Switch workspace",exact:true}).click();
    await expect.poll(()=>page!.workers().length).toBe(0);
  }
  await page.goto(new URL("/", url).href);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.detach();
  await page.addInitScript(() => {
    const state = window as any;
    state.calls = [];
    state.held = [];
    state.hold = null;
    state.rejectList = false;
    state.release = () => {
      state.hold = null;
      state.held.splice(0).forEach((deliver: () => void) => deliver());
    };
    const Original = window.Worker;
    window.Worker = class extends Original {
      requests = new Map<number, any>();
      postMessage(request: any, ...args: any[]) {
        this.requests.set(request.id, request);
        state.calls.push(request);
        return super.postMessage(request, ...(args as [any]));
      }
      set onmessage(handler: any) {
        super.onmessage = (event) => {
          const request = this.requests.get(event.data.id);
          if (event.data.error)
            console.error(
              "Worker receipt:",
              request?.method,
              JSON.stringify(event.data.error),
            );
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
  await page.goto(url);
  await page
    .getByRole("button", { name: "Open my workspace", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: /Find records/ }),
  ).toBeEnabled();
  await page.getByText("Connect to a hub", { exact: true }).click();
  await page.getByText("Use a device token", { exact: true }).click();
  await page.getByLabel("Hub address").fill(server.url.href.replace(/\/$/, ""));
  await page.getByLabel("Device token").fill("fixture");
  await page.getByRole("button", { name: "Sync now", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Sync now", exact: true }),
  ).toBeEnabled({ timeout: 30000 });
  const dialog = page.getByRole("dialog", {
    name: "Find records",
    exact: true,
  });
  const input = dialog.getByRole("combobox", {
    name: "Search records",
    exact: true,
  });
  const tables = page.getByRole("navigation", { name: "Tables", exact: true });
  const editor = page.getByRole("complementary", {
    name: "Record editor",
    exact: true,
  });
  const viewOption = (table: string) =>
    dialog
      .getByRole("group", { name: "Saved views", exact: true })
      .getByRole("option")
      .filter({ hasText: "Pinned" })
      .filter({ hasText: table });
  const tableOption = (table: string) =>
    dialog
      .getByRole("group", { name: "Tables", exact: true })
      .getByRole("option", { name: table, exact: true });
  const recordOption = (label: string) =>
    dialog
      .getByRole("group", { name: "Records", exact: true })
      .getByRole("option")
      .filter({ hasText: label });
  const query = () => new URL(owned.url()).searchParams;
  async function open() {
    await owned.keyboard.press("Meta+k");
    await expect(dialog).toBeVisible();
  }
  async function home() {
    accept = true;
    await owned.evaluate(() => (window as any).release());
    if (await dialog.isVisible()) await owned.keyboard.press("Escape");
    if (await editor.isVisible())
      await owned
        .getByRole("button", { name: "Close record", exact: true })
        .click();
    await tables.getByRole("button", { name: "widgets", exact: true }).click();
    await expect.poll(() => query().get("table")).toBe("widgets");
    await expect(
      owned.getByRole("region", { name: "Recents", exact: true })
        .getByText("Loading…", { exact: true }),
    ).toHaveCount(0);
  }
  async function hold(method: string) {
    await owned.evaluate((method) => {
      (window as any).hold = method;
    }, method);
  }
  async function held() {
    await owned.waitForFunction(() => (window as any).held.length > 0);
  }
  async function editView(id: string, remove = false) {
    await owned.evaluate(
      async ({ id, remove }) => {
        const { WorkspaceDatabase } = await import("/src/lib/database.ts");
        const database = new WorkspaceDatabase();
        try {
          await database.request("open");
          const { views } = await database.request("listViews", {
            table: "projects",
          });
          const view = views.find((view: any) => view.id === id)!;
          if (remove)
            await database.request("deleteView", {
              id,
              expectedUpdatedAt: view.updated_at,
            });
          else
            await database.request("saveView", {
              id,
              table: "projects",
              name: "Renamed view",
              definition: { version: 1, columns: ["headline", "detail"] },
              expectedUpdatedAt: view.updated_at,
            });
        } finally {
          database.close();
        }
      },
      { id, remove },
    );
  }
  const cases: [string, () => Promise<void>][] = [
    [
      "empty palette lists tables and views without record requests; table choice has history",
      async () => {
        await owned.evaluate(() => {
          (window as any).calls = [];
        });
        await open();
        await expect(tableOption("projects")).toBeVisible();
        await expect(viewOption("widgets")).toBeVisible();
        await expect(viewOption("projects")).toBeVisible();
        await expect(
          dialog.getByRole("option").filter({ hasText: "Future view" }),
        ).toBeDisabled();
        expect(
          await owned.evaluate(() =>
            (window as any).calls.filter(
              (call: any) => call.method === "search",
            ),
          ),
        ).toEqual([]);
        await tableOption("projects").click();
        await expect(dialog).not.toBeVisible();
        await expect.poll(() => query().get("table")).toBe("projects");
        await owned.goBack();
        await expect(
          owned.getByRole("heading", { name: "widgets", exact: true }),
        ).toBeVisible();
      },
    ],
    [
      "cross-table saved view applies stable ID and preserves full hidden editor fields",
      async () => {
        await open();
        await input.fill("PIN");
        await viewOption("projects").click();
        await expect(
          owned.getByRole("combobox", { name: "View", exact: true }),
        ).toHaveValue("project-view");
        await expect.poll(() => query().get("view")).toBe("project-view");
        await owned
          .getByRole("button", { name: "Project signal", exact: true })
          .click();
        await expect(
          editor.getByRole("textbox", { name: "Detail", exact: true }),
        ).toHaveValue("Hidden detail");
      },
    ],
    [
      "record search retains accents prefixes snippets and raw fifty-row paging",
      async () => {
        await open();
        await input.fill("astronomia");
        await expect(recordOption("Fixture record")).toContainText(
          "Astronomía",
        );
        await input.fill("nebul");
        await recordOption("Fixture record").click();
        await expect(
          editor.getByLabel("Quantity", { exact: true }),
        ).toHaveValue("42");
        await owned
          .getByRole("button", { name: "Close record", exact: true })
          .click();
        await open();
        await input.fill("paginationword");
        await expect(dialog.getByRole("option")).toHaveCount(50);
        await dialog
          .getByRole("button", { name: "More results", exact: true })
          .click();
        await expect(dialog.getByRole("option")).toHaveCount(55);
        await expect(
          dialog.getByRole("button", { name: "More results", exact: true }),
        ).not.toBeVisible();
        expect(
          await owned.evaluate(() =>
            (window as any).calls
              .filter(
                (call: any) =>
                  call.method === "search" &&
                  call.args.text === "paginationword",
              )
              .map((call: any) => call.args.offset),
          ),
        ).toEqual([0, 50]);
      },
    ],
    [
      "late view entries do not steal the selected record",
      async () => {
        await hold("listViews");
        await open();
        await held();
        await input.fill("project");
        await expect(recordOption("Project signal")).toBeVisible();
        await input.press("ArrowUp");
        await expect(recordOption("Project signal")).toHaveAttribute(
          "aria-selected",
          "true",
        );
        await owned.evaluate(() => (window as any).release());
        await expect(viewOption("projects")).toBeVisible();
        await expect(recordOption("Project signal")).toHaveAttribute(
          "aria-selected",
          "true",
        );
        await input.press("Enter");
        await expect(
          editor.getByRole("textbox", { name: "Headline", exact: true }),
        ).toHaveValue("Project signal");
      },
    ],
    [
      "cancelled dirty discard retains dialog draft and URL; accept prompts once",
      async () => {
        await owned
          .getByRole("button", { name: "Fixture record", exact: true })
          .click();
        await editor
          .getByRole("textbox", { name: "Title", exact: true })
          .fill("Keep draft");
        const address = owned.url(),
          before = dialogs;
        await open();
        accept = false;
        await tableOption("projects").click();
        await expect(input).toBeEnabled();
        await expect(dialog).toBeVisible();
        expect(owned.url()).toBe(address);
        expect(dialogs).toBe(before + 1);
        await expect(
          editor.getByRole("textbox", { name: "Title", exact: true }),
        ).toHaveValue("Keep draft");
        accept = true;
        await viewOption("projects").click();
        await expect(dialog).not.toBeVisible();
        expect(dialogs).toBe(before + 2);
        await expect.poll(() => query().get("view")).toBe("project-view");
      },
    ],
    [
      "closed destination lookup cannot overwrite a reopened palette",
      async () => {
        await open();
        await expect(viewOption("projects")).toBeVisible();
        const address = owned.url();
        await hold("snapshot");
        await tableOption("projects").click();
        await held();
        await owned.keyboard.press("Escape");
        await open();
        await owned.evaluate(() => (window as any).release());
        await expect(viewOption("projects")).toBeVisible();
        await expect(input).toBeEnabled();
        expect(owned.url()).toBe(address);
        await expect(
          owned.getByRole("heading", { name: "widgets", exact: true }),
        ).toBeVisible();
      },
    ],
    [
      "pending write receipt blocks palette navigation",
      async () => {
        await owned
          .getByRole("button", { name: "Fixture record", exact: true })
          .click();
        await editor
          .getByRole("textbox", { name: "Title", exact: true })
          .fill("Receipt waiting");
        await hold("write");
        await owned
          .getByRole("button", { name: "Save record", exact: true })
          .click();
        await held();
        const address = owned.url();
        await owned.keyboard.press("Meta+k");
        await expect(dialog).not.toBeVisible();
        expect(owned.url()).toBe(address);
        await owned.evaluate(() => (window as any).release());
        await expect(
          owned.getByRole("button", { name: "Save record", exact: true }),
        ).toBeEnabled();
        await editor
          .getByRole("textbox", { name: "Title", exact: true })
          .fill("Fixture record");
        await owned
          .getByRole("button", { name: "Save record", exact: true })
          .click();
      },
    ],
    [
      "stale saved-view entry resolves the new revision before applying",
      async () => {
        await open();
        await expect(viewOption("projects")).toBeVisible();
        await editView("project-view");
        await viewOption("projects").click();
        await expect(
          owned.getByRole("textbox", { name: "View name", exact: true }),
        ).toHaveValue("Renamed view");
        await expect(
          owned.getByRole("columnheader", { name: "Detail", exact: true }),
        ).toBeVisible();
      },
    ],
    [
      "deleted saved-view entry reports absence and keeps the source URL",
      async () => {
        await open();
        const option = dialog
          .getByRole("option")
          .filter({ hasText: "Disposable view" });
        await expect(option).toBeVisible();
        const address = owned.url();
        await editView("delete-view", true);
        await option.click();
        await expect(dialog.getByRole("alert")).toContainText("not available");
        await expect(input).toBeFocused();
        expect(owned.url()).toBe(address);
      },
    ],
    [
      "palette groups fit desktop and narrow dark layouts",
      async () => {
        await open();
        await expect(viewOption("widgets")).toBeVisible();
        const screenshots = process.env.LIFE_UI_TEST_SCREENSHOTS;
        if (screenshots) await mkdir(screenshots, { recursive: true });
        for (const [width, colorScheme] of [
          [1440, "light"],
          [390, "dark"],
        ] as const) {
          await owned.setViewportSize({ width, height: 900 });
          await owned.emulateMedia({ colorScheme });
          const box = await dialog.boundingBox();
          expect(box).not.toBeNull();
          expect(box!.x).toBeGreaterThanOrEqual(0);
          expect(box!.x + box!.width).toBeLessThanOrEqual(width);
          expect(
            await dialog.evaluate((el) => el.scrollWidth <= el.clientWidth),
          ).toBe(true);
          if (screenshots)
            await owned.screenshot({
              path: resolve(screenshots, `palette-${width}.png`),
            });
        }
      },
    ],
  ];
  for (const [name, run] of cases) {
    if (
      process.env.LIFE_UI_PALETTE_CASE &&
      !name.includes(process.env.LIFE_UI_PALETTE_CASE)
    )
      continue;
    await home();
    await run();
    console.log("PASS:", name);
  }
} catch (error) {
  if (page)
    console.error(
      "Fixture state:",
      await page
        .evaluate(() => ({
          text: document.body.innerText,
          calls: (window as any).calls,
          held: (window as any).held?.length,
        }))
        .catch(() => null),
    );
  throw error;
} finally {
  if (page) {
    await page.evaluate(() => (window as any).release?.()).catch(() => {});
    if (await page.getByRole("dialog", {name:"Find records",exact:true}).isVisible()) await page.keyboard.press("Escape");
    if (await page.getByRole("button", {name:"Switch workspace",exact:true}).count()) {
      accept = true;
      await page.getByRole("button", {name:"Switch workspace",exact:true}).click();
      await expect.poll(()=>page!.workers().length).toBe(0);
    }
    await page.goto(new URL("/", url).href).catch(() => {});
    await page.goto(url).catch(() => {});
  }
  await browser.close();
  server.stop(true);
  db.db.close();
}
