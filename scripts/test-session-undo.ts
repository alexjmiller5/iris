import { chromium, expect } from "@playwright/test";
import { disposableOrigin, recordReady, recordSaved, workspacePage } from "./test-origin";
import { regressionHub } from "./workspace-regression-hub";
const url =
  process.env.IRIS_TEST_URL ??
  "http://iris-markdown.localhost:5198/workspace?review";
const origin = disposableOrigin(url),
  source = process.argv[2];
if (!source) throw Error("Provide the soma checkout");
const browser = await chromium.connectOverCDP(
  process.env.IRIS_TEST_CDP ?? "http://127.0.0.1:9222",
);
const page = workspacePage(
  browser.contexts().flatMap((c) => c.pages()),
  url,
);
page.setDefaultTimeout(10000);
page.on("dialog", (d) => d.accept());
page.on("pageerror", (error) => console.error("Page error:", error.message));
await page.addInitScript(() => {
  const state = window as any;
  state.writes = [];
  state.activeWorkers = new Set();
  state.holdUndo = false;
  state.heldUndo = [];
  state.releaseUndo = () => {
    state.holdUndo = false;
    state.heldUndo.splice(0).forEach((deliver: () => void) => deliver());
  };
  const Original = window.Worker;
  window.Worker = class extends Original {
    constructor(...args: ConstructorParameters<typeof Worker>) {
      super(...args); state.activeWorkers.add(this);
    }
    terminate() { state.activeWorkers.delete(this); super.terminate(); }
    methods = new Map<number, string>();
    postMessage(message: any, ...args: any[]) {
      this.methods.set(message.id, message.method);
      if (message.method === "write") state.writes.push(message.args);
      return super.postMessage(message, ...(args as [any]));
    }
    set onmessage(handler: any) {
      super.onmessage = (event) => {
        const method = this.methods.get(event.data.id);
        this.methods.delete(event.data.id);
        const deliver = () => handler.call(this, event);
        if (method === "undo" && state.holdUndo) state.heldUndo.push(deliver);
        else deliver();
      };
    }
  };
});
// Undo pauses autosave over a kept draft; Save draft stores it and resumes autosave.
const save = () =>
  page.getByRole("button", { name: "Save draft", exact: true });
const undo = () =>
  page.getByRole("button", { name: "Undo last saved change", exact: true });
const quantity = () => page.getByLabel("Quantity", { exact: true });
const title = () => page.getByRole("textbox", { name: "Title", exact: true });
const editor = () =>
  page.getByRole("complementary", { name: "Record editor", exact: true });
const close = () =>
  page.getByRole("button", { name: "Close record", exact: true }).click();
