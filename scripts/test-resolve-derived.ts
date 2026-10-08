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
if (!source) throw Error("Provide the life-data checkout");
const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-resolve.localhost:5252/workspace?review";
const origin = disposableOrigin(url);
let providerCalls = 0,
  providerFails = false;
const ordinaryFetch = globalThis.fetch;
globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
  if (String(input) === "https://derivation.invalid/fixture") {
    providerCalls++;
    if (providerFails)
      return new Response("Synthetic provider failure", { status: 503 });
    return Response.json({
      computed: "Resolved fixture value",
      _source_ref: "fixture:provider",
    });
  }
  return ordinaryFetch(input, init);
}) as typeof fetch;
const { server, db, auth } = await regressionHub(source, origin, 0, {
  env: {
    DERIVATIONS: JSON.stringify({
      fixture: { url: "https://derivation.invalid/fixture" },
    }),
  },
});
let page: Awaited<ReturnType<typeof sourceNavigationCDP>> | undefined;
try {
  for (const ddl of [
    "ALTER TABLE widgets ADD COLUMN computed TEXT",
    "CREATE TABLE provenance(id TEXT PRIMARY KEY,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT,from_kind TEXT,from_ref TEXT,to_kind TEXT,to_ref TEXT,rel TEXT,field TEXT,detail TEXT,asserted_by TEXT,inputs_hash TEXT,value_hash TEXT,produced_at TEXT)",
  ]) {
    db.db.exec(ddl);
    db.db
      .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
      .run("2026-01-01T00:00:00.000Z", ddl);
  }
  db.db
    .exec(`INSERT INTO catalog_tables(id,kind,display) VALUES ('provenance','system','field');
    INSERT INTO catalog_properties(id,tbl,col,label,sort,type,derived_by,inputs) VALUES
    ('widgets.computed','widgets','computed','Computed',9,'text','http:fixture','["title"]');
    UPDATE widgets SET computed='Old fixture value' WHERE id='fixture-record';`);
  page = await sourceNavigationCDP(url);
  const cdp = page;
  const button = (name: string) => named("button", name);
  const click = (name: string) => cdp.click(button(name));
  const field = (column: string) => element("#field-" + column);
  const value = (column: string, expected: string) =>
    cdp.until(`(${field(column)})?.value===${js(expected)}`);
  const bodyHas = (text: string) =>
    cdp.until(`document.body.innerText.includes(${js(text)})`);
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
    `!!(${button("New record")}) && !(${button("New record")}).disabled`,
  );
  await click("Fixture record");
  await value("computed", "Old fixture value");
  await cdp.until(`(${field("computed")}).disabled`);
  const resolve = `document.querySelector('button[aria-label="Resolve Computed"]')`;
  // A dirty draft must never reach the provider, and must remain intact.
  await cdp.fill(field("title"), "Keep my unsaved title");
  await cdp.click(resolve);
  await bodyHas("Save or discard your changes before resolving.");
  await value("title", "Keep my unsaved title");
  expect(providerCalls).toBe(0);
  expect(
    db.db.query("SELECT title FROM widgets WHERE id='fixture-record'").get()
      .title,
  ).toBe("Fixture record");
  await cdp.fill(field("title"), "Fixture record");
  await cdp.click(resolve);
  await bodyHas("Resolved and synced");
  await value("computed", "Resolved fixture value");
  expect(providerCalls).toBe(1);
  expect(
    db.db.query("SELECT computed FROM widgets WHERE id='fixture-record'").get()
      .computed,
  ).toBe("Resolved fixture value");
  expect(
    db.db
      .query(
        "SELECT from_ref FROM provenance WHERE to_ref='fixture-record' AND field='computed'",
      )
      .get().from_ref,
  ).toBe("fixture:provider");
  // The field remains read-only; provider failure never claims a successful resolve.
  providerFails = true;
  await cdp.click(resolve);
  await bodyHas("Some derived values could not be resolved.");
  await bodyHas("503");
  await value("computed", "Resolved fixture value");
  expect(providerCalls).toBe(2);
  await cdp.until(`(${field("computed")}).disabled`);
  // An externally changed hub revision must fail before another provider call.
  db.db.exec(
    "UPDATE widgets SET updated_at='2099-01-01T00:00:00.000Z' WHERE id='fixture-record'",
  );
  await cdp.click(resolve);
  await bodyHas("sync and reopen it before resolving");
  expect(providerCalls).toBe(2);
  if (process.env.LIFE_UI_TEST_SCREENSHOT) {
    const shot = await cdp.command("Page.captureScreenshot", { format: "png" });
    await Bun.write(
      process.env.LIFE_UI_TEST_SCREENSHOT,
      Buffer.from(shot.data, "base64"),
    );
  }
  console.log(
    "PASS actual Worker/OPFS Resolve: draft guard, provider write/provenance, sync readback, read-only display, failure and stale revision.",
  );
} catch (failure) {
  if (page) console.error(await page.evaluate("document.body.innerText"));
  throw failure;
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
  globalThis.fetch = ordinaryFetch;
}
