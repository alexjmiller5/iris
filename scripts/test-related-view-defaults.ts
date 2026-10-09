import { expect } from "@playwright/test";
import { regressionHub } from "./workspace-regression-hub";
import { disposableOrigin } from "./test-origin";
import {
  sourceNavigationCDP,
  element,
  named,
  js,
} from "./source-navigation-cdp";
const source = process.argv[2];
if (!source) throw Error("Provide matching soma source");
const url =
  process.env.IRIS_TEST_URL ??
  "http://iris-navigation.localhost:5274/workspace?review";
const origin = disposableOrigin(url);
expect(await Bun.file(`${source}/core/contract/core.json`).text()).toBe(
  await Bun.file(
    new URL("../packages/core/contract/core.json", import.meta.url),
  ).text(),
);
const { server, db, auth } = await regressionHub(source, origin);
let page: Awaited<ReturnType<typeof sourceNavigationCDP>> | undefined;
try {
  for (const ddl of [
    "ALTER TABLE catalog_properties ADD COLUMN source TEXT",
    "ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT",
  ]) {
    db.db.exec(ddl);
    db.db
      .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
      .run("2026-01-01T00:00:00.000Z", ddl);
  }
  for (const name of [
    "saved-views",
    "view-defaults",
    "related-view-defaults",
  ]) {
    const storage = await Bun.file(`${source}/core/schema/${name}.json`).json();
    for (const ddl of storage.ddl) {
      db.db.exec(ddl);
      db.db
        .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
        .run("2026-01-01T00:00:00.000Z", ddl);
    }
    for (const [table, rows] of [
      ["catalog_tables", [storage.table]],
      ["catalog_properties", storage.properties],
    ] as const)
      for (const row of rows) {
        const keys = Object.keys(row);
        db.db
          .query(
            `INSERT INTO ${table}(${keys.join(",")}) VALUES (${keys.map(() => "?").join(",")})`,
          )
          .run(...Object.values(row));
      }
  }
  db.db.query("INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)").run(
    "preferred-opaque",
    "Z chosen",
    "widgets",
    JSON.stringify({
      version: 1,
      filters: [{ column: "id", op: "eq", value: "fixture-record" }],
    }),
  );
  db.db
    .query("INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)")
    .run("other-opaque", "A all", "widgets", JSON.stringify({ version: 1 }));
  const ddl = "ALTER TABLE widgets ADD COLUMN parent TEXT";
  db.db.exec(ddl);
  db.db
    .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
    .run("2026-01-01T00:00:00.000Z", ddl);
  db.db.exec(
    "INSERT INTO catalog_properties(id,tbl,col,label,sort,type,ref_table) VALUES ('widgets.parent','widgets','parent','Parent',5,'ref','widgets'); UPDATE widgets SET parent='second-record' WHERE id IN ('fixture-record','legacy-record');",
  );
  db.db.query("INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)").run(
    "linked-opaque",
    "Linked fixture",
    "widgets",
    JSON.stringify({
      version: 1,
      columns: ["title"],
      filters: [{ column: "id", op: "ne", value: "legacy-record" }],
    }),
  );
  page = await sourceNavigationCDP(url);
  const cdp = page;
  let unexpectedDialogs = 0;
  cdp.on("Page.javascriptDialogOpening", (dialog) => {
    unexpectedDialogs++;
    console.error("Synthetic dialog", JSON.stringify(dialog));
    void cdp.command("Page.handleJavaScriptDialog", { accept: false });
  });
  const button = (name: string) => named("button", name);
  const click = async (name: string) => {
    await cdp.until(`!!(${button(name)})&&!(${button(name)}).disabled`);
    await cdp.click(button(name));
  };
  const select = element('select[aria-label="View"]');
  const choose = async (id: string) => {
    await cdp.until(
      `!!(${select})&&!(${select}).disabled && [...(${select}).options].some(o=>o.value===${js(id)})`,
    );
    await cdp.evaluate(
      `(()=>{const e=${select};e.value=${js(id)};e.dispatchEvent(new Event('change',{bubbles:true}));})()`,
    );
  };
  const waitSelected = (id: string) =>
    cdp.until(`(${select})?.value===${js(id)}`);
  await cdp.navigate(new URL("/", url).href);
  await cdp.command("Storage.clearDataForOrigin", {
    origin,
    storageTypes: "all",
  });
  await cdp.navigate(url);
  await click("Open my workspace");
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
  await cdp.until(
    `!!(${button("New record")})&&!(${button("New record")}).disabled`,
  );
  const table = (id: string) =>
    named("button", id, element('nav[aria-label="Tables"]'));
  const openTable = async (id: string) => {
    await cdp.click(table(id));
    await cdp.until(`!!(${named("h1", id)})`);
  };
  await openTable("widgets");
  await choose("preferred-opaque");
  await waitSelected("preferred-opaque");
  await click("Use current view by default");
  await cdp.until("document.body.innerText.includes('Default view saved.')");
  await choose("linked-opaque");
  await waitSelected("linked-opaque");
  await click("Use current view for related records");
  await cdp.until(
    "document.body.innerText.includes('Related-record view saved.')",
  );
  const relatedResync = await cdp.evaluate("new Date().toISOString()");
  await cdp.until(
    `(document.querySelector('[data-last-sync]')?.getAttribute('data-last-sync') ?? '') > ${js(relatedResync)}`,
  );
  await expect
    .poll(
      () =>
        db.db
          .query(
            "SELECT view_id FROM related_view_defaults WHERE tbl='widgets' AND deleted_at IS NULL",
          )
          .get()?.view_id,
    )
    .toBe("linked-opaque");
  expect(
    db.db
      .query(
        "SELECT view_id FROM view_defaults WHERE tbl='widgets' AND deleted_at IS NULL",
      )
      .get()?.view_id,
  ).toBe("preferred-opaque");
  await cdp.navigate(
    new URL("/workspace?table=widgets&row=second-record", url).href,
  );
  await click("Open my workspace");
  const group = element('details[aria-label="widgets / Parent"]');
  await cdp.until(`!!(${group})`);
  await cdp.click(named("summary", "widgets / Parent"));
  await cdp.until(`(${group})?.innerText.includes('Fixture record')`);
  expect(
    await cdp.evaluate(`(${group}).innerText.includes('Legacy record')`),
  ).toBe(false);
  await cdp.click(named("button", "Open Fixture record", group));
  await cdp.until("document.body.innerText.includes('Original body')");
  await cdp.until(
    "document.querySelector('fieldset.workspace-controls')?.disabled===false",
  );
  await cdp.navigate(new URL("/workspace?table=widgets", url).href);
  await click("Open my workspace");
  await waitSelected("preferred-opaque");
  await cdp.until(
    '!!document.querySelector(\'[aria-label="Records"] [data-row="fixture-record"]\')',
  );
  expect(
    await cdp.evaluate(
      "[...new Set(Array.from(document.querySelectorAll('[aria-label=\"Records\"] [data-row]'),e=>e.getAttribute('data-row')))]",
    ),
  ).toEqual(["fixture-record"]);
  expect(unexpectedDialogs).toBe(0);
  console.log(
    "PASS independent related preference, real Worker sync readback, filtered incoming links, full-record opening, table default and OPFS reopen.",
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
