import { chromium, expect } from "@playwright/test";
import { disposableOrigin, workspacePage } from "./test-origin";
import { regressionHub } from "./workspace-regression-hub";
const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-markdown.localhost:5198/workspace?review";
const origin = disposableOrigin(url),
  source = process.argv[2];
if (!source) throw Error("Provide the life-data checkout");
const browser = await chromium.connectOverCDP(
  process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
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
const save = () =>
  page.getByRole("button", { name: "Save record", exact: true });
const undo = () =>
  page.getByRole("button", { name: "Undo last saved change", exact: true });
const quantity = () => page.getByLabel("Quantity", { exact: true });
const title = () => page.getByRole("textbox", { name: "Title", exact: true });
const close = () =>
  page.getByRole("button", { name: "Close record", exact: true }).click();
async function openFixture() {
  await page
    .getByRole("button", { name: "Fixture record", exact: true })
    .click();
}
async function setQuantity(value: string) {
  await quantity().fill(value);
  await save().click();
  await expect(save()).toBeEnabled();
}
async function body() {
  const toggle = page.getByRole("button", { name: "Body source", exact: true });
  if ((await toggle.getAttribute("aria-pressed")) !== "true")
    await toggle.click();
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
    process.env.LIFE_UI_UNDO_CASE &&
    !name.includes(process.env.LIFE_UI_UNDO_CASE)
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
    await page
      .getByLabel("Hub address")
      .fill(server.url.href.replace(/\/$/, ""));
    await page.getByLabel("Device token").fill("fixture");
    const sync = page.getByRole("button", { name: "Sync now", exact: true });
    await sync.click();
    await expect(sync).toBeEnabled({ timeout: 30000 });
    await expect(
      page.getByRole("button", { name: "Fixture record", exact: true }),
    ).toBeVisible();
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
    "a newer Markdown draft survives undo and waits for an explicit save",
    async () => {
      await openFixture();
      await setQuantity("43");
      const content = await body();
      await page.clock.install();
      await title().fill("Newer title draft");
      await content.fill("Newer unsaved Markdown");
      await undo().click();
      await expect(quantity()).toHaveValue("42");
      await expect(title()).toHaveValue("Newer title draft");
      await expect(content).toHaveValue("Newer unsaved Markdown");
      await expect(
        page.getByRole("status", { name: "Draft review", exact: true }),
      ).toBeVisible();
      const count = await page.evaluate(() => (window as any).writes.length);
      await page.clock.runFor(2500);
      expect(await page.evaluate(() => (window as any).writes.length)).toBe(
        count,
      );
      expect((await rows()).find((r) => r.id === "fixture-record")!.body).toBe(
        "Original body",
      );
      await save().click();
      await expect(
        page.getByRole("status", { name: "Draft review", exact: true }),
      ).toHaveCount(0);
      expect((await rows()).find((r) => r.id === "fixture-record")!.body).toBe(
        "Newer unsaved Markdown",
      );
      await page.clock.resume();
    },
  );
  await check(
    "undoing creation keeps a newer draft for explicit restore before save",
    async () => {
      await page
        .getByRole("button", { name: "New record", exact: true })
        .click();
      await title().fill("Created record");
      await save().click();
      await expect(save()).toBeEnabled();
      await title().fill("Retained draft after undo");
      await undo().click();
      await expect(title()).toHaveValue("Retained draft after undo");
      await expect(save()).toBeDisabled();
      const restore = page.getByRole("button", {
        name: "Restore record",
        exact: true,
      });
      await expect(restore).toBeEnabled();
      await restore.click();
      await expect(title()).toHaveValue("Retained draft after undo");
      await expect(save()).toBeEnabled();
      await save().click();
      await expect(save()).toBeEnabled();
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
    "a newer external revision blocks undo and preserves the draft and action",
    async () => {
      await openFixture();
      await setQuantity("43");
      await title().fill("Keep this draft");
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
      await expect(page.getByRole("alert")).toContainText(/changed|revision/i);
      await expect(title()).toHaveValue("Keep this draft");
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
      await expect(save()).toBeDisabled();
      await expect(
        page.getByRole("button", { name: "Close record", exact: true }),
      ).toBeDisabled();
      await expect(
        page.getByRole("button", { name: "New record", exact: true }),
      ).toBeDisabled();
      await expect(title()).toBeDisabled();
      await page.evaluate(() => (window as any).releaseUndo());
      await expect(quantity()).toHaveValue("42");
      await expect(save()).toBeEnabled();
    },
  );
  await check(
    "undoing another record preserves the open record draft",
    async () => {
      await openFixture();
      await setQuantity("43");
      await close();
      await page
        .getByRole("button", { name: "Second record", exact: true })
        .click();
      await title().fill("A different record draft");
      await undo().click();
      await expect(title()).toHaveValue("A different record draft");
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
      await page
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
      await page
        .getByRole("button", { name: "Move to trash", exact: true })
        .click();
      await page.getByRole("button", { name: "Trash", exact: true }).click();
      await openFixture();
      await page
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
