import { mkdirSync } from "node:fs";
import { expect } from "@playwright/test";
import { regressionHub } from "./workspace-regression-hub";
import { disposableOrigin } from "./test-origin";
import {
  sourceNavigationCDP,
  element,
  named,
} from "./source-navigation-cdp";

// Synthetic lifecycle workspace: a default view, a separate related-record view,
// a Boolean flag whose description names its reason column, and status-labeled
// search. Nothing here is a product schema; the catalog drives every behavior.
const source = process.argv[2];
if (!source) throw Error("Provide matching soma source");
const url =
  process.env.IRIS_TEST_URL ??
  "http://iris-relations.localhost:5311/workspace?review";
const shots = process.env.IRIS_TEST_SHOTS;
if (shots) mkdirSync(shots, { recursive: true });
const origin = disposableOrigin(url);
const { server, db, auth } = await regressionHub(source, origin);
const log = (ddl: string) => {
  db.db.exec(ddl);
  db.db
    .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
    .run("2026-01-01T00:00:00.000Z", ddl);
};
const insert = (table: string, row: Record<string, unknown>) => {
  const keys = Object.keys(row);
  db.db
    .query(
      `INSERT INTO ${table}(${keys.join(",")}) VALUES (${keys.map(() => "?").join(",")})`,
    )
    .run(
      ...Object.values(row).map((v) =>
        v !== null && typeof v === "object" ? JSON.stringify(v) : v,
      ) as any[],
    );
};
const hex = (s: string) => Buffer.from(s).toString("hex");
let page: Awaited<ReturnType<typeof sourceNavigationCDP>> | undefined;
try {
  log("ALTER TABLE catalog_properties ADD COLUMN source TEXT");
  log("ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT");
  for (const name of ["saved-views", "view-defaults", "related-view-defaults"]) {
    const storage = await Bun.file(`${source}/core/schema/${name}.json`).json();
    for (const ddl of storage.ddl) log(ddl);
    insert("catalog_tables", storage.table);
    for (const row of storage.properties) insert("catalog_properties", row);
  }
  const system =
    "id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),deleted_at TEXT,hub_at TEXT";
  log(`CREATE TABLE "trips" (${system},title TEXT)`);
  log(
    `CREATE TABLE "notes" (${system},title TEXT,kind TEXT,status TEXT,needs_review INTEGER NOT NULL DEFAULT 0,review_reason TEXT,trip_ids TEXT)`,
  );
  insert("catalog_tables", { id: "trips", kind: "table", display: "title" });
  insert("catalog_tables", { id: "notes", kind: "table", display: "title" });
  const status = [
    ["Working", "Actively being developed."],
    ["Reference", "Kept to consult or reuse."],
    ["Someday", "Deferred; not a commitment."],
    ["History", "A record of something finished."],
    ["Retired", "Superseded and no longer in use."],
  ].map(([v, d], sort) => ({ v, d, sort }));
  for (const [col, props] of Object.entries({
    title: { type: "text", required: 1, label: "Title" },
    kind: { type: "select", label: "Kind", options: [{ v: "Note" }] },
    status: { type: "select", label: "Status", options: status },
    needs_review: {
      type: "bool",
      label: "Needs review",
      default_value: "0",
      description: "Cleanup flag; the reason is in review_reason.",
    },
    review_reason: { type: "text", label: "Review reason" },
    trip_ids: { type: "multi_ref", label: "Trips", ref_table: "trips" },
  }))
    insert("catalog_properties", { id: `notes.${col}`, tbl: "notes", col, ...props });
  insert("catalog_properties", {
    id: "trips.title",
    tbl: "trips",
    col: "title",
    type: "text",
    required: 1,
    label: "Title",
  });
  insert("trips", { id: "trip-1", title: "Synthetic trip" });
  for (const [id, title, state, extra] of [
    ["n-working", "Working draft", "Working", { trip_ids: ["trip-1"] }],
    [
      "n-reference",
      "Reference sheet",
      "Reference",
      { needs_review: 1, review_reason: "Duplicates the packing list" },
    ],
    ["n-someday", "Someday idea", "Someday", {}],
    ["n-history", "History log", "History", { trip_ids: ["trip-1"] }],
    ["n-retired", "Retired lantern plan", "Retired", { trip_ids: ["trip-1"] }],
  ] as const)
    insert("notes", { id, title, kind: "Note", status: state, ...extra });
  const eq = (column: string, value: string) => ({ column, op: "eq", value });
  const columns = ["title", "status"];
  insert("views", {
    id: "everyday",
    name: "Everyday",
    tbl: "notes",
    definition: {
      version: 2,
      columns,
      filters: [eq("kind", "Note")],
      groups: [{ match: "any", filters: [eq("status", "Working"), eq("status", "Reference")] }],
    },
  });
  insert("views", {
    id: "someday",
    name: "Someday",
    tbl: "notes",
    definition: { version: 1, columns, filters: [eq("status", "Someday")] },
  });
  insert("views", {
    id: "linked",
    name: "Linked",
    tbl: "notes",
    definition: {
      version: 1,
      columns,
      filters: [{ column: "status", op: "ne", value: "Retired" }],
    },
  });
  insert("view_defaults", { id: `default:v1:${hex("notes")}`, tbl: "notes", view_id: "everyday" });
  insert("related_view_defaults", {
    id: `related:v1:${hex("notes")}`,
    tbl: "notes",
    view_id: "linked",
  });

  page = await sourceNavigationCDP(url);
  const cdp = page;
  const shot = async (name: string) => {
    if (!shots) return;
    const { data } = await cdp.command("Page.captureScreenshot", { format: "png" });
    await Bun.write(`${shots}/${name}.png`, Buffer.from(data, "base64"));
  };
  const button = (name: string) => named("button", name);
  const click = async (name: string) => cdp.click(button(name));
  const rows = () =>
    cdp.evaluate(
      "[...new Set(Array.from(document.querySelectorAll('[aria-label=\"Records\"] [data-row]'),e=>e.getAttribute('data-row')))].sort()",
    );
  const showsRows = (ids: string[]) =>
    expect.poll(rows, { timeout: 10000 }).toEqual([...ids].sort());
  const select = element('select[aria-label="View"]');
  const tables = element('nav[aria-label="Tables"]');
  // A click before hydration does nothing; retry until the workspace shell is up.
  const enter = () =>
    expect
      .poll(
        async () =>
          (await cdp.evaluate(`!!(${tables})`)) ||
          (await cdp.click(button("Open my workspace")).then(
            () => false,
            () => false,
          )),
        { timeout: 30000 },
      )
      .toBe(true);
  const open = async (path: string) => {
    await cdp.navigate(new URL(path, url).href);
    await enter();
  };
  await cdp.navigate(new URL("/", url).href);
  await cdp.command("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.navigate(url);
  await enter();
  for (const label of ["Connect to a hub", "Use a device token"]) {
    const control = named("button,summary", label);
    await cdp.until(`!!(${control})`);
    if (!(await cdp.evaluate(`(${control}).closest('details').open`)))
      await cdp.click(control);
  }
  const input = (label: string) =>
    `(()=>{const e=${named("label", label)};return e?.control??e?.querySelector('input');})()`;
  await cdp.fill(input("Hub address"), server.url.href.replace(/\/$/, ""));
  await cdp.fill(input("Device token"), "fixture");
  await click("Connect");
  await cdp.until(`!!(${named("button", "notes", tables)})`);

  // 1. Plain table navigation opens the preferred everyday view.
  await cdp.click(named("button", "notes", tables));
  await cdp.until(`(${select})?.value==='everyday'`);
  await showsRows(["n-reference", "n-working"]);
  await shot("1-default-everyday");

  // 2. Someday is its own view.
  await cdp.evaluate(
    `(()=>{const e=${select};e.value='someday';e.dispatchEvent(new Event('change',{bubbles:true}));})()`,
  );
  await cdp.until(`(${select})?.value==='someday'`);
  await showsRows(["n-someday"]);
  await shot("2-someday");

  // 3. A linked record shows History through the related view, never Retired.
  await open("/workspace?table=trips&row=trip-1");
  const group = element('details[aria-label="notes / Trips"]');
  await cdp.until(`!!(${group})`);
  await cdp.click(named("summary", "notes / Trips"));
  await cdp.until(`(${group})?.innerText.includes('History log')`);
  expect(await cdp.evaluate(`(${group}).innerText.includes('Working draft')`)).toBe(true);
  expect(await cdp.evaluate(`(${group}).innerText.includes('Retired lantern plan')`)).toBe(false);
  await shot("3-related-history-not-retired");

  // 4. The flag's quick filter narrows any view and shows its reason inline.
  await open("/workspace?table=notes");
  await cdp.until(`(${select})?.value==='everyday'`);
  await showsRows(["n-reference", "n-working"]);
  const flagChip = named("button", "Needs review", element(".chips"));
  await cdp.click(flagChip);
  await showsRows(["n-reference"]);
  await cdp.until(
    `!!document.querySelector('[aria-label="Records"] [data-row="n-reference"][data-column="review_reason"]')?.textContent.includes('Duplicates the packing list')`,
  );
  // The bar's own removable chip replaces the quick filter while it is on.
  expect(await cdp.evaluate(`!!(${flagChip})`)).toBe(false);
  await shot("4-needs-review-reason");

  // 5. Search still finds Retired records and labels them from the catalog.
  await cdp.click(
    `[...document.querySelectorAll('button')].find(b=>b.textContent.trim().startsWith('Find records'))`,
  );
  await cdp.fill(element('input[aria-label="Search records"]'), "lantern");
  const badge = element('[aria-label="Search results"] .lifecycle');
  await cdp.until(`(${badge})?.textContent==='Retired'`);
  expect(await cdp.evaluate(`(${badge}).title`)).toBe("Superseded and no longer in use.");
  await shot("5-search-retired-label");
  console.log(
    "PASS everyday default, Someday view, related view keeps History and hides Retired, flag quick filter with inline reason, Retired search label.",
  );
} catch (error) {
  if (page) console.error(await page.evaluate("document.body.innerText"));
  throw error;
} finally {
  if (page) {
    await page.navigate(new URL("/", url).href).catch(() => {});
    await page
      .command("Storage.clearDataForOrigin", { origin, storageTypes: "all" })
      .catch(() => {});
    page.close();
  }
  server.stop(true);
  db.db.close();
  auth.db.close();
}
