// Usage: LIFE_UI_TEST_TARGET=<owned-target-id> bun scripts/test-view-options.ts <core-checkout> [all|rollover|options|actions]
import { resolve } from "node:path";
import { mkdir } from "node:fs/promises";
import { regressionHub } from "./workspace-regression-hub";
import { disposableOrigin } from "./test-origin";

const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-markdown.localhost:5252/workspace?review";
const source = process.argv[2];
if (!source) throw Error("Provide the Life Data source checkout");
const mode = process.argv[3] ?? "all";
const { server, db, auth } = await regressionHub(source, disposableOrigin(url));
const schema = await Bun.file(
  resolve(source, "core/schema/saved-views.json"),
).json();
for (const ddl of [
  "ALTER TABLE catalog_properties ADD COLUMN source TEXT",
  "ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT",
  "ALTER TABLE widgets ADD COLUMN due TEXT",
  "ALTER TABLE widgets ADD COLUMN done INTEGER",
  "ALTER TABLE widgets ADD COLUMN related TEXT",
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
] as const)
  for (const record of records) {
    const columns = Object.keys(record);
    db.db
      .query(
        `INSERT INTO ${table} (${columns.map((c) => '"' + c + '"').join(",")}) VALUES (${columns.map(() => "?").join(",")})`,
      )
      .run(...Object.values(record));
  }
db.db
  .exec(`INSERT INTO catalog_properties(id,tbl,col,type,label,ref_table) VALUES
  ('widgets.due','widgets','due','date','Due',NULL),
  ('widgets.done','widgets','done','bool','Done',NULL),
  ('widgets.related','widgets','related','ref','Related','widgets');
  UPDATE widgets SET due='2026-06-01' WHERE id='fixture-record';
  UPDATE widgets SET due='2026-06-02' WHERE id='second-record';`);
db.db.query("INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)").run(
  "late-day",
  "Late day",
  "widgets",
  JSON.stringify({
    version: 2,
    filters: [{ column: "due", op: "lte", relative: "today" }],
    timeZone: "America/New_York",
    dayStartMinutes: 180,
  }),
);
// Attach only to the explicitly owned fixture target. Browser-wide Playwright
// attachment can stall on unrelated extension pages in a shared Chrome session.
const target = process.env.LIFE_UI_TEST_TARGET;
if (!target)
  throw Error("Provide LIFE_UI_TEST_TARGET from the owned session group");
const endpoint = process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222";
let socket: WebSocket | undefined;
let next = 0;
const pending = new Map<
  number,
  {
    resolve: (value: any) => void;
    reject: (error: unknown) => void;
    timer: ReturnType<typeof setTimeout>;
  }
