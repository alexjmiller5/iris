import { expect } from "@playwright/test";
import {
  sourceNavigationCDP,
  element,
  named,
  js,
} from "./source-navigation-cdp";
import { regressionHub } from "./workspace-regression-hub";
import { disposableOrigin } from "./test-origin";

const url =
  process.env.IRIS_TEST_URL ??
  "http://iris-navigation.localhost:5269/workspace?review";
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source)
  throw Error(
    "Usage: bun scripts/test-source-navigation.ts <soma-checkout>",
  );
const { server, db, auth } = await regressionHub(source, origin);
const sourceID = "11111111222233334444555555555555";
const sourceURL = `https://app.notion.com/p/Related-${sourceID}`;
const body = `# Source document\n\n[Related record](${sourceURL})\n\n[Unmapped record](https://app.notion.com/p/Absent-aaaaaaaa222233334444555555555555)\n`;
for (const ddl of [
  "ALTER TABLE widgets ADD COLUMN parent TEXT",
  "ALTER TABLE widgets ADD COLUMN output TEXT",
  "CREATE TABLE provenance (id TEXT PRIMARY KEY,from_kind TEXT,from_ref TEXT,to_kind TEXT,to_ref TEXT,rel TEXT,field TEXT,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT)",
]) {
  db.db.exec(ddl);
  db.db
    .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
    .run("2026-01-01T00:00:00.000Z", ddl);
}
db.db
  .query("UPDATE widgets SET body=?,parent=? WHERE id=?")
  .run(body, "legacy-record", "fixture-record");
db.db
  .query("INSERT INTO catalog_tables(id,kind,display) VALUES (?,?,?)")
  .run("provenance", "system", "id");
db.db
  .query(
    "INSERT INTO catalog_properties(id,tbl,col,label,sort,type,ref_table) VALUES (?,?,?,?,?,?,?)",
  )
  .run("widgets.parent", "widgets", "parent", "Parent", 5, "ref", "widgets");
db.db
  .query(
    "INSERT INTO provenance(id,from_kind,from_ref,to_kind,to_ref,rel,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
  )
  .run(
    "fixture-source",
    "notion",
    sourceID,
    "widgets",
    "second-record",
    "imported_from",
    "2026-01-01T00:00:00.000Z",
    "2026-01-01T00:00:00.000Z",
  );

db.db
  .query(
    "INSERT INTO catalog_properties(id,tbl,col,label,sort,type) VALUES (?,?,?,?,?,?)",
  )
  .run("widgets.output", "widgets", "output", "Output", 6, "text");
db.db
  .query("UPDATE widgets SET output=? WHERE id=?")
  .run("widgets/second-record", "fixture-record");

function installWorkerBarrier() {
  const state = window as any;
  state.sourceNavigation = {
    holdSource: false,
    holdRow: "",
    heldSource: [],
    heldRows: [],
    writes: 0,
    sourceDelivered: 0,
    sourceRequests: 0,
    rowRequests: [],
    inFlight: 0,
  };
  const fixture = state.sourceNavigation;
  fixture.releaseSource = (fail = false) => {
    fixture.holdSource = false;
    fixture.heldSource
      .splice(0)
      .forEach((deliver: (fail: boolean) => void) => deliver(fail));
  };
  fixture.releaseRows = () => {
    fixture.holdRow = "";
    fixture.heldRows.splice(0).forEach((deliver: () => void) => deliver());
  };
  const Original = window.Worker;
  window.Worker = class extends Original {
    requests = new Map<number, any>();
    postMessage(request: any, ...args: any[]) {
      this.requests.set(request.id, request);
      fixture.inFlight++;
      if (request.method === "write") fixture.writes++;
      if (request.method === "resolveSourceLink") fixture.sourceRequests++;
      if (request.method === "rows")
        fixture.rowRequests.push(request.args.view);
      return super.postMessage(request, ...(args as [any]));
    }
    set onmessage(handler: any) {
      super.onmessage = (event) => {
        const request = this.requests.get(event.data.id);
        this.requests.delete(event.data.id);
        const deliver = (fail = false) => {
          if (request) fixture.inFlight--;
          if (request?.method === "resolveSourceLink")
            fixture.sourceDelivered++;
          handler.call(
            this,
            fail
              ? {
                  data: {
                    ...event.data,
                    error: { message: "Delayed source lookup failed" },
                  },
                }
              : event,
          );
        };
        if (request?.method === "resolveSourceLink" && fixture.holdSource)
          fixture.heldSource.push(deliver);
        else if (
          request?.method === "rows" &&
          fixture.holdRow &&
          request.args.view.filters?.some(
            (filter: any) =>
              filter.column === "id" && filter.value === fixture.holdRow,
          )
        )
          fixture.heldRows.push(deliver);
        else deliver();
      };
    }
  };
}
const cdp = await sourceNavigationCDP(url);
const { command, evaluate, until, click, key, fill, navigate } = cdp;
let acceptDiscard = true,
  dialogs = 0;
