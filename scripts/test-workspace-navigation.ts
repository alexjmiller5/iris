import { chromium, expect } from "@playwright/test";
import { resolve } from "node:path";
import { mkdir } from "node:fs/promises";
import { regressionHub } from "./workspace-regression-hub";
import { disposableOrigin, workspacePage } from "./test-origin";

const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-navigation.localhost:5224/workspace?review";
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source)
  throw new Error(
    "Usage: bun scripts/test-workspace-navigation.ts <life-data-checkout>",
  );
const { server, db } = await regressionHub(source, origin);
const schema = await Bun.file(
  resolve(import.meta.dir, "../packages/core/schema/saved-views.json"),
).json();
const system =
  "id TEXT PRIMARY KEY NOT NULL,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT";
for (const ddl of [
  `CREATE TABLE projects (${system},headline TEXT,detail TEXT,code TEXT,count INTEGER)`,
  "ALTER TABLE catalog_properties ADD COLUMN source TEXT",
  "ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT",
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
db.db
  .query("INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)")
  .run(
    "project-view",
    "Project headlines",
    "projects",
    JSON.stringify({ version: 1, columns: ["headline"] }),
  );
db.db.exec(`
 INSERT INTO catalog_tables(id,kind,display,purpose) VALUES ('projects','table','headline','Synthetic reference targets');
 INSERT INTO catalog_properties(id,tbl,col,label,sort,type,ref_table,immutable) VALUES
 ('projects.headline','projects','headline','Headline',0,'text',NULL,0),
 ('projects.detail','projects','detail','Detail',1,'text',NULL,0),
 ('projects.code','projects','code','Code',2,'text',NULL,0),
 ('projects.count','projects','count','Count',3,'int',NULL,0);
 INSERT INTO projects(id,headline,detail,code,count,updated_at,hub_at) VALUES
 ('fixture-record','Target project','Full target detail','hidden-code',73,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z'),
 ('target-two','Second project','Second detail','second-code',19,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z');
`);

const encodedRow = "row / café?&%",
  encodedView = "view /?&%";
db.db
  .query("INSERT INTO widgets(id,title,body,deleted_at) VALUES (?,?,?,?)")
  .run(encodedRow, "Encoded record", "Opaque identity", null);
db.db
  .query("INSERT INTO widgets(id,title,deleted_at) VALUES (?,?,?)")
  .run("trashed-record", "Trashed record", "2026-01-02T00:00:00.000Z");
db.db
  .query("INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)")
  .run(
    encodedView,
    "Encoded view",
    "widgets",
    JSON.stringify({ version: 1, columns: ["title"] }),
  );

const browser = await chromium.connectOverCDP(
  process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
);
let accept = true,
  dialogs = 0;
let ownedPage: import('@playwright/test').Page | undefined;
try {
  const page = ownedPage = workspacePage(browser.contexts().flatMap(c => c.pages()), url);
  if (!page)
    throw new Error("Open the reserved navigation fixture page first.");
  page.setDefaultTimeout(8000);
  await page.setViewportSize({ width: 1440, height: 1000 });
  page.on("pageerror", (error) => console.error("PAGE ERROR:", error.message));
  page.on("console", (message) => {
    if (message.type() === "error") console.error("BROWSER:", message.text());
  });
  page.on("dialog", (dialog) => {
    dialogs++;
    return accept ? dialog.accept() : dialog.dismiss();
  });
  await page.goto(new URL("/", url).href);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.detach();
  await page.addInitScript(() => {
    const state = window as any;
    state.holdWrites = false;
    state.holdRows = false;
    state.failTableRows = false;
    state.held = [];
    state.pops = 0;
    state.calls = [];
    state.inflight = 0;
    window.addEventListener("popstate", () => state.pops++);
    state.release = (fail = false) => {
      state.holdWrites = false;
      state.holdRows = false;
      state.held.splice(0).forEach((f: any) => f(fail));
    };
    const Original = (state.originalWorker ??= window.Worker);
    window.Worker = class extends Original {
      requests = new Map<number, any>();
      postMessage(message: any, ...args: any[]) {
        state.inflight++;
        state.calls.push(["send", message.id, message.method]);
        this.requests.set(message.id, message);
        return super.postMessage(message, ...(args as [any]));
      }
      set onmessage(handler: any) {
        super.onmessage = (event) => {
          const request = this.requests.get(event.data.id);
          state.calls.push([
            "reply",
            event.data.id,
            request?.method,
            event.data.error?.message,
          ]);
          this.requests.delete(event.data.id);
          const deliver = (fail = false) => {
            if (request) state.inflight--;
            handler.call(
              this,
              fail
                ? {
                    data: {
                      ...event.data,
                      error: { message: "Delayed lookup failure" },
                    },
                  }
                : event,
            );
          };
          if (
            request?.method === "rows" &&
            !request.args.view.filters?.some((f: any) => f.column === "id") &&
            state.failTableRows
          ) {
            state.failTableRows = false;
            deliver(true);
          } else if (request?.method === "write" && state.holdWrites)
            state.held.push(deliver);
          else if (
            request?.method === "rows" &&
            request.args.view.filters?.some((f: any) => f.column === "id") &&
            state.holdRows
          ) {
            state.holdRows = false;
            state.held.push(deliver);
          } else deliver();
        };
      }
    };
  });
  const editor = page.getByRole("complementary", {
    name: "Record editor",
    exact: true,
  });
  const tables = page.getByRole("navigation", { name: "Tables", exact: true });
  const query = () => new URL(page.url()).searchParams;
  async function opened(address = url, reload = false) {
    accept = true;
    const leave = page.getByRole("button", {
      name: "Switch workspace",
      exact: true,
    });
    if (!reload && (await leave.isVisible())) {
      await leave.click();
      await expect.poll(() => page.workers().length).toBe(0);
    }
    await page.goto(address);
    await page
      .getByRole("button", { name: "Open my workspace", exact: true })
      .click();
    await expect(page.getByRole("button", { name: /Find records/ }))
      .toBeEnabled({ timeout: 15000 })
      .catch(async (e) => {
        console.error(
          "Worker calls:",
          await page.evaluate(() => (window as any).calls),
        );
        console.error(
          "Locks:",
          await page.evaluate(() => navigator.locks.query()),
        );
        console.error(
          "Workers:",
          page.workers().map((w) => w.url()),
        );
        throw e;
      });
    if (
      address === url &&
      (await tables
        .getByRole("button", { name: "widgets", exact: true })
        .isVisible())
    )
      await tables
        .getByRole("button", { name: "widgets", exact: true })
        .click();
  }
  async function home() {
    accept = true;
    if (await editor.isVisible())
      await page
        .getByRole("button", { name: "Close record", exact: true })
        .click();
    await tables.getByRole("button", { name: "widgets", exact: true }).click();
    await expect(
      page.getByRole("heading", { name: "widgets", exact: true }),
    ).toBeVisible();
    await expect
      .poll(() => page.evaluate(() => (window as any).inflight))
      .toBe(0);
  }
  async function follow(address: string) {
    await page.evaluate((address) => {
      const link = document.createElement("a");
      link.href = address;
      link.textContent = "Fixture destination";
      document.body.append(link);
      link.click();
      link.remove();
    }, address);
  }
  async function connect() {
    await page.getByText("Connect to a hub", { exact: true }).click();
    await page.getByText("Use a device token", { exact: true }).click();
    await page
      .getByLabel("Hub address")
      .fill(server.url.href.replace(/\/$/, ""));
    await page.getByLabel("Device token").fill("fixture");
    const sync = page.getByRole("button", { name: "Connect", exact: true });
    await sync.click();
    await expect(sync).toBeEnabled({ timeout: 30000 }).catch(async (error) => {
      console.error("Connection state:", await page.locator("body").innerText());
      console.error("Worker calls:", await page.evaluate(() => (window as any).calls));
      throw error;
    });
  }
  await opened();
  await connect();
  const cases: [string, () => Promise<void>][] = [
    [
      "table links and browser history",
      async () => {
        await expect.poll(() => query().get("table")).toBe("widgets");
        await tables
          .getByRole("button", { name: "projects", exact: true })
          .click();
        await expect.poll(() => query().get("table")).toBe("projects");
        await page.evaluate(() => history.back());
        await expect(
          page.getByRole("heading", { name: "widgets", exact: true }),
        ).toBeVisible();
        await expect.poll(() => query().get("table")).toBe("widgets");
        await page.evaluate(() => history.forward());
        await expect(
          page.getByRole("heading", { name: "projects", exact: true }),
        ).toBeVisible();
      },
    ],
    [
      "row reload, close, Back and full editor fields",
      async () => {
        await page
          .getByRole("button", { name: "Fixture record", exact: true })
          .click();
        await expect.poll(() => query().get("row")).toBe("fixture-record");
        const address = page.url();
        await opened(address, true);
        await expect(
          editor.getByLabel("Quantity", { exact: true }),
        ).toHaveValue("42");
        await page
          .getByRole("button", { name: "Close record", exact: true })
          .click();
        await expect.poll(() => query().has("row")).toBe(false);
        await page.evaluate(() => history.back());
        await expect(
          editor.getByLabel("Quantity", { exact: true }),
        ).toHaveValue("42");
      },
    ],
    [
      "saved view and row links restore layout with full records",
      async () => {
        await tables
          .getByRole("button", { name: "projects", exact: true })
          .click();
        await page
          .getByRole("combobox", { name: "View", exact: true })
          .selectOption("project-view");
        await expect.poll(() => query().get("view")).toBe("project-view");
        await page
          .getByRole("button", { name: "Target project", exact: true })
          .click();
        await expect.poll(() => query().get("row")).toBe("fixture-record");
        expect(query().get("view")).toBe("project-view");
        await opened(page.url());
        await expect(
          page.getByRole("combobox", { name: "View", exact: true }),
        ).toHaveValue("project-view");
        await expect(editor.getByLabel("Code", { exact: true })).toHaveValue(
          "hidden-code",
        );
        await expect(editor.getByLabel("Count", { exact: true })).toHaveValue(
          "73",
        );
      },
    ],
    [
      "renamed saved views keep stable links and reopen their current definition",
      async () => {
        await tables
          .getByRole("button", { name: "projects", exact: true })
          .click();
        await page
          .getByRole("combobox", { name: "View", exact: true })
          .selectOption("project-view");
        await expect.poll(() => query().get("view")).toBe("project-view");
        const address = page.url();
        await page
          .getByRole("button", { name: "View settings", exact: true })
          .click();
        const menu = page.getByRole("dialog", {
          name: "View settings",
          exact: true,
        });
        await menu
          .getByRole("textbox", { name: "View name", exact: true })
          .fill("Renamed headlines");
        await menu.getByRole("button", { name: "Rename", exact: true }).click();
        const views = page.getByRole("combobox", { name: "View", exact: true });
        await expect(views.locator("option:checked")).toHaveText(
          "Renamed headlines",
        );
        await page.keyboard.press("Escape");
        expect(page.url()).toBe(address);
        await home();
        await follow(address);
        await expect(views).toHaveValue("project-view");
        await expect(views.locator("option:checked")).toHaveText(
          "Renamed headlines",
        );
      },
    ],
    [
      "Back cancellation keeps the draft and current URL",
      async () => {
        await page
          .getByRole("button", { name: "Fixture record", exact: true })
          .click();
        await expect.poll(() => query().get("row")).toBe("fixture-record");
        await page
          .getByRole("button", { name: "Second record", exact: true })
          .click();
        await expect.poll(() => query().get("row")).toBe("second-record");
        await editor
          .getByRole("textbox", { name: "Title", exact: true })
          .fill("Keep this draft");
        const address = page.url(),
          before = dialogs;
        accept = false;
        await page.evaluate(() => history.back());
        await expect.poll(() => dialogs).toBe(before + 1);
        await expect.poll(() => page.url()).toBe(address);
        await expect(
          editor.getByRole("textbox", { name: "Title", exact: true }),
        ).toHaveValue("Keep this draft");
        accept = true;
        await page.evaluate(() => history.back());
        await expect(
          editor.getByRole("textbox", { name: "Title", exact: true }),
        ).toHaveValue("Fixture record");
        await expect.poll(() => query().get("row")).toBe("fixture-record");
      },
    ],
    [
      "pending write blocks browser Back until receipt",
      async () => {
        await page
          .getByRole("button", { name: "Fixture record", exact: true })
          .click();
        await expect.poll(() => query().get("row")).toBe("fixture-record");
        await editor.getByLabel("Quantity", { exact: true }).fill("44");
        await page.evaluate(() => {
          (window as any).holdWrites = true;
        });
        await editor
          .getByRole("button", { name: "Save record", exact: true })
          .click();
        await page.waitForFunction(() => (window as any).held.length > 0);
        const address = page.url(),
          pops = await page.evaluate(() => (window as any).pops);
        await page.evaluate(() => history.back());
        await expect
          .poll(() => page.evaluate(() => (window as any).pops))
          .toBeGreaterThan(pops);
        await expect.poll(() => page.url()).toBe(address);
        await expect(
          editor.getByLabel("Quantity", { exact: true }),
        ).toHaveValue("44");
        await page.evaluate(() => (window as any).release());
        await expect(
          editor.getByRole("button", { name: "Save record", exact: true }),
        ).toBeEnabled();
      },
    ],
    [
      "late row replies cannot replace a newer table",
      async () => {
        await tables
          .getByRole("button", { name: "projects", exact: true })
          .click();
        await page.evaluate(() => {
          (window as any).holdRows = true;
        });
        await page
          .getByRole("button", { name: "Target project", exact: true })
          .click();
        await page.waitForFunction(() => (window as any).held.length > 0);
        await tables
          .getByRole("button", { name: "widgets", exact: true })
          .click();
        await expect.poll(() => query().get("table")).toBe("widgets");
        await page.evaluate(() => (window as any).release());
        await expect(editor).not.toBeVisible();
        await expect(
          page.getByRole("heading", { name: "widgets", exact: true }),
        ).toBeVisible();
      },
    ],
    [
      "a newer record wins over a delayed linked record",
      async () => {
        await page.evaluate(() => {
          (window as any).holdRows = true;
        });
        await follow(origin + "/workspace?table=widgets&row=fixture-record");
        await page.waitForFunction(() => (window as any).held.length === 1);
        await page.evaluate(() => {
          (window as any).holdRows = true;
        });
        await page
          .getByRole("button", { name: "Second record", exact: true })
          .click();
        await page.waitForFunction(() => (window as any).held.length === 2);
        await page.evaluate(() => (window as any).held.shift()());
        await expect(
          page.getByText("Opening link…", { exact: true }),
        ).not.toBeVisible();
        await expect(editor).not.toBeVisible();
        await page.evaluate(() => (window as any).release());
        await expect(
          editor.getByRole("textbox", { name: "Title", exact: true }),
        ).toHaveValue("Second record");
        await expect.poll(() => query().get("row")).toBe("second-record");
      },
    ],
    [
      "encoded identifiers resolve without display-name assumptions",
      async () => {
        await page
          .getByRole("combobox", { name: "View", exact: true })
          .selectOption(encodedView);
        await page
          .getByRole("button", { name: "Encoded record", exact: true })
          .click();
        await expect.poll(() => query().get("row")).toBe(encodedRow);
        expect(query().get("view")).toBe(encodedView);
        const address = page.url();
        await home();
        await follow(address);
        await expect(
          editor.getByRole("textbox", { name: "Title", exact: true }),
        ).toHaveValue("Encoded record");
        await expect(
          page.getByRole("combobox", { name: "View", exact: true }),
        ).toHaveValue(encodedView);
      },
    ],
    [
      "graph and trash navigation remove closed record from URL",
      async () => {
        await page
          .getByRole("button", { name: "Fixture record", exact: true })
          .click();
        await expect.poll(() => query().get("row")).toBe("fixture-record");
        await page
          .getByRole("button", { name: "Table graph", exact: true })
          .click();
        await expect(editor).not.toBeVisible();
        await expect.poll(() => query().has("row")).toBe(false);
        await page
          .getByRole("button", { name: "Records", exact: true })
          .click();
        await page
          .getByRole("button", { name: "Fixture record", exact: true })
          .click();
        await expect.poll(() => query().get("row")).toBe("fixture-record");
        await page
          .getByRole("button", { name: "Trash", exact: true })
          .press("Enter");
        await expect.poll(() => query().has("row")).toBe(false);
        await page
          .getByRole("button", { name: "Trashed record", exact: true })
          .click();
        await expect(
          editor.getByRole("textbox", { name: "Title", exact: true }),
        ).toHaveValue("Trashed record");
        await expect.poll(() => query().get("row")).toBe("trashed-record");
        const address = page.url();
        await page
          .getByRole("button", { name: "Close record", exact: true })
          .click();
        await expect.poll(() => query().has("row")).toBe(false);
        await follow(address);
        await expect(
          editor.getByRole("textbox", { name: "Title", exact: true }),
        ).toHaveValue("Trashed record");
        await expect(
          editor.getByRole("button", { name: "Restore record", exact: true }),
        ).toBeVisible();
        await page
          .getByRole("button", { name: "Close record", exact: true })
          .click();
        await page
          .getByRole("button", { name: "All records", exact: true })
          .click();
      },
    ],
    [
      "late lookup errors do not replace a newer workspace",
      async () => {
        await page.evaluate(() => {
          (window as any).holdRows = true;
        });
        await follow(origin + "/workspace?table=widgets&row=fixture-record");
        await page.waitForFunction(() => (window as any).held.length === 1);
        await page
          .getByRole("button", { name: "Switch workspace", exact: true })
          .click();
        await page.evaluate(() => (window as any).release(true));
        await expect(
          page.getByRole("button", { name: "Open my workspace", exact: true }),
        ).toBeVisible();
        await expect(
          page.getByText("Delayed lookup failure", { exact: true }),
        ).not.toBeVisible();
        await opened();
      },
    ],
    [
      "pending linked lookup freezes writes to the source record",
      async () => {
        await page
          .getByRole("button", { name: "Fixture record", exact: true })
          .click();
        await expect(
          editor.getByRole("button", { name: "Save record", exact: true }),
        ).toBeEnabled();
        await expect
          .poll(() => page.evaluate(() => (window as any).inflight))
          .toBe(0);
        await page.evaluate(() => {
          (window as any).holdRows = true;
        });
        await follow(origin + "/workspace?table=widgets&row=second-record");
        await page.waitForFunction(() => (window as any).held.length === 1);
        await expect(
          editor.getByRole("button", { name: "Save record", exact: true }),
        ).toBeDisabled();
        await expect(
          editor.getByRole("button", { name: "Move to trash", exact: true }),
        ).toBeDisabled();
        await page.evaluate(() => (window as any).release());
        await expect(
          editor.getByRole("textbox", { name: "Title", exact: true }),
        ).toHaveValue("Second record");
      },
    ],
    [
      "destination refresh failures remain visible after row resolution",
      async () => {
        await page.evaluate(() => {
          (window as any).failTableRows = true;
        });
        await follow(origin + "/workspace?table=projects&row=fixture-record");
        await expect(
          editor.getByRole("textbox", { name: "Headline", exact: true }),
        ).toHaveValue("Target project");
        await expect(page.getByRole("alert")).toContainText(
          "Delayed lookup failure",
        );
      },
    ],
    [
      "absent targets are explained without opening another row",
      async () => {
        for (const [suffix, reason] of [
          ["table=missing", "linked table"],
          ["table=widgets&view=missing", "linked view"],
          ["table=widgets&row=missing", "linked record"],
          ["table=widgets&table=projects", "empty or repeated"],
        ]) {
          await follow(origin + "/workspace?" + suffix);
          await expect(page.getByRole("alert")).toContainText(reason);
          await expect(editor).not.toBeVisible();
        }
      },
    ],
    [
      "Copy link excludes credentials and restores the selected record",
      async () => {
        await page
          .getByRole("button", { name: "Fixture record", exact: true })
          .click();
        await expect.poll(() => query().get("row")).toBe("fixture-record");
        const view = query().get("view");
        expect(view).toBeTruthy();
        await follow(
          page.url() +
            "&token=fixture-secret&search=fixture-private#fixture-private",
        );
        await expect(
          page.getByText("Opening link…", { exact: true }),
        ).not.toBeVisible();
        await page
          .context()
          .grantPermissions(["clipboard-read", "clipboard-write"], { origin });
        await page
          .getByRole("button", { name: "Copy link", exact: true })
          .click();
        const copied = await page.evaluate(() =>
          navigator.clipboard.readText(),
        );
        expect(copied).toBe(
          `${origin}/workspace?${new URLSearchParams({ table: "widgets", view: view!, row: "fixture-record" })}`,
        );
        await opened(copied);
        await expect(
          editor.getByRole("textbox", { name: "Title", exact: true }),
        ).toHaveValue("Fixture record");
      },
    ],
    [
      "graph groups persist per workspace and a graph table opens its records",
      async () => {
        const graph = page.getByRole("group", {
          name: "Catalog tables and reference relationships",
        });
        await page
          .getByRole("button", { name: "Table graph", exact: true })
          .click();
        await page.getByText("Group tables", { exact: true }).click();
        const group = page.getByLabel("Group for projects", { exact: true });
        await group.fill("Synthetic group");
        await group.blur();
        await expect(graph.getByText("Synthetic group", { exact: true })).toBeVisible();
        await opened(page.url(), true);
        await page
          .getByRole("button", { name: "Table graph", exact: true })
          .click();
        await expect(graph.getByText("Synthetic group", { exact: true })).toBeVisible();
        await graph.getByRole("button", { name: /^projects\b/ }).click();
        await expect(
          page.getByRole("heading", { name: "projects", exact: true }),
        ).toBeVisible();
        await expect.poll(() => query().get("table")).toBe("projects");
      },
    ],
    [
      "link controls fit desktop and narrow screens",
      async () => {
        const screenshots = process.env.LIFE_UI_TEST_SCREENSHOTS;
        if (screenshots) await mkdir(screenshots, { recursive: true });
        for (const [width, colorScheme] of [
          [1440, "light"],
          [390, "dark"],
        ] as const) {
          await page.setViewportSize({ width, height: 1000 });
          await page.emulateMedia({ colorScheme });
          await page
            .getByRole("button", { name: "Fixture record", exact: true })
            .click();
          const copy = editor.getByRole("button", {
            name: "Copy link",
            exact: true,
          });
          await expect(copy).toBeEnabled();
          const box = await copy.boundingBox();
          expect(box!.x).toBeGreaterThanOrEqual(0);
          expect(box!.x + box!.width).toBeLessThanOrEqual(width);
          await expect
            .poll(() =>
              page.evaluate(
                () => document.documentElement.scrollWidth <= innerWidth,
              ),
            )
            .toBe(true);
          if (screenshots)
            await page.screenshot({
              path: resolve(screenshots, `navigation-record-${width}.png`),
              fullPage: true,
            });
          await page
            .getByRole("button", { name: "Close record", exact: true })
            .click();
          if (screenshots)
            await page.screenshot({
              path: resolve(screenshots, `navigation-table-${width}.png`),
              fullPage: true,
            });
        }
        await page.setViewportSize({ width: 1440, height: 1000 });
      },
    ],
  ];
  for (const [name, run] of cases) {
    if (
      process.env.LIFE_UI_NAVIGATION_CASE &&
      !name.includes(process.env.LIFE_UI_NAVIGATION_CASE)
    )
      continue;
    await home();
    try {
      await run();
      console.log("PASS: " + name);
    } catch (error) {
      console.error("FAIL: " + name);
      console.error("URL:", page.url());
      console.error(await page.locator("body").innerText());
      throw error;
    }
  }
} finally {
  accept = true;
  const page = ownedPage;
  await page?.evaluate(() => (window as any).release?.()).catch(() => {});
  if (page && await page.getByRole("button", {name:"Switch workspace",exact:true}).count()) {
    await page.getByRole("button", {name:"Switch workspace",exact:true}).click();
    await expect.poll(()=>page.workers().length).toBe(0);
  }
  await page?.goto(url).catch(() => {});
  await browser.close();
  server.stop(true);
  db.db.close();
}
