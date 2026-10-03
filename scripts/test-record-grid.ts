import { chromium, expect, type Page } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { disposableOrigin, workspacePage } from "./test-origin";
import { regressionHub } from "./workspace-regression-hub";
const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-grid.localhost:5228/workspace?review";
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source)
  throw Error("Usage: bun scripts/test-record-grid.ts <life-data-checkout>");
const { server, db } = await regressionHub(source, origin);
for (const [col, type, sql, value] of [
  ["amount", "number", "REAL", 1.5],
  ["active", "bool", "INTEGER", 0],
  ["day", "date", "TEXT", "2026-01-01"],
  ["moment", "datetime", "TEXT", "2026-01-01T12:00:00.000Z"],
  ["link", "url", "TEXT", "https://example.test"],
  ["email", "email", "TEXT", "fixture@example.test"],
  ["phone", "phone", "TEXT", "+15550123456"],
  ["data", "json", "TEXT", '{"n":1}'],
  ["related", "ref", "TEXT", "second-record"],
  ["relations", "multi_ref", "TEXT", '["second-record"]'],
  ["code", "text", "TEXT", "Original code"],
] as const) {
  const ddl = `ALTER TABLE widgets ADD COLUMN ${col} ${sql}`;
  db.db.exec(ddl);
  db.db
    .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
    .run("2026-01-01T00:00:00.000Z", ddl);
  db.db
    .query(
      "INSERT INTO catalog_properties(id,tbl,col,label,type,ref_table,immutable) VALUES (?,?,?,?,?,?,?)",
    )
    .run(
      `widgets.${col}`,
      "widgets",
      col,
      col,
      type,
      type.includes("ref") ? "widgets" : null,
      col === "code" ? 1 : 0,
    );
  db.db
    .query(`UPDATE widgets SET ${col}=? WHERE id='fixture-record'`)
    .run(value);
}
const browser = await chromium.connectOverCDP(
  process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
);
let page: Page | undefined;
let accept = true;
try {
  page = workspacePage(
    browser.contexts().flatMap((context) => context.pages()),
    url,
  );
  if (!page) throw Error("Open the reserved grid fixture page first");
  const owned = page;
  page.on("dialog", (dialog) => (accept ? dialog.accept() : dialog.dismiss()));
  const pageErrors: string[] = [];
  page.on("pageerror", (error) => {
    pageErrors.push(error.message);
    console.error("PAGE ERROR:", error.message);
  });
  page.setDefaultTimeout(8000);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.emulateMedia({ colorScheme: "light" });
  if (
    await page
      .getByRole("button", { name: "Switch workspace", exact: true })
      .count()
  ) {
    await page
      .getByRole("button", { name: "Switch workspace", exact: true })
      .click();
    await expect.poll(() => page!.workers().length).toBe(0);
  }
  await page.goto(new URL("/", url).href);
  await expect(
    page.getByRole("button", { name: "Open my workspace", exact: true }),
  ).toBeEnabled();
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.detach();
  await page.addInitScript(() => {
    const state = window as any;
    state.gridCalls = [];
    state.gridHeld = [];
    state.gridHold = "";
    state.releaseGrid = (reject = false) => {
      state.gridHold = "";
      state.gridHeld
        .splice(0)
        .forEach((fn: (reject: boolean) => void) => fn(reject));
    };
    const Original = window.Worker;
    window.Worker = class extends Original {
      requests = new Map<number, any>();
      postMessage(request: any, ...args: any[]) {
        this.requests.set(request.id, request);
        state.gridCalls.push(request);
        return super.postMessage(request, ...(args as [any]));
      }
      set onmessage(handler: any) {
        super.onmessage = (event) => {
          const request = this.requests.get(event.data.id);
          this.requests.delete(event.data.id);
          const deliver = (reject = false) =>
            handler?.(
              reject
                ? new MessageEvent("message", {
                    data: {
                      ...event.data,
                      error: { message: "late cell lookup" },
                      result: undefined,
                    },
                  })
                : event,
            );
          if (request?.method === state.gridHold) {
            state.gridHold = "";
            state.gridHeld.push(deliver);
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
  await page
    .getByRole("navigation", { name: "Tables", exact: true })
    .getByRole("button", { name: "widgets", exact: true })
    .click();
  const grid = page.getByRole("grid", { name: "Records", exact: true });
  const cell = (column: string, id = "fixture-record") =>
    grid.locator(`[data-row="${id}"][data-column="${column}"]`);
  const editor = page.getByRole("complementary", {
    name: "Record editor",
    exact: true,
  });
  const group = (label: string) =>
    page!.getByRole("group", { name: `Edit ${label}`, exact: true });
  async function show(label: string) {
    const details = owned.locator("details").filter({
      has: owned.locator("summary").filter({ hasText: /^\s*Columns\s*$/ }),
    });
    if (!(await details.evaluate((element) => element.hasAttribute("open"))))
      await details.locator("summary").click();
    await details
      .getByRole("checkbox", { name: `Show ${label}`, exact: true })
      .check();
    await details.locator("summary").click();
  }
  async function begin(column: string, label: string) {
    await cell(column).focus();
    await cell(column).press("Enter");
    await expect(group(label)).toBeVisible();
  }
  async function saved(column: string, value: unknown) {
    await expect.poll(async () => (await record())[column]).toEqual(value);
    await expect(owned.locator("[data-cell-editor]")).toHaveCount(0);
  }
  async function record() {
    return owned.evaluate(async () => {
      const { WorkspaceDatabase } = await import("/src/lib/database.ts");
      const database = new WorkspaceDatabase();
      try {
        await database.request("open");
        return (
          await database.request("rows", {
            view: {
              table: "widgets",
              filters: [{ column: "id", op: "eq", value: "fixture-record" }],
              limit: 1,
            },
          })
        )[0];
      } finally {
        database.close();
      }
    });
  }
  async function check(name: string, body: () => Promise<void>) {
    if (
      process.env.LIFE_UI_GRID_CASE &&
      !name.includes(process.env.LIFE_UI_GRID_CASE)
    )
      return;
    await body();
    console.log("PASS", name);
  }
  await expect(grid).toBeVisible();
  await check(
    "fresh inline revision, Escape commit and hidden fields",
    async () => {
      await begin("title", "Title");
      await group("Title")
        .getByLabel("Title", { exact: true })
        .fill("Inline record");
      await group("Title").getByLabel("Title", { exact: true }).press("Escape");
      await saved("title", "Inline record");
      expect((await record()).quantity).toBe(42);
      const write = await owned.evaluate(() =>
        (window as any).gridCalls
          .filter((r: any) => r.method === "write")
          .at(-1),
      );
      expect(write.args.patch).toEqual({
        id: "fixture-record",
        title: "Inline record",
      });
      expect(write.args.expectedUpdatedAt).toMatch(/Z$/);
    },
  );
  await check(
    "incomplete numeric input stays a rejected draft instead of clearing data",
    async () => {
      const before = (await record()).quantity;
      await show("Quantity");
      await begin("quantity", "Quantity");
      const input = group("Quantity").getByLabel("Quantity", { exact: true });
      await input.fill("");
      await input.press("-");
      await input.press("Escape");
      await expect(group("Quantity").getByRole("alert")).toBeVisible();
      expect((await record()).quantity).toBe(before);
      await group("Quantity")
        .getByRole("button", { name: "Discard", exact: true })
        .click();
    },
  );
  await check("numeric zero and empty remain distinct", async () => {
    await show("Quantity");
    await begin("quantity", "Quantity");
    await group("Quantity").getByLabel("Quantity", { exact: true }).fill("0");
    await group("Quantity")
      .getByRole("button", { name: "Save cell", exact: true })
      .click();
    await saved("quantity", 0);
    await begin("quantity", "Quantity");
    await group("Quantity")
      .getByRole("button", { name: "Clear Quantity", exact: true })
      .click();
    await group("Quantity")
      .getByRole("button", { name: "Save cell", exact: true })
      .click();
    await saved("quantity", null);
  });
  await check("blank numeric whitespace clears instead of zero", async () => {
    await show("Quantity");
    await begin("quantity", "Quantity");
    await group("Quantity").getByLabel("Quantity", { exact: true }).fill(" ");
    await group("Quantity")
      .getByLabel("Quantity", { exact: true })
      .press("Escape");
    await saved("quantity", null);
  });
  await check(
    "validation failure and explicit Discard retain saved content",
    async () => {
      const before = (await record()).title;
      await begin("title", "Title");
      await group("Title").getByLabel("Title", { exact: true }).fill("");
      await group("Title").getByLabel("Title", { exact: true }).press("Escape");
      await expect(group("Title").getByRole("alert")).toBeVisible();
      await expect(
        group("Title").getByLabel("Title", { exact: true }),
      ).toHaveValue("");
      await expect(
        group("Title").getByLabel("Title", { exact: true }),
      ).toBeFocused();
      expect((await record()).title).toBe(before);
      const attempts = await owned.evaluate(
        () =>
          (window as any).gridCalls.filter((r: any) => r.method === "write")
            .length,
      );
      const input = group("Title").getByLabel("Title", { exact: true });
      await input.press("Tab");
      await expect(
        group("Title").getByRole("button", {
          name: "Clear Title",
          exact: true,
        }),
      ).toBeFocused();
      await owned.keyboard.press("Shift+Tab");
      await expect(input).toBeFocused();
      await owned.keyboard.press("Tab");
      await owned.keyboard.press("Tab");
      await expect(
        group("Title").getByRole("button", { name: "Save cell", exact: true }),
      ).toBeFocused();
      await owned.keyboard.press("Tab");
      const discard = group("Title").getByRole("button", {
        name: "Discard",
        exact: true,
      });
      await expect(discard).toBeFocused();
      expect(
        await owned.evaluate(
          () =>
            (window as any).gridCalls.filter((r: any) => r.method === "write")
              .length,
        ),
      ).toBe(attempts);
      await expect(input).toHaveValue("");
      await discard.press("Enter");
      await expect(owned.locator("[data-cell-editor]")).toHaveCount(0);
      expect((await record()).title).toBe(before);
    },
  );
  await check("typed controls and cleared boolean", async () => {
    for (const [column, type, value, want] of [
      ["amount", "number", "2.75", 2.75],
      ["day", "date", "2026-02-03", "2026-02-03"],
      [
        "moment",
        "datetime",
        "2026-02-03T14:15:16.123",
        "2026-02-03T14:15:16.123Z",
      ],
      ["link", "url", "https://example.test/new", "https://example.test/new"],
      ["email", "email", "other@example.test", "other@example.test"],
      ["phone", "phone", "+15550987654", "+15550987654"],
      ["data", "json", '{"kept":true}', '{"kept":true}'],
    ] as const) {
      await show(column);
      await begin(column, column);
      const input = group(column).getByLabel(column, { exact: true });
      await input.fill(value);
      if (type === "datetime") await input.blur();
      await group(column)
        .getByRole("button", { name: "Save cell", exact: true })
        .click();
      await saved(column, want);
    }
    await show("active");
    await begin("active", "active");
    await group("active")
      .getByRole("checkbox", { name: "active", exact: true })
      .check();
    await group("active")
      .getByRole("button", { name: "Save cell", exact: true })
      .click();
    await saved("active", 1);
    await begin("active", "active");
    await group("active")
      .getByRole("checkbox", { name: "active", exact: true })
      .uncheck();
    await group("active")
      .getByRole("button", { name: "Save cell", exact: true })
      .click();
    await saved("active", 0);
  });
  await check("select, multi-select and named reference editors", async () => {
    await show("Status");
    await begin("status", "Status");
    await group("Status")
      .getByLabel("Status", { exact: true })
      .selectOption("Dynamic");
    await group("Status")
      .getByRole("button", { name: "Save cell", exact: true })
      .click();
    await saved("status", "Dynamic");
    await show("Tags");
    await begin("tags", "Tags");
    await group("Tags")
      .getByLabel("Tags", { exact: true })
      .selectOption(["Fixed", "Dynamic"]);
    await group("Tags")
      .getByRole("button", { name: "Save cell", exact: true })
      .click();
    await saved("tags", '["Fixed","Dynamic"]');
    await show("related");
    await begin("related", "related");
    await group("related")
      .getByLabel("Search related", { exact: true })
      .fill("Second");
    await expect(
      group("related").getByRole("option", {
        name: "Second record",
        exact: true,
      }),
    ).toBeAttached();
    await group("related")
      .getByLabel("related", { exact: true })
      .selectOption("second-record");
    await group("related")
      .getByRole("button", { name: "Save cell", exact: true })
      .click();
    await saved("related", "second-record");
    await show("relations");
    await begin("relations", "relations");
    await group("relations")
      .getByRole("button", { name: "Remove Second record", exact: true })
      .click();
    await group("relations")
      .getByRole("button", { name: "Save cell", exact: true })
      .click();
    await saved("relations", "[]");
  });
  await check("Markdown source preserves raw content", async () => {
    await show("Body");
    await begin("body", "Body");
    await group("Body")
      .getByRole("button", { name: "Body source", exact: true })
      .click();
    await group("Body")
      .getByRole("textbox", { name: /Body/ })
      .fill("# Grid body\n\nExact source.");
    await group("Body")
      .getByRole("button", { name: "Save cell", exact: true })
      .click();
    await saved("body", "# Grid body\n\nExact source.");
  });
  await check(
    "keyboard cursor, typed-editor Escape and Tab commit before movement",
    async () => {
      await show("Quantity");
      await show("Status");
      await cell("title").focus();
      await cell("title").press("ArrowRight");
      expect(
        await owned.evaluate(() =>
          document.activeElement?.getAttribute("data-row"),
        ),
      ).toBe("fixture-record");
      await begin("quantity", "Quantity");
      await group("Quantity")
        .getByLabel("Quantity", { exact: true })
        .fill("23");
      await group("Quantity")
        .getByLabel("Quantity", { exact: true })
        .press("Tab");
      await saved("quantity", 23);
      expect(
        await owned.evaluate(() =>
          document.activeElement?.getAttribute("data-row"),
        ),
      ).toBe("fixture-record");
      await begin("status", "Status");
      await group("Status")
        .getByLabel("Status", { exact: true })
        .press("Escape");
      await expect(owned.locator("[data-cell-editor]")).toHaveCount(0);
    },
  );
  await check(
    "stale row rejects instead of rebasing a cell draft",
    async () => {
      await begin("title", "Title");
      await group("Title")
        .getByLabel("Title", { exact: true })
        .fill("Stale draft");
      await owned.evaluate(async () => {
        const { WorkspaceDatabase } = await import("/src/lib/database.ts");
        const database = new WorkspaceDatabase();
        try {
          await database.request("open");
          await database.request("write", {
            table: "widgets",
            patch: { id: "fixture-record", quantity: 55 },
          });
        } finally {
          database.close();
        }
      });
      await group("Title")
        .getByRole("button", { name: "Save cell", exact: true })
        .click();
      await expect(group("Title").getByRole("alert")).toContainText(
        /changed|revision/i,
      );
      await expect(
        group("Title").getByLabel("Title", { exact: true }),
      ).toHaveValue("Stale draft");
      expect((await record()).quantity).toBe(55);
      await group("Title")
        .getByRole("button", { name: "Discard", exact: true })
        .click();
    },
  );
  await check(
    "pending write blocks leaving and cancelled record draft stays",
    async () => {
      await begin("title", "Title");
      await group("Title")
        .getByLabel("Title", { exact: true })
        .fill("Held save");
      await owned.evaluate(() => ((window as any).gridHold = "write"));
      await group("Title")
        .getByRole("button", { name: "Save cell", exact: true })
        .click();
      await owned.waitForFunction(() => (window as any).gridHeld.length > 0);
      await expect(
        owned.getByRole("button", { name: "Switch workspace", exact: true }),
      ).toBeDisabled();
      await expect(grid).toBeVisible();
      await owned.evaluate(() => (window as any).releaseGrid());
      await saved("title", "Held save");
      await cell("title").press("Meta+Enter");
      await expect(editor).toBeVisible();
      await editor.getByLabel("Title", { exact: true }).fill("Record draft");
      accept = false;
      await show("Quantity");
      await cell("quantity").focus();
      await cell("quantity").press("Enter");
      await expect(
        owned.getByText("Opening cell…", { exact: true }),
      ).toHaveCount(0);
      await expect(editor.getByLabel("Title", { exact: true })).toHaveValue(
        "Record draft",
      );
      await expect(owned.locator("[data-cell-editor]")).toHaveCount(0);
      accept = true;
      await owned
        .getByRole("button", { name: "Close record", exact: true })
        .click();
    },
  );
  await check(
    "cancelled cell navigation keeps input and late lookup errors cannot overwrite a new editor",
    async () => {
      await begin("title", "Title");
      await group("Title")
        .getByLabel("Title", { exact: true })
        .fill("Cell draft");
      accept = false;
      await owned
        .getByRole("button", { name: "Switch workspace", exact: true })
        .click();
      await expect(
        group("Title").getByLabel("Title", { exact: true }),
      ).toHaveValue("Cell draft");
      accept = true;
      await group("Title")
        .getByRole("button", { name: "Discard", exact: true })
        .click();
      await owned.evaluate(() => ((window as any).gridHold = "rows"));
      await cell("title").focus();
      await cell("title").press("Enter");
      await owned.waitForFunction(() => (window as any).gridHeld.length > 0);
      await owned
        .getByRole("button", { name: "New record", exact: true })
        .click();
      await expect(editor).toBeVisible();
      await owned.evaluate(() => (window as any).releaseGrid(true));
      await expect(
        owned.getByText("Opening cell…", { exact: true }),
      ).toHaveCount(0);
      await expect(
        owned.getByText("late cell lookup", { exact: true }),
      ).toHaveCount(0);
      await owned
        .getByRole("button", { name: "Close record", exact: true })
        .click();
    },
  );
  await check("bottom new and duplicate open unsaved drafts", async () => {
    await owned.evaluate(async () => {
      const { WorkspaceDatabase } = await import("/src/lib/database.ts");
      const database = new WorkspaceDatabase();
      try {
        await database.request("open");
        await database.request("write", {
          table: "widgets",
          patch: { id: "fixture-record", quantity: null },
        });
      } finally {
        database.close();
      }
    });
    await owned
      .getByRole("button", { name: "New record at bottom", exact: true })
      .click();
    await expect(editor).toBeVisible();
    await expect(
      editor.getByRole("heading", { name: "Untitled", exact: true }),
    ).toBeVisible();
    await editor.getByLabel("Title", { exact: true }).fill("Created at bottom");
    await editor
      .getByRole("button", { name: "Save record", exact: true })
      .click();
    await expect(
      editor.getByRole("heading", { name: "Created at bottom", exact: true }),
    ).toBeVisible();
    await owned
      .getByRole("button", { name: "Close record", exact: true })
      .click();
    const sourceTitle = (await record()).title;
    await cell("title").focus();
    await cell("title").press("ArrowRight");
    await owned
      .getByRole("button", { name: "Duplicate record", exact: true })
      .click();
    await expect(editor.getByLabel("Title", { exact: true })).toHaveValue(
      sourceTitle as string,
    );
    await expect(editor.getByLabel("code", { exact: true })).toHaveValue(
      "Original code",
    );
    await expect(
      editor.getByRole("heading", { name: "Untitled", exact: true }),
    ).toBeVisible();
    await editor.getByLabel("Title", { exact: true }).fill("Duplicate saved");
    await editor
      .getByRole("button", { name: "Save record", exact: true })
      .click();
    await expect(
      editor.getByRole("heading", { name: "Duplicate saved", exact: true }),
    ).toBeVisible();
    await expect(editor.getByLabel("Quantity", { exact: true })).toHaveValue(
      "",
    );
    await owned
      .getByRole("button", { name: "Close record", exact: true })
      .click();
  });
  await check(
    "grid trash and restore use a fresh revision and retain rejected cell drafts",
    async () => {
      await show("Quantity");
      await begin("quantity", "Quantity");
      await group("Quantity")
        .getByLabel("Quantity", { exact: true })
        .fill("invalid");
      await group("Quantity")
        .getByLabel("Quantity", { exact: true })
        .press("Escape");
      await expect(group("Quantity").getByRole("alert")).toBeVisible();
      // The footer is outside the scroll container; locate by the component's root.
      const trashAction = owned
        .locator(".record-grid")
        .getByRole("button", { name: "Trash selected record", exact: true });
      accept = false;
      await trashAction.click();
      await expect(
        owned.getByText("Opening record action…", { exact: true }),
      ).toHaveCount(0);
      await expect(
        group("Quantity").getByLabel("Quantity", { exact: true }),
      ).toHaveValue("invalid");
      accept = true;
      await owned.evaluate(() => ((window as any).gridHold = "rows"));
      await trashAction.click();
      await owned.waitForFunction(() => (window as any).gridHeld.length > 0);
      await owned.evaluate(async () => {
        const { WorkspaceDatabase } = await import("/src/lib/database.ts");
        const database = new WorkspaceDatabase();
        try {
          await database.request("open");
          await database.request("write", {
            table: "widgets",
            patch: { id: "fixture-record", quantity: 77 },
          });
        } finally {
          database.close();
        }
      });
      await owned.evaluate(() => (window as any).releaseGrid());
      await expect(
        owned.getByRole("alert").filter({ hasText: /changed|revision/i }),
      ).toBeVisible();
      await expect(
        group("Quantity").getByLabel("Quantity", { exact: true }),
      ).toHaveValue("invalid");
      expect((await record()).quantity).toBe(77);
      await trashAction.click();
      await expect(cell("title")).toHaveCount(0);
      await expect(owned.locator("[data-cell-editor]")).toHaveCount(0);
      await owned.getByRole("button", { name: "Trash", exact: true }).click();
      await expect(cell("title")).toBeVisible();
      await cell("title").focus();
      await cell("title").press("ArrowRight");
      const restoreAction = owned.getByRole("button", {
        name: "Restore selected record",
        exact: true,
      });
      await expect(restoreAction).toHaveText("Restore record");
      await restoreAction.click();
      await expect(cell("title")).toHaveCount(0);
      await owned
        .getByRole("button", { name: "All records", exact: true })
        .click();
      await expect(cell("title")).toBeVisible();
      expect((await record()).quantity).toBe(77);
    },
  );
  if (process.env.LIFE_UI_SCREENSHOTS) {
    await mkdir(process.env.LIFE_UI_SCREENSHOTS, { recursive: true });
    await page.locator(".grid-scroll").evaluate((el) => {
      el.scrollLeft = 0;
      el.scrollTop = 0;
    });
    await page.screenshot({
      path: process.env.LIFE_UI_SCREENSHOTS + "/grid-1440.png",
      fullPage: true,
    });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.emulateMedia({ colorScheme: "dark" });
    await page.screenshot({
      path: process.env.LIFE_UI_SCREENSHOTS + "/grid-390.png",
      fullPage: true,
    });
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
  }
  expect(
    pageErrors.filter((error) => !error.startsWith("ResizeObserver loop")),
  ).toEqual([]);
} finally {
  accept = true;
  await page?.evaluate(() => (window as any).releaseGrid?.()).catch(() => {});
  try {
    if (
      page &&
      (await page
        .getByRole("button", { name: "Switch workspace", exact: true })
        .count())
    ) {
      await page
        .getByRole("button", { name: "Switch workspace", exact: true })
        .click();
      await expect.poll(() => page!.workers().length).toBe(0);
    }
  } finally {
    await browser.close();
    server.stop(true);
    db.db.close();
  }
}