const failures: string[] = [];
cdp.on("Page.javascriptDialogOpening", () => {
  dialogs++;
  void command("Page.handleJavaScriptDialog", { accept: acceptDiscard });
});
const editor = element('[aria-label="Record editor"]');
const grid = element('[role="grid"][aria-label="Records"]');
const popup = element('[role="dialog"][aria-label="Open document link"]');
const fixture = "(window.sourceNavigation)";
const button = (name: string, root = "document") => named("button", name, root);
const link = (name: string, root = "document") => named("a", name, root);
const input = (name: string) => element(`input[aria-label="${name}"]`);
const heading = (name: string) => named("h2,h3", name, editor);
let initScript: string | undefined;
try {
  await command("Emulation.setDeviceMetricsOverride", {
    width: 1440,
    height: 1000,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await navigate(new URL("/favicon.svg", url).href);
  await command("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  initScript = (
    await command("Page.addScriptToEvaluateOnNewDocument", {
      source: `(${installWorkerBarrier.toString()})()`,
    })
  ).identifier;
  await navigate(url);
  await click(button("Open my workspace"));
  await click(named("summary", "Connect to a hub"));
  await click(named("summary", "Use a device token"));
  await fill(element("#endpoint"), server.url.href.replace(/\/$/, ""));
  await fill(element("#token"), "fixture");
  await click(button("Connect"));
  await until(`!(${button("Connect")}).disabled`);
  async function release() {
    await evaluate(`${fixture}.releaseSource();${fixture}.releaseRows();`);
  }
  async function sourceRecord() {
    acceptDiscard = true;
    await release();
    if (
      await evaluate(`!!${element("dialog[open]")}`)
    )
      await key("Escape");
    if (await evaluate(`!!${editor}`))
      await click(button("Close record", editor));
    if (await evaluate(`!!(${button("Discard")})`))
      await click(button("Discard"));
    await click(button("widgets", element('nav[aria-label="Tables"]')));
    await click(button("Fixture record", grid));
    await until(`!!(${heading("Fixture record")})`);
    await until(`!!(${link("Related record", editor)})`);
    // The record paints from the listed row and stays inert until its fresh row arrives.
    await until("document.querySelector('.record-panel form')?.inert===false");
  }
  // Records save themselves; only a value autosave refuses (Title is required) keeps
  // a draft that leaving has to ask about.
  async function refuseTitle() {
    await evaluate(
      `(()=>{const e=${input("Title")};e.focus();e.value='';e.dispatchEvent(new Event('input',{bubbles:true}));e.blur();})()`,
    );
    await until(
      `document.querySelector('[aria-label="Record save status"]')?.dataset.state==='failed'`,
    );
  }
  async function clickSource(name = "Related record") {
    await click(link(name));
    await click(button("Open in workspace", popup));
  }
  async function check(name: string, run: () => Promise<void>) {
    if (
      process.env.IRIS_SOURCE_CASE &&
      !name.includes(process.env.IRIS_SOURCE_CASE)
    )
      return;
    try {
      await sourceRecord();
      await run();
      console.log(`PASS: ${name}`);
    } catch (error) {
      failures.push(name);
      console.error(`FAIL: ${name}\n${error}`);
    } finally {
      acceptDiscard = true;
      await release();
    }
  }
  await check(
    "explicit record identity opens a fresh destination without writing",
    async () => {
      const writes = await evaluate(`${fixture}.writes`);
      await click(button("Open record", editor));
      await until(`!!(${heading("Second record")})`);
      expect(await evaluate(`${fixture}.writes`)).toBe(writes);
      expect(
        db.db
          .query("SELECT output FROM widgets WHERE id='fixture-record'")
          .get(),
      ).toEqual({ output: "widgets/second-record" });
    },
  );
  await check(
    "unavailable explicit identity keeps the draft and reports an error",
    async () => {
      await fill(input("Output"), "widgets/missing");
      // The edit saves itself first; opening it then writes nothing more.
      await evaluate("document.activeElement?.blur()");
      await until(
        `document.querySelector('[aria-label="Record save status"]')?.dataset.state==='saved'`,
      );
      const writes = await evaluate(`${fixture}.writes`);
      await click(button("Open record", editor));
      await until(
        `(${editor}).textContent.includes('This record is not available in this workspace.')`,
      );
      expect(await evaluate(`(${input("Output")}).value`)).toBe(
        "widgets/missing",
      );
      expect(await evaluate(`${fixture}.writes`)).toBe(writes);
      // The edit saved itself; put the identity back for the cases that follow.
      await fill(input("Output"), "widgets/second-record");
      await evaluate("document.activeElement?.blur()");
      await until(
        `document.querySelector('[aria-label="Record save status"]')?.dataset.state==='saved'`,
      );
    },
  );
  await check(
    "an unsaveable draft can cancel explicit record navigation",
    async () => {
      acceptDiscard = false;
      const before = dialogs;
      await refuseTitle();
      const writes = await evaluate(`${fixture}.writes`);
      await click(button("Open record", editor));
      await expect.poll(() => dialogs).toBe(before + 1);
      await until(`!!(${button("Open record", editor)}) && !(${button("Open record", editor)}).disabled`);
      expect(await evaluate(`(${input("Title")}).value`)).toBe("");
      expect(await evaluate(`!!(${heading("Fixture record")})`)).toBe(true);
      expect(await evaluate(`${fixture}.writes`)).toBe(writes);
    },
  );
  for (const navigation of ["related", "Find"]) {
    await check(
      `older source lookup cannot replace newer ${navigation} navigation`,
      async () => {
        await evaluate(`${fixture}.holdSource=true`);
        await clickSource();
        await until(`${fixture}.heldSource.length===1`);
        const hold = () => evaluate(`${fixture}.holdRow='legacy-record'`);
        if (navigation === "related") {
          await hold();
          await click(button("Open Legacy record", editor));
        } else {
          await click(
            `[...document.querySelectorAll('button')].find(e=>e.textContent.includes('Find records'))`,
          );
          // The table toolbar has a "Search records" box too; type into Find's.
          await fill(element('dialog[open] [aria-label="Search records"]'), "Legacy");
          const option = `[...document.querySelectorAll('[role="option"]')].find(e=>e.textContent.includes('Legacy record'))`;
          await until(`!!(${option}) && !(${option}).disabled`);
          // Hold only the destination's row read: search results read rows of their own.
          await hold();
          await click(option);
        }
        await until(`${fixture}.heldRows.length===1`);
        await evaluate(`${fixture}.releaseSource()`);
        await evaluate(`${fixture}.releaseRows()`);
        await until(
          `!!(${heading("Legacy record")})`,
          "newer navigation must win over older source lookup",
        );
        await until(`${fixture}.inFlight===0`);
        expect(await evaluate(`!!(${heading("Legacy record")})`)).toBe(true);
      },
    );
  }
  await check(
    "superseded source failure stays silent while newer lookup waits",
    async () => {
      await evaluate(`${fixture}.holdSource=true`);
      await clickSource();
      await until(`${fixture}.heldSource.length===1`);
      await evaluate(`${fixture}.holdRow='legacy-record'`);
      await evaluate(`(${button("Open Legacy record", editor)}).focus()`);
      await key("Enter");
      await until(`${fixture}.heldRows.length===1`);
      await evaluate(`${fixture}.releaseSource(true)`);
      await until(`!(${button("Open in workspace", popup)}).disabled`);
      expect(await evaluate(`(${popup}).textContent`)).not.toContain(
        "Delayed source lookup failed",
      );
      expect(await evaluate(`(${popup}).textContent`)).not.toContain(
        "This link has no record available",
      );
      expect(
        await evaluate(`(${popup}).querySelectorAll('[role="status"]').length`),
      ).toBe(0);
      await evaluate(`${fixture}.releaseRows()`);
      await until(`!!(${heading("Legacy record")})`);
    },
  );
  await check("current source lookup failure remains visible", async () => {
    await evaluate(`${fixture}.holdSource=true`);
    await clickSource();
    await until(`${fixture}.heldSource.length===1`);
    await evaluate(`${fixture}.releaseSource(true)`);
    await until(
      `(${popup}).textContent.includes('Delayed source lookup failed')`,
    );
    expect(await evaluate(`!!(${heading("Fixture record")})`)).toBe(true);
  });
  await check(
    "unmapped source link retains its availability message",
    async () => {
      await clickSource("Unmapped record");
      await until(
        `(${popup}).textContent.includes('This link has no record available')`,
      );
      expect(await evaluate(`!!(${heading("Fixture record")})`)).toBe(true);
    },
  );
  await check(
    "canceling source navigation retains the latest full-record draft",
    async () => {
      const before = dialogs;
      await refuseTitle();
      acceptDiscard = false;
      await clickSource();
      await expect.poll(() => dialogs).toBe(before + 1);
      await until(`!(${button("Open in workspace", popup)}).disabled`);
      expect(
        await evaluate(`(${popup}).querySelectorAll('[role="status"]').length`),
      ).toBe(0);
      expect(await evaluate(`(${input("Title")}).value`)).toBe("");
      expect(
        db.db
          .query("SELECT title FROM widgets WHERE id=?")
          .get("fixture-record"),
      ).toEqual({ title: "Fixture record" });
    },
  );
  await check(
    "inline source navigation preserves dirty Markdown until explicit discard",
    async () => {
      await click(button("Close record", editor));
      await click(
        `[...document.querySelectorAll('summary')].find(e=>e.textContent.trim()==='Columns')`,
      );
      const visible = element('input[aria-label="Show Body"]');
      if (!(await evaluate(`(${visible}).checked`))) await click(visible);
      await click(
        `[...document.querySelectorAll('summary')].find(e=>e.textContent.trim()==='Columns')`,
      );
      const cell = element('[data-row="fixture-record"][data-column="body"]');
      await click(cell, 2);
      await until(`!!(${link("Related record", cell)})`);
      await click(`${cell}.querySelector('[contenteditable="true"]')`);
      await evaluate(
        `(()=>{const field=${cell}.querySelector('[contenteditable="true"]');field.focus();const selection=document.getSelection();selection.selectAllChildren(field);selection.collapseToEnd();})()`,
      );
      await key("Enter");
      await command("Input.insertText", { text: "Unsent inline text" });
      const before = dialogs;
      const writes = await evaluate(`${fixture}.writes`);
      acceptDiscard = false;
      await clickSource();
      await expect.poll(() => dialogs).toBe(before + 1);
      await until(`!(${button("Open in workspace", popup)}).disabled`);
      expect(
        await evaluate(`(${popup}).querySelectorAll('[role="status"]').length`),
      ).toBe(0);
      expect(await evaluate(`${cell}.textContent`)).toContain(
        "Unsent inline text",
      );
      expect(await evaluate(`!!${editor}`)).toBe(false);
      expect(await evaluate(`${fixture}.writes`)).toBe(writes);
      acceptDiscard = true;
      await click(button("Open in workspace", popup));
      await until(`!!(${heading("Second record")})`);
      expect(await evaluate(`${fixture}.writes`)).toBe(writes);
      expect(
        db.db
          .query("SELECT body FROM widgets WHERE id=?")
          .get("fixture-record"),
      ).toEqual({ body });
    },
  );
  if (failures.length)
    throw Error(
      `${failures.length} source-navigation cases failed: ${failures.join("; ")}`,
    );
} catch (error) {
  console.error(await evaluate("document.body?.innerText").catch(String));
  throw error;
} finally {
  await evaluate(`${fixture}?.releaseSource();${fixture}?.releaseRows()`).catch(
    () => {},
  );
  if (initScript)
    await command("Page.removeScriptToEvaluateOnNewDocument", {
      identifier: initScript,
    });
  await navigate(new URL("/favicon.svg", url).href).catch(() => {});
  await command("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  cdp.close();
  server.stop(true);
  db.db.close();
  auth.db.close();
}