async function openFixture() {
  await page
    .getByRole("button", { name: "Fixture record", exact: true })
    .click();
  await recordReady(page);
}
async function setQuantity(value: string) {
  await quantity().fill(value);
  await recordSaved(page);
}
async function body() {
  if (!await page.locator('textarea[aria-label="Body"]').isVisible()) {
    await page.getByRole("button", {name:"Body options",exact:true}).click();
    await page.getByRole("menuitem", {name:"Body source",exact:true}).click();
  }
  return page.getByRole("textbox", { name: "Body", exact: true });
}
async function rows() {
  return page.evaluate(async () => {
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const other = new WorkspaceDatabase();
    try {
      await other.request("open");
      return [
        ...(await other.request("rows", { view: { table: "widgets" } })),
        ...(await other.request("rows", {
          view: { table: "widgets", trash: true },
        })),
      ];
    } finally {
      other.close();
    }
  });
}
async function closeFixture() {
  await page.evaluate(() => (window as any).releaseUndo?.());
  const leave = page.getByRole("button", {name:"Switch workspace",exact:true});
  if (await leave.count()) await leave.click();
  await page.waitForFunction(() => !(window as any).activeWorkers?.size, undefined, {timeout:15000});
}
async function check(name: string, run: () => Promise<void>) {
  if (
    process.env.IRIS_UNDO_CASE &&
    !name.includes(process.env.IRIS_UNDO_CASE)
  )
    return;
  console.log("RUN: " + name);
  const { server, db } = await regressionHub(source, origin, 0);
  db.db.exec(
    "INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES ('positive','widgets','invariant',1,'SELECT id FROM changed WHERE quantity<0','Quantity cannot be negative.')",
  );
  try {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await closeFixture();
    await page.goto(new URL("/", url).href);
    await expect(
      page.getByRole("button", { name: "Open my workspace", exact: true }),
    ).toBeEnabled({ timeout: 30000 });
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Storage.clearDataForOrigin", {
      origin,
      storageTypes: "all",
    });
    await cdp.detach();
    await page.goto(url);
    await page
      .getByRole("button", { name: "Open my workspace", exact: true })
      .click({ timeout: 30000 });
    await page.getByText("Connect to a hub", { exact: true }).click();
  await page.getByText("Use a device token", { exact: true }).click();
    await page
      .getByLabel("Hub address")
      .fill(server.url.href.replace(/\/$/, ""));
    await page.getByLabel("Device token").fill("fixture");
    await page
      .getByRole("button", { name: "Connect", exact: true })
      .click();
    await page
      .getByRole("navigation", { name: "Tables", exact: true })
      .getByRole("button", { name: "widgets", exact: true })
      .click({ timeout: 30000 });
    await expect(
      page.getByRole("button", { name: "Fixture record", exact: true }),
    ).toBeVisible({ timeout: 30000 });
    await run();
    console.log("PASS: " + name);
  } finally {
    await closeFixture();
    await page.goto(url);
    await expect(
      page.getByRole("button", { name: "Open my workspace", exact: true }),
    ).toBeEnabled({ timeout: 30000 });
    server.stop(true);
    db.db.close();
  }
}
try {
  await check(
    "edit undo restores a field, updates its revision and leaves no redo",
    async () => {
      await openFixture();
      const before = (await rows()).find((r) => r.id === "fixture-record")!;
      await setQuantity("43");
      await undo().click();
      await expect(quantity()).toHaveValue("42");
      await expect(undo()).toBeDisabled();
      const after = (await rows()).find((r) => r.id === "fixture-record")!;
      expect(after.quantity).toBe(42);
      expect(after.updated_at > before.updated_at).toBe(true);
    },
  );
  await check(
    "undo first saves pending field and Markdown edits as one step, then reverts that step",
    async () => {
      await openFixture();
      await setQuantity("43");
      const content = await body();
      const count = await page.evaluate(() => (window as any).writes.length);
      await title().fill("Newer title draft");
      await content.fill("Newer unsaved Markdown");
      await undo().click();
      await expect(title()).toHaveValue("Fixture record");
      await expect(content).toHaveValue("Original body");
      await expect(quantity()).toHaveValue("43");
      await expect(
        page.getByRole("status", { name: "Draft review", exact: true }),
      ).toHaveCount(0);
      expect(
        await page.evaluate((n) => (window as any).writes.slice(n), count),
      ).toEqual([
        expect.objectContaining({
          patch: expect.objectContaining({
            title: "Newer title draft",
            body: "Newer unsaved Markdown",
          }),
        }),
      ]);
      const stored = (await rows()).find((r) => r.id === "fixture-record")!;
      expect([stored.quantity, stored.title, stored.body]).toEqual([
        43,
        "Fixture record",
        "Original body",
      ]);
    },
  );
  await check(
    "undoing creation keeps a refused draft for explicit restore before save",
    async () => {
      await page
        .getByRole("button", { name: "New record", exact: true })
        .click();
      await title().fill("Created record");
      await recordSaved(page);
      // A valid edit would save before Undo; a refused one stays the draft.
      await title().fill("");
      await recordSaved(page);
      await undo().click();
      await expect(title()).toHaveValue("");
      await expect(title()).toBeDisabled();
      await expect(save()).toBeDisabled();
      const restore = editor().getByRole("button", {
        name: "Restore record",
        exact: true,
      });
      await expect(restore).toBeEnabled();
      await restore.click();
      await expect(title()).toHaveValue("");
      await expect(save()).toBeEnabled();
      await title().fill("Retained draft after undo");
      await save().click();
      await expect(save()).toHaveCount(0);
      expect(
        (await rows()).find((r) => r.title === "Retained draft after undo")!
          .deleted_at,
      ).toBeNull();
    },
  );
  await check(
    "a rejected edit retains the prior receipt and invalid draft",
    async () => {
      await openFixture();
      await setQuantity("43");
      await setQuantity("-1");
      await expect(page.getByRole("alert")).toContainText(
        "Quantity cannot be negative",
      );
      await undo().click();
      await expect(quantity()).toHaveValue("-1");
      await expect(
        page.getByRole("status", { name: "Draft review", exact: true }),
      ).toBeVisible();
      expect(
        (await rows()).find((r) => r.id === "fixture-record")!.quantity,
      ).toBe(42);
    },
  );
  await check(
    "a newer external revision blocks undo and preserves the refused draft and action",
    async () => {
      await openFixture();
      await setQuantity("43");
      // A valid edit would save before Undo; a refused one stays the draft.
      await title().fill("");
      await recordSaved(page);
      await page.evaluate(async () => {
        const { WorkspaceDatabase } = await import("/src/lib/database.ts");
        const other = new WorkspaceDatabase();
        try {
          await other.request("open");
          const [row] = await other.request("rows", {
            view: {
              table: "widgets",
              filters: [{ column: "id", op: "eq", value: "fixture-record" }],
            },
          });
          await other.request("write", {
            table: "widgets",
            patch: { id: row.id, quantity: 44 },
            expectedUpdatedAt: row.updated_at,
          });
        } finally {
          other.close();
        }
      });
      await undo().click();
      await expect(
        page.getByRole("alert").filter({ hasText: /changed|revision/i }),
      ).toBeVisible();
      await expect(title()).toHaveValue("");
      await expect(undo()).toBeEnabled();
      expect(
        (await rows()).find((r) => r.id === "fixture-record")!.quantity,
      ).toBe(44);
    },
  );
  await check(
    "pending undo locks writes and navigation until the committed receipt arrives",
    async () => {
      await openFixture();
      await setQuantity("43");
      await page.evaluate(() => ((window as any).holdUndo = true));
      await undo().click();
      await page.waitForFunction(() => (window as any).heldUndo.length === 1);
      await expect(
        page.getByRole("button", { name: "Close record", exact: true }),
      ).toBeDisabled();
      await expect(
        page.getByRole("button", { name: "New record", exact: true }),
      ).toBeDisabled();
      await expect(title()).toBeDisabled();
      await page.evaluate(() => (window as any).releaseUndo());
      await expect(quantity()).toHaveValue("42");
      await expect(title()).toBeEnabled();
    },
  );
  await check(
    "undoing another record preserves the open record's refused draft",
    async () => {
      await openFixture();
      await setQuantity("43");
      await close();
      await page
        .getByRole("button", { name: "Second record", exact: true })
        .click();
      await recordReady(page);
      // A valid edit would save before Undo; a refused one stays the draft.
      await title().fill("");
      await recordSaved(page);
      await undo().click();
      await expect(title()).toHaveValue("");
      await expect(
        page.getByRole("status", { name: "Draft review", exact: true }),
      ).toBeVisible();
      const stored = await rows();
      expect(stored.find((r) => r.id === "fixture-record")!.quantity).toBe(42);
      expect(stored.find((r) => r.id === "second-record")!.title).toBe(
        "Second record",
      );
    },
  );
  await check(
    "undo broadcasts the committed row to another open tab",
    async () => {
      const observer = await page.context().newPage();
      try {
        await observer.goto(url + "&observer=undo");
        await observer
          .getByRole("button", { name: "Open my workspace", exact: true })
          .click({ timeout: 30000 });
        const observed = observer
          .getByRole("row")
          .filter({
            has: observer.getByRole("button", {
              name: "Fixture record",
              exact: true,
            }),
          });
        await expect(observed).toContainText("42");
        await openFixture();
        await setQuantity("43");
        await expect(observed).toContainText("43");
        await undo().click();
        await expect(observed).toContainText("42");
      } finally {
        await observer.close();
      }
    },
  );
  await check(
    "trash and restore undo use new tombstones and preserve earlier values",
    async () => {
      await openFixture();
      await editor()
        .getByRole("button", { name: "Move to trash", exact: true })
        .click();
      await expect(
        page.getByRole("complementary", { name: "Record editor" }),
      ).toHaveCount(0);
      await undo().click();
      await expect(
        page.getByRole("button", { name: "Fixture record", exact: true }),
      ).toBeVisible();
      await openFixture();
      await editor()
        .getByRole("button", { name: "Move to trash", exact: true })
        .click();
      await page.getByRole("button", { name: "Trash", exact: true }).click();
      await openFixture();
      await editor()
        .getByRole("button", { name: "Restore record", exact: true })
        .click();
      await expect(
        page.getByRole("complementary", { name: "Record editor" }),
      ).toHaveCount(0);
      await undo().click();
      await expect(
        page.getByRole("button", { name: "Fixture record", exact: true }),
      ).toBeVisible();
      expect(
        (await rows()).find((r) => r.id === "fixture-record")!.deleted_at,
      ).not.toBeNull();
    },
  );
  await check(
    "reopening clears the volatile action and narrow editing keeps Undo reachable",
    async () => {
      await page.setViewportSize({ width: 390, height: 844 });
      await openFixture();
      await setQuantity("43");
      await undo().click();
      await expect(quantity()).toHaveValue("42");
      await setQuantity("43");
      await close();
      await page.reload();
      await page
        .getByRole("button", { name: "Open my workspace", exact: true })
        .click();
      await expect(undo()).toBeDisabled();
    },
  );
} finally {
  await browser.close();
}
