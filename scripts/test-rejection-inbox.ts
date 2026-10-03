import { chromium, expect } from "@playwright/test";
import { disposableOrigin, workspacePage } from "./test-origin";
import { regressionHub } from "./workspace-regression-hub";

const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-rejections.localhost:5238/workspace?review";
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source) throw Error("Provide the life-data checkout");
const fixture = await regressionHub(source, origin);
const browser = await chromium.connectOverCDP(
  process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
  { timeout: 30000 },
);
const page = workspacePage(
  browser.contexts().flatMap((context) => context.pages()),
  url,
);
if (!page) throw Error("Open the reserved rejection fixture page first");
page.setDefaultTimeout(10000);
page.on("dialog", (dialog) => dialog.accept());
page.on("pageerror", (error) => console.error("PAGE ERROR:", error.message));
await page.addInitScript(() => {
  const state = window as any;
  state.activeWorkers = new Set();
  state.hold = null;
  state.held = [];
  state.release = () => {
    state.hold = null;
    state.held.splice(0).forEach((deliver: () => void) => deliver());
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
const summary = () => page.locator(".rejections summary");
const reviewButtons = () =>
  page.getByRole("button", { name: "Review rejected edit", exact: true });
const sync = () => page.getByRole("button", { name: "Sync now", exact: true });
async function leave() {
  const close = page!.getByRole("button", {
    name: "Close record",
    exact: true,
  });
  if (await close.count()) await close.click();
  const button = page!.getByRole("button", {
    name: "Switch workspace",
    exact: true,
  });
  if (await button.count()) await button.click();
}
async function connect() {
  console.log("CONNECT");
  await page!
    .getByText("Connect to a hub", { exact: true })
    .click({ timeout: 30000 });
  await page!.getByText("Use a device token", { exact: true }).click();
  await page!.getByLabel("Hub address").fill(fixture.server.url.origin);
  await page!.getByLabel("Device token").fill("fixture");
  await sync().click();
  await expect(sync()).toBeEnabled({ timeout: 30000 });
}
async function probe(method: string, args: object = {}) {
  return page!.evaluate(
    ({ method, args }) => (window as any).rejectionProbe.request(method, args),
    { method, args },
  );
}
try {
  await page.setViewportSize({ width: 1440, height: 1000 });
  await leave();
  await page.goto(new URL("/", url).href);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.detach();
  await page.goto(url);
  await page
    .getByRole("button", { name: "Open my workspace", exact: true })
    .click();
  await connect();
  await expect(
    page.getByRole("button", { name: "Fixture record", exact: true }),
  ).toBeVisible();
  await leave();

  await page
    .context()
    .route(`${origin}/src/lib/database.worker.ts*`, async (route) => {
      const response = await route.fetch();
      const original = await response.text();
      const body = original.replace(
        "switch (method) {",
        `switch (method) {
      case '__test_all': return db.all(args.sql, args.params);
      case '__test_run': return db.run(args.sql, args.params);`,
      );
      if (body === original) throw Error("Worker test seam missing");
      await route.fulfill({ response, body });
    });
  console.log("SEED");
  await page.evaluate(async () => {
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const probe = new WorkspaceDatabase();
    (window as any).rejectionProbe = probe;
    await probe.request("open");
    for (let i = 0; i < 205; i++)
      await probe.request("write", {
        table: "widgets",
        patch: {
          title: `Rejected ${String(i).padStart(3, "0")}`,
          body: "Rejected body",
        },
      });
  });
  await page.context().unroute(`${origin}/src/lib/database.worker.ts*`);
  const stamp = new Date().toISOString();
  fixture.db.db
    .query(
      "UPDATE catalog_properties SET pattern='Allowed',updated_at=?,hub_at=? WHERE col='title'",
    )
    .run(stamp, stamp);
  await page
    .getByRole("button", { name: "Open my workspace", exact: true })
    .click();
  await connect();
  await expect(summary()).toHaveText("205 rejected edits need attention");
  await summary().click();
  // End-user RED: the old inbox renders all 205 records and has no bounded paging.
  await expect(reviewButtons()).toHaveCount(100);
  await expect(
    page.getByText("Showing 100 of 205 rejected edits", { exact: true }),
  ).toBeVisible();
  const stored = (await probe("__test_all", {
    sql: "SELECT tbl,row_id,errors FROM _core_rejected ORDER BY tbl COLLATE BINARY,row_id COLLATE BINARY",
  })) as any[];
  const broken = stored[150];
  await probe("__test_run", {
    sql: "UPDATE _core_rejected SET errors=? WHERE tbl=? AND row_id=?",
    params: ["invalid fixture JSON", broken.tbl, broken.row_id],
  });
  await page
    .getByRole("button", { name: "Load more rejected edits", exact: true })
    .click();
  await expect(page.locator(".rejections [role=alert]")).toContainText(
    "Invalid stored rejection data",
  );
  await expect(reviewButtons()).toHaveCount(100);
  expect(
    (
      (await probe("__test_all", {
        sql: "SELECT count(*) AS n FROM _core_rejected",
      })) as any[]
    )[0].n,
  ).toBe(205);
  await probe("__test_run", {
    sql: "UPDATE _core_rejected SET errors=? WHERE tbl=? AND row_id=?",
    params: [broken.errors, broken.tbl, broken.row_id],
  });
  await page
    .getByRole("button", { name: "Retry rejected edits", exact: true })
    .click();
  await expect(reviewButtons()).toHaveCount(200);
  console.log(
    "PASS: corrupt later page preserves loaded entries/storage and retries the same offset",
  );
  await page
    .getByRole("button", { name: "Load more rejected edits", exact: true })
    .click();
  await expect(reviewButtons()).toHaveCount(205);
  await expect(
    page.getByRole("button", { name: "Load more rejected edits", exact: true }),
  ).toHaveCount(0);
  console.log(
    "PASS: 205 actual hub rejections are counted and reachable through bounded pages",
  );

  const first = stored[0];
  await probe("__test_run", {
    sql: "UPDATE _core_rejected SET errors=? WHERE tbl=? AND row_id=?",
    params: ["invalid fixture JSON", first.tbl, first.row_id],
  });
  await leave();
  await page
    .getByRole("button", { name: "Open my workspace", exact: true })
    .click();
  await expect(summary()).toHaveText("205 rejected edits need attention");
  await summary().click();
  await expect(page.locator(".rejections [role=alert]")).toContainText(
    "Invalid stored rejection data",
  );
  await expect(reviewButtons()).toHaveCount(0);
  await expect(
    page
      .getByRole("grid")
      .getByRole("button", { name: /^Rejected / })
      .first(),
  ).toBeVisible();
  await probe("__test_run", {
    sql: "UPDATE _core_rejected SET errors=? WHERE tbl=? AND row_id=?",
    params: [first.errors, first.tbl, first.row_id],
  });
  await page
    .getByRole("button", { name: "Retry rejected edits", exact: true })
    .click();
  await expect(reviewButtons()).toHaveCount(100);
  console.log(
    "PASS: corrupt first page remains visible without blocking local rows; retry starts at zero",
  );

  // A later local save must not be overwritten merely by opening its old rejection.
  const localRow = (
    (await probe("rows", {
      view: {
        table: "widgets",
        filters: [{ column: "id", op: "eq", value: first.row_id }],
        limit: 1,
      },
    })) as any[]
  )[0];
  await probe("write", {
    table: "widgets",
    patch: { id: first.row_id, title: "Allowed", body: "Newer local body" },
    expectedUpdatedAt: localRow.updated_at,
  });
  await expect(reviewButtons()).toHaveCount(100);
  await probe("__test_run", {
    sql: "UPDATE catalog_properties SET immutable=1 WHERE tbl='widgets' AND col='body'",
  });
  for (const col of ["id", "created_at", "updated_at", "deleted_at", "hub_at"])
    await probe("__test_run", {
      sql: "INSERT INTO catalog_properties(id,tbl,col,label,type) VALUES (?,?,?,?,?)",
      params: [`widgets.${col}`, "widgets", col, `System ${col}`, "text"],
    });
  await reviewButtons().first().click();
  await expect(
    page.getByRole("textbox", { name: "Body", exact: true }),
  ).toHaveText("Newer local body");
  for (const col of ["id", "created_at", "updated_at", "deleted_at", "hub_at"])
    await expect(page.getByLabel(`System ${col}`, { exact: true })).toHaveCount(
      0,
    );
  await expect(
    page.getByRole("textbox", { name: "Body", exact: true }),
  ).not.toHaveAttribute("contenteditable", "true");
  await page.getByRole("button", { name: "Close record", exact: true }).click();
  await probe("__test_run", {
    sql: "UPDATE catalog_properties SET immutable=0 WHERE tbl='widgets' AND col='body'",
  });
  await reviewButtons().first().click();
  console.log(
    "PASS: review refreshes catalog, preserves newly immutable values and excludes catalogued system fields",
  );
  await expect(
    page.getByRole("status", { name: "Draft review", exact: true }),
  ).toContainText("Body autosave is paused");
  await expect(
    page.getByRole("textbox", { name: "Title", exact: true }),
  ).toHaveValue(String(localRow.title));
  await page.getByRole("button", { name: "Body source", exact: true }).click();
  await expect(
    page.getByRole("textbox", { name: "Body", exact: true }),
  ).toHaveValue("Rejected body");
  await page.waitForTimeout(1000); // Longer than body autosave debounce; no review write is allowed.
  expect(
    (
      (await probe("__test_all", {
        sql: "SELECT body FROM widgets WHERE id=?",
        params: [first.row_id],
      })) as any[]
    )[0].body,
  ).toBe("Newer local body");
  await page.getByRole("button", { name: "Save record", exact: true }).click();
  await expect(
    page.getByRole("status", { name: "Draft review", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("textbox", { name: "Body", exact: true }),
  ).toHaveValue("Rejected body");
  await page
    .getByRole("textbox", { name: "Title", exact: true })
    .fill("Allowed");
  await page.getByRole("button", { name: "Save record", exact: true }).click();
  await expect(
    page.getByRole("status", { name: "Draft review", exact: true }),
  ).toHaveCount(0);
  expect(
    (
      (await probe("__test_all", {
        sql: "SELECT body FROM widgets WHERE id=?",
        params: [first.row_id],
      })) as any[]
    )[0].body,
  ).toBe("Rejected body");
  await expect(summary()).toHaveText("205 rejected edits need attention");
  console.log(
    "PASS: review retains fresh revision, pauses autosave, keeps failed drafts and uses normal explicit Save",
  );
  await page.getByRole("button", { name: "Close record", exact: true }).click();
  const second = stored[1];
  const otherRow = (
    (await probe("rows", {
      view: {
        table: "widgets",
        filters: [{ column: "id", op: "eq", value: second.row_id }],
        limit: 1,
      },
    })) as any[]
  )[0];
  await probe("write", {
    table: "widgets",
    patch: {
      id: second.row_id,
      title: "Allowed",
      body: "Newer tombstone body",
      deleted_at: true,
    },
    expectedUpdatedAt: otherRow.updated_at,
  });
  await page
    .locator(".rejections article")
    .filter({ hasText: second.row_id })
    .getByRole("button", { name: "Review rejected edit", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Save record", exact: true }),
  ).toBeDisabled();
  await expect(
    page.getByRole("textbox", { name: "Title", exact: true }),
  ).toHaveValue(String(otherRow.title));
  await page
    .getByRole("button", { name: "Restore record", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Save record", exact: true }),
  ).toBeEnabled();
  await expect(
    page.getByRole("textbox", { name: "Title", exact: true }),
  ).toHaveValue(String(otherRow.title));
  await expect(
    page.getByRole("status", { name: "Draft review", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Close record", exact: true }).click();
  console.log(
    "PASS: tombstone review is read-only and Restore preserves the rejected draft",
  );
  await connect();
  await expect(summary()).toHaveText("203 rejected edits need attention");
  console.log(
    "PASS: saved corrections remain rejected until accepted sync receipts",
  );
  await page.evaluate(() => (window as any).rejectionProbe.close());
  await leave();
  await page.reload();
  await page
    .getByRole("button", { name: "Open my workspace", exact: true })
    .click();
  await expect(summary()).toHaveText("203 rejected edits need attention");
  await summary().click();
  await expect(reviewButtons()).toHaveCount(100);
  await expect(page.getByLabel("Device token")).toHaveValue("");
  console.log(
    "PASS: offline reopen retains durable count and first page without credentials",
  );
  await page.evaluate(() => {
    (window as any).hold = "rejections";
  });
  await page
    .getByRole("button", { name: "Load more rejected edits", exact: true })
    .click();
  await expect
    .poll(() => page.evaluate(() => (window as any).held.length))
    .toBe(1);
  await leave();
  await page
    .getByRole("button", { name: "Try sample workspace", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "notes", exact: true }),
  ).toBeVisible();
  await page.evaluate(() => (window as any).release());
  await expect(summary()).toHaveCount(0);
  console.log(
    "PASS: a delayed rejection page cannot publish into a different workspace",
  );
} catch (error) {
  console.error("UI:", await page.locator("body").innerText());
  throw error;
} finally {
  await page
    .evaluate(() => (window as any).rejectionProbe?.close())
    .catch(() => {});
  await leave().catch(() => {});
  await expect
    .poll(() => page.evaluate(() => (window as any).activeWorkers?.size ?? 0))
    .toBe(0);
  await page.context().unrouteAll({ behavior: "wait" });
  fixture.server.stop(true);
  fixture.db.db.close();
  fixture.auth.db.close();
  await browser.close();
}