>();
async function call(
  method: string,
  params: Record<string, unknown> = {},
): Promise<any> {
  return new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(Error("CDP timeout: " + method));
    }, 12000);
    pending.set(id, { resolve, reject, timer });
    socket!.send(JSON.stringify({ id, method, params }));
  });
}
async function screenshot(name: string) {
  const directory = process.env.LIFE_UI_TEST_SCREENSHOT_DIR;
  if (!directory) return;
  await mkdir(directory, { recursive: true });
  const result = await call("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: false,
  });
  await Bun.write(
    resolve(directory, name + ".png"),
    Buffer.from(result.data, "base64"),
  );
}
async function evaluate(expression: string) {
  const reply = await call("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
    userGesture: true,
  });
  if (reply.exceptionDetails)
    throw Error(JSON.stringify(reply.exceptionDetails));
  return reply.result.value;
}
async function until(expression: string, description: string, seconds = 10) {
  for (let i = 0; i < seconds * 10; i++) {
    if (await evaluate(expression)) return;
    await Bun.sleep(100);
  }
  throw Error("Timed out: " + description);
}
const literal = JSON.stringify;
async function click(text: string, scope = "document") {
  const find = `Array.from(${scope}?.querySelectorAll('button,summary')??[]).find(e=>e.textContent.trim()===${literal(text)} && !e.disabled)`;
  await until(`!!(${find})`, "enabled " + text);
  await evaluate(`(${find}).click()`);
}
async function set(selector: string, value: string) {
  await until(
    `document.querySelector(${literal(selector)}) && !document.querySelector(${literal(selector)}).disabled`,
    selector,
  );
  await evaluate(
    `(()=>{const e=document.querySelector(${literal(selector)}); e.value=${literal(value)};e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));})()`,
  );
}
const view = '[aria-label="View"]';
async function selectView(id: string) {
  await set(view, id);
  await until(
    `document.querySelector(${literal(view)}).value===${literal(id)} && !document.querySelector(${literal(view)}).disabled`,
    "applied view " + id,
  );
}
async function rows(labels: string[]) {
  await until(
    `JSON.stringify([...document.querySelectorAll('.record-link')].map(e=>e.textContent.trim()))===${literal(JSON.stringify(labels))}`,
    "rows " + labels.join(", "),
    15,
  );
}
async function openOptions(prefix: string) {
  await evaluate(
    `(()=>{const s=[...document.querySelectorAll('.view-controls summary')].find(e=>e.textContent.startsWith(${literal(prefix)}));if(!s)throw Error('Missing options');s.parentElement.open=true;})()`,
  );
}
async function value(selector: string, expected: string) {
  await until(
    `document.querySelector(${literal(selector)})?.value===${literal(expected)}`,
    selector + " = " + expected,
  );
}
try {
  const pages = await (await fetch(endpoint + "/json/list")).json();
  const owned = pages.find((p: any) => p.id === target);
  if (
    !owned ||
    new URL(owned.url).origin !== new URL(url).origin ||
    owned.type !== "page"
  )
    throw Error("Owned synthetic target missing");
  socket = new WebSocket(owned.webSocketDebuggerUrl);
  socket.onmessage = (message) => {
    const reply = JSON.parse(String(message.data));
    if (!reply.id) return;
    const request = pending.get(reply.id);
    if (!request) return;
    pending.delete(reply.id);
    clearTimeout(request.timer);
    reply.error ? request.reject(reply.error) : request.resolve(reply.result);
  };
  await new Promise<void>((resolve, reject) => {
    socket!.onopen = () => resolve();
    socket!.onerror = reject;
  });
  await call("Page.enable");
  await call("Page.navigate", { url: new URL("/", url).href });
  await until(
    `location.pathname==='/' && document.readyState==='complete'`,
    "fixture reset",
  );
  await call("Storage.clearDataForOrigin", {
    origin: new URL(url).origin,
    storageTypes: "all",
  });
  await call("Page.navigate", { url });
  await until(
    `document.querySelector('#svelte-announcer')!==null && [...document.querySelectorAll('button')].some(e=>e.textContent.trim()==='Open my workspace' && !e.disabled)`,
    "hydrated workspace",
  );
  await click("Open my workspace");
  await click("Connect to a hub");
  await click("Use a device token");
  await set("#endpoint", server.url.href.replace(/\/$/, ""));
  await set("#token", "fixture");
  await click("Sync now");
  await click("widgets", `document.querySelector('nav[aria-label="Tables"]')`);
  await rows(["Fixture record", "Legacy record", "Second record"]);
  if (mode === "all" || mode === "rollover") {
    // Date advances with real elapsed time. The app's actual rollover timer fires.
    // This override is page-local and is discarded by the final navigation.
    await evaluate(
      `(()=>{const NativeDate=Date, epoch=NativeDate.parse('2026-06-02T06:59:50Z'), start=NativeDate.now();window.__viewClockOffset=0;window.Date=class extends NativeDate{constructor(...args){super(...(args.length?args:[epoch+NativeDate.now()-start+window.__viewClockOffset]));}static now(){return epoch+NativeDate.now()-start+window.__viewClockOffset;}};})()`,
    );
    await selectView("late-day");
    await rows(["Fixture record"]);
    await openOptions("Filter groups");
    await value('[aria-label="Day starts at"]', "03:00");
    await rows(["Fixture record", "Second record"]);
    await screenshot("rollover");
    await set('[aria-label="Day starts at"]', "04:00");
    await rows(["Fixture record"]);
    await set('[aria-label="View name"]', "Boundary copy");
    await click("Save as");
    await until(
      `document.querySelector(${literal(view)}).value!=='' && document.querySelector(${literal(view)}).value!=='late-day'`,
      "saved boundary copy",
    );
    const copied = await evaluate(
      `document.querySelector(${literal(view)}).value`,
    );
    await selectView("");
    await value('[aria-label="Day starts at"]', "00:00");
    await selectView(copied);
    await value('[aria-label="Day starts at"]', "04:00");
    await rows(["Fixture record"]);
    await set('[aria-label="Today timezone"]', "UTC");
    await rows(["Fixture record", "Second record"]);
    await set('[aria-label="Today timezone"]', "America/New_York");
    await rows(["Fixture record"]);
    await evaluate(
      `window.__viewClockOffset+=86400000;window.dispatchEvent(new Event('focus'));`,
    );
    await rows(["Fixture record", "Second record"]);
    console.log(
      "PASS: 02:59/03:00 actual timer, policy/timezone refresh, save/reopen, midnight reset and foreground refresh",
    );
  }
  if (mode === "all" || mode === "options") {
    await selectView("");
    await openOptions("Filter groups");
    await click("Add filter group");
    await set('[aria-label="Rule property"]', "quantity");
    await value('[aria-label="Rule property"]', "quantity");
    await set('[aria-label="Rule condition"]', "eq");
    await set('[aria-label="Rule value"]', "42");
    await rows(["Fixture record", "Legacy record", "Second record"]);
    await set('[aria-label="Rule property"]', "done");
    await value('[aria-label="Rule property"]', "done");
    await value('[aria-label="Rule value"]', "false");
    await click("Remove group");
    console.log(
      "PASS: numeric and boolean filter property changes stay editable",
    );
  }
  if (mode === "all" || mode === "actions") {
    await selectView("");
    await openOptions("Row actions");
    await click("Add action");
    await set('[aria-label="Add value to action 1"]', "status");
    await until(
      `!!document.querySelector('select[id^="action-"][id$="-status"] option[value="Dynamic"]')`,
      "dynamic select",
    );
    await set('select[id^="action-"][id$="-status"]', "Dynamic");
    await set('[aria-label="Add value to action 1"]', "tags");
    await until(
      `!!document.querySelector('select[id^="action-"][id$="-tags"] option[value="Dynamic"]')`,
      "dynamic multi-select",
    );
    await set('select[id^="action-"][id$="-tags"]', "Dynamic");
    await set('[aria-label="Add value to action 1"]', "related");
    await set('[aria-label="Search Related"]', "Second");
    await until(
      `!!document.querySelector('select[id^="action-"][id$="-related"] option[value="second-record"]')`,
      "reference search",
    );
    await set('select[id^="action-"][id$="-related"]', "second-record");
    await set(".view-controls fieldset label input", "Apply choices");
    await until(
      `!document.querySelector('select[id^="action-"][id$="-related"] option[value="fixture-record"]')`,
      "retained filtered choices",
    );
    await value('[aria-label="Search Related"]', "Second");
    await set('[aria-label="View name"]', "Action choices");
    await click("Save as");
    await until(
      `document.querySelector(${literal(view)}).value!==''`,
      "saved action view",
    );
    const actionView = await evaluate(
      `document.querySelector(${literal(view)}).value`,
    );
    await evaluate(
      `(async()=>{const {WorkspaceDatabase}=await import('/src/lib/database.ts');const other=new WorkspaceDatabase();try{await other.request('open',{demo:false});const saved=(await other.request('listViews',{table:'widgets'})).views.find(v=>v.id===${literal(actionView)});await other.request('saveView',{id:saved.id,table:'widgets',name:'Changed elsewhere',expectedUpdatedAt:saved.updated_at,definition:{...saved.definition,actions:saved.definition.actions.map(a=>({...a,values:{title:'Unexpected external action'}}))}});}finally{other.close();}})()`,
    );
    await until(
      `!![...document.querySelector(${literal(view)}).options].find(o=>o.textContent==='Changed elsewhere')`,
      "refreshed saved view list",
    );
    await click("Apply choices");
    await until(
      `document.body.innerText.includes('Saved view changed. Reload it before running this action.')`,
      "stale displayed action rejection",
    );
    await rows(["Fixture record", "Legacy record", "Second record"]);
    await screenshot("action-guard");
    console.log(
      "PASS: dynamic action choices, retained reference search and frozen displayed revision guard",
    );
  }
} catch (error) {
  if (socket?.readyState === WebSocket.OPEN)
    console.error(
      "DIAGNOSTIC",
      await evaluate(
        `({url:location.href,body:document.body.innerText.slice(-1800)})`,
      ).catch(() => null),
    );
  throw error;
} finally {
  if (socket?.readyState === WebSocket.OPEN) {
    await call("Page.navigate", { url: new URL("/", url).href }).catch(
      () => {},
    );
    await until(
      `location.pathname==='/' && document.readyState==='complete'`,
      "cleanup navigation",
    ).catch(() => {});
    await call("Storage.clearDataForOrigin", {
      origin: new URL(url).origin,
      storageTypes: "all",
    }).catch(() => {});
    socket.close();
  }
  for (const request of pending.values()) {
    clearTimeout(request.timer);
    request.reject(Error("CDP closed"));
  }
  server.stop(true);
  db.db.close();
  auth.db.close();
}
