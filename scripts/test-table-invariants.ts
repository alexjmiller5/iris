import { expect } from "@playwright/test";
import { regressionHub } from "./workspace-regression-hub";
import { disposableOrigin } from "./test-origin";
import {
  sourceNavigationCDP,
  element,
  named,
  js,
} from "./source-navigation-cdp";

// Actual Worker/OPFS acceptance. Requires an explicitly leased synthetic target.
// Mutants: generic rule text, discarded failed draft, editable derived/immutable
// controls, missing catalog descriptions, or an accepted invariant violation.
const source = process.argv[2];
if (!source) throw Error("Provide the soma checkout");
const url =
  process.env.IRIS_TEST_URL ??
  "http://iris-markdown.localhost:5198/workspace?review";
const origin = disposableOrigin(url);
if (!process.env.IRIS_TEST_TARGET)
  throw Error("Provide the owned IRIS_TEST_TARGET");
let failPull = false;
const { server, db, auth } = await regressionHub(source, origin, 0, {
  wrap: (worker) => ({
    async fetch(request: Request, env: unknown, context: unknown) {
      if (failPull && new URL(request.url).pathname === "/v1/rows/pull")
        return new Response("Fixture offline", {
          status: 503,
          headers: { "Access-Control-Allow-Origin": origin },
        });
      return worker.fetch(request, env, context);
    },
  }),
});
let page: Awaited<ReturnType<typeof sourceNavigationCDP>> | undefined;
try {
  db.db
    .query(
      "INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)",
    )
    .run(
      "quantity-positive",
      "widgets",
      "invariant",
      1,
      "SELECT id FROM changed WHERE quantity < 0",
      "Quantity cannot be negative.",
    );
  db.db.exec(
    "INSERT INTO catalog_tables(id,kind,display) VALUES ('history','system','col')",
  );
  for (const ddl of [
    "CREATE TABLE provenance(id TEXT PRIMARY KEY,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT,detail TEXT)",
    "ALTER TABLE widgets ADD COLUMN detail TEXT",
    "ALTER TABLE widgets ADD COLUMN locked TEXT",
    "ALTER TABLE widgets ADD COLUMN computed TEXT",
  ]) {
    db.db.exec(ddl);
    db.db
      .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
      .run("2026-01-01T00:00:00.000Z", ddl);
  }
  db.db.exec(
    "INSERT INTO catalog_tables(id,kind,display) VALUES ('provenance','system','detail')",
  );
  db.db
    .exec(`UPDATE catalog_properties SET description='Short fixture title.' WHERE id='widgets.title';
    UPDATE catalog_properties SET options='[{"v":"Dynamic","d":"Ready for review."}]',description='Choose a fixture state.' WHERE id='widgets.status';
    INSERT INTO catalog_properties(id,tbl,col,label,type,description,immutable,derived_by) VALUES
      ('widgets.detail','widgets','detail','Detail','text','A second independent edit.',0,NULL),
      ('widgets.locked','widgets','locked','Locked','text','Set once by the creator.',1,NULL),
      ('widgets.computed','widgets','computed','Computed','text','Filled by the fixture derivation.',0,'fixture-derivation');
    UPDATE widgets SET detail='Original detail',locked='Immutable fixture value',computed='Derived fixture value' WHERE id='fixture-record';`);

  page = await sourceNavigationCDP(url);
  const cdp = page;
  cdp.on("Page.javascriptDialogOpening", () => {
    void cdp.command("Page.handleJavaScriptDialog", { accept: true });
  });
  await cdp.command("Emulation.setDeviceMetricsOverride", {
    width: 1440,
    height: 1000,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await cdp.navigate(new URL("/", url).href);
  await cdp.command("Storage.clearDataForOrigin", {
    origin,
    storageTypes: "all",
  });
  const script = await cdp.command("Page.addScriptToEvaluateOnNewDocument", {
    source: `
    window.holdPermissionTable='';window.heldPermissions=[];
    window.releasePermissions=()=>{window.holdPermissionTable='';window.heldPermissions.splice(0).forEach(deliver=>deliver());};
    const Original=window.Worker;
    window.Worker=class extends Original {
      tables=new Map();
      postMessage(message,...args){if(message.method==='writeability')this.tables.set(message.id,message.args.table);return super.postMessage(message,...args);}
      set onmessage(handler){super.onmessage=event=>{const table=this.tables.get(event.data.id);this.tables.delete(event.data.id);const deliver=()=>handler.call(this,event);if(table&&table===window.holdPermissionTable)window.heldPermissions.push(deliver);else deliver();};}
    };`,
  });
  try {
    await cdp.navigate(url);
    const button = (name: string) => named("button", name);
    const text = (name: string) => named("button,summary", name);
    const field = (column: string) => element("#field-" + column);
    const click = (name: string) => cdp.click(button(name));
    const value = (column: string, expected: string) =>
      cdp.until(`(${field(column)})?.value===${js(expected)}`);
    const connect = async () => {
      for (const name of ["Connect to a hub", "Use a device token"]) {
        await cdp.until(`!!(${text(name)})`);
        if (!(await cdp.evaluate(`(${text(name)}).closest('details').open`)))
          await cdp.click(text(name));
      }
      const input = (label: string) =>
        `(()=>{const label=${named("label", label)};return label?.control??label?.querySelector('input');})()`;
      await cdp.fill(input("Hub address"), server.url.href.replace(/\/$/, ""));
      await cdp.fill(input("Device token"), "fixture");
    };
    const open = async () => {
      await click("Open my workspace");
      await connect();
    };
    const sync = async () => {
      await click("Connect");
      await expect
        .poll(
          () =>
            cdp.evaluate(
              `!!(${button("Connect")}) && !(${button("Connect")}).disabled`,
            ),
          { timeout: 30000 },
        )
        .toBe(true);
    };
    const enabled = (name: string, yes: boolean) =>
      cdp.until(`!!(${button(name)}) && (${button(name)}).disabled===${!yes}`);
    const bodyHas = (text: string) =>
      cdp.until(`document.body.innerText.includes(${js(text)})`);
    // Read the actual local replica through its existing request API, never a mock receipt.
    const local = (method: string, args?: unknown) =>
      cdp.evaluate(`(async()=>{
      const {WorkspaceDatabase}=await import('/src/lib/database.ts');const database=new WorkspaceDatabase();
      try{await database.request('open');return await database.request(${js(method)},${js(args ?? {})});}finally{database.close();}
    })()`);
    const stored = async () => {
      const rows = await local("rows", {
        view: {
          table: "widgets",
          filters: [{ column: "id", op: "eq", value: "fixture-record" }],
        },
      });
      return rows[0];
    };
    await open();
    await sync();
    await enabled("New record", true);
    await click("Fixture record");
    await value("quantity", "42");
    await cdp.until(
      `document.querySelector('label[for="field-title"] .required')?.textContent==='Required'`,
    );
    await cdp.until(
      `(${field("title")})?.closest('.field').innerText.includes('Short fixture title.')`,
    );
    await cdp.until(
      `Array.from((${field("status")})?.options??[]).some(o=>o.textContent.includes('Ready for review.'))`,
    );
    for (const [col, expected, description] of [
      ["locked", "Immutable fixture value", "Set once"],
      ["computed", "Derived fixture value", "Filled automatically"],
    ]) {
      await value(col, expected);
      await cdp.until(
        `(${field(col)}).disabled && (${field(col)}).closest('.field').innerText.includes(${js(description)})`,
      );
    }
    const before = await stored();
    const pending = (await local("snapshot")).status.pendingUiEdits;
    const history = db.db
      .query("SELECT * FROM history WHERE row_id='fixture-record' ORDER BY id")
      .all();
    await cdp.fill(field("quantity"), "-1");
    await cdp.fill(field("detail"), "Retained second edit");
    await click("Save record");
    await cdp.until(
      `Array.from(document.querySelectorAll('.failure')).some(e=>e.innerText.includes('Quantity cannot be negative.'))`,
    );
    await value("quantity", "-1");
    await value("detail", "Retained second edit");
    await enabled("Save record", true);
    expect(await stored()).toEqual(before);
    expect((await local("snapshot")).status.pendingUiEdits).toBe(pending);
    expect(
      db.db
        .query(
          "SELECT * FROM history WHERE row_id='fixture-record' ORDER BY id",
        )
        .all(),
    ).toEqual(history);
    await click("Close record");
    await click("Fixture record");
    await value("quantity", "42");
    await value("detail", "Original detail");
    await cdp.fill(field("quantity"), "43");
    await cdp.fill(field("detail"), "Retained second edit");
    await click("Save record");
    await cdp.until(`!!document.querySelector('[data-pending="1"]')`);
    await click("Close record");
    await click("Fixture record");
    await value("quantity", "43");
    await value("detail", "Retained second edit");
    await value("locked", "Immutable fixture value");
    await value("computed", "Derived fixture value");
    await click("Close record");
    await sync();
    expect(
      db.db
        .query(
          "SELECT quantity,detail,locked,computed FROM widgets WHERE id='fixture-record'",
        )
        .get(),
    ).toEqual({
      quantity: 43,
      detail: "Retained second edit",
      locked: "Immutable fixture value",
      computed: "Derived fixture value",
    });
    expect(
      db.db
        .query(
          "SELECT col,old,new FROM history WHERE row_id='fixture-record' ORDER BY col",
        )
        .all(),
    ).toEqual([
      { col: "detail", old: "Original detail", new: "Retained second edit" },
      { col: "quantity", old: "42", new: "43" },
    ]);
    console.log(
      "PASS: real catalog errors retain drafts; helpers/read-only metadata and corrected readback agree",
    );

    // Preserve the existing incomplete-replica, dependency and stale advisory regressions.
    await click("Switch workspace");
    await cdp.evaluate(
      `localStorage.setItem('iris:replica',JSON.stringify({maxRows:50000,tables:{history:false,provenance:false}}))`,
    );
    await open();
    await sync();
    await enabled("New record", true);
    await click("Fixture record");
    await cdp.fill(field("quantity"), "44");
    await click("Save record");
    await cdp.until(`!!document.querySelector('[data-pending="1"]')`);
    await click("Close record");
    await sync();
    expect(
      db.db
        .query("SELECT quantity FROM widgets WHERE id='fixture-record'")
        .get(),
    ).toEqual({ quantity: 44 });
    console.log(
      "PASS: self-contained rules allow writes while unrelated tables stay skipped",
    );

    db.db
      .query(
        "UPDATE catalog_rules SET sql=?,updated_at=?,hub_at=NULL WHERE id=?",
      )
      .run(
        "SELECT id FROM changed WHERE quantity < (SELECT count(*) FROM history)",
        new Date().toISOString(),
        "quantity-positive",
      );
    await sync();
    await enabled("New record", false);
    await bodyHas("history");
    await click("Fixture record");
    await cdp.until(`(${field("quantity")})?.disabled===true`);
    await click("Close record");
    await click("Switch workspace");
    await cdp.evaluate(
      `localStorage.setItem('iris:replica',JSON.stringify({maxRows:50000,tables:{provenance:false}}))`,
    );
    await open();
    await sync();
    await enabled("New record", true);
    console.log("PASS: a real rule dependency requires backfill");

    // Completed coverage remains valid when an incremental pull fails before
    // changing schema or metadata. A transport failure alone is not revocation.
    const certified = await stored();
    failPull = true;
    await sync();
    await bodyHas("hub HTTP 503");
    await enabled("New record", true);
    expect(await stored()).toEqual(certified);
    await cdp.navigate(url);
    await click("Open my workspace");
    await enabled("New record", true);
    await click("Fixture record");
    await value("quantity", "44");
    await cdp.fill(field("detail"), "Saved after interrupted refresh");
    await click("Save record");
    await cdp.until(`!!document.querySelector('[data-pending="1"]')`);
    expect(await stored()).toMatchObject({
      quantity: 44,
      detail: "Saved after interrupted refresh",
    });
    await click("Close record");
    // Reload intentionally forgets session credentials. Prove the offline save
    // first, then reconnect through the supported controls for recovery sync.
    await connect();
    failPull = false;
    await sync();
    await enabled("New record", true);
    expect(
      db.db
        .query("SELECT quantity,detail FROM widgets WHERE id='fixture-record'")
        .get(),
    ).toEqual({ quantity: 44, detail: "Saved after interrupted refresh" });
    console.log(
      "PASS: unchanged incremental failure retains certified writes after reopen and recovery",
    );

    await cdp.evaluate(`window.holdPermissionTable='history'`);
    const table = (name: string, group = "Tables") =>
      named("button", name, element(`nav[aria-label="${group}"]`));
    await cdp.click(text("System tables"));
    await cdp.click(table("history", "System tables"));
    await cdp.until("window.heldPermissions.length>0");
    await cdp.click(table("widgets"));
    await enabled("New record", true);
    await cdp.evaluate("window.releasePermissions()");
    await enabled("New record", true);
    await click("New record");
    await cdp.until(`(${field("quantity")})?.disabled===false`);
    console.log(
      "PASS: a delayed read-only advisory cannot lock the current table",
    );

    await click("Close record");
    const ddl =
      "CREATE TRIGGER widgets_marker AFTER UPDATE ON widgets BEGIN SELECT 1; END";
    db.db.exec(ddl);
    db.db
      .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
      .run(new Date().toISOString(), ddl);
    await connect();
    await sync();
    await enabled("New record", false);
    await bodyHas("Unsupported trigger");
    await click("Fixture record");
    await value("quantity", "44");
    await cdp.until(`(${field("quantity")})?.disabled===true`);
    console.log(
      "PASS: unsupported effects stay read-only while records remain browsable",
    );
  } finally {
    await cdp.evaluate("window.releasePermissions?.()").catch(() => {});
    await cdp.command("Page.removeScriptToEvaluateOnNewDocument", {
      identifier: script.identifier,
    });
  }
} finally {
  if (page) {
    await page.navigate(new URL("/", url).href).catch(() => {});
    await page
      .command("Storage.clearDataForOrigin", { origin, storageTypes: "all" })
      .catch(() => {});
    await page.command("Emulation.clearDeviceMetricsOverride").catch(() => {});
    page.close();
  }
  server.stop(true);
  db.db.close();
  auth.db.close();
}
