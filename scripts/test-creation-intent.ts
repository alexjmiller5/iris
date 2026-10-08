import { chromium, expect, type Page } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { disposableOrigin, workspacePage } from "./test-origin";
import { regressionHub } from "./workspace-regression-hub";
const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-creation.localhost:5242/workspace?review";
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source)
  throw Error("Usage: bun scripts/test-creation-intent.ts <life-data-checkout>");
const { server, db } = await regressionHub(source, origin);
// Synthetic defaults and byte-preserving copy inputs; only this disposable hub.
for (const [col, sql, type, value] of [
 ['links','TEXT','multi_ref','["second-record"]'], ['literal','TEXT','text','Old default'], ['empty','TEXT','text',null], ['code','TEXT','text',null]
]) {
 const ddl=`ALTER TABLE widgets ADD COLUMN ${col} ${sql}`;
 db.db.exec(ddl);
 db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z',ddl);
 db.db.query('INSERT INTO catalog_properties(id,tbl,col,label,type,default_value,immutable) VALUES (?,?,?,?,?,?,?)').run(`widgets.${col}`,'widgets',col,col,type,value,col==='code'?1:0);
}
db.db.exec("UPDATE catalog_properties SET ref_table='widgets' WHERE col='links'");
db.db.exec("UPDATE widgets SET links='[\"second-record\"]',empty='',body='',code='SET-ONCE' WHERE id='fixture-record'");
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
  ).toBeEnabled({ timeout: 30000 });
  await page.getByText("Connect to a hub", { exact: true }).click();
  await page.getByText("Use a device token", { exact: true }).click();
  await page.getByLabel("Hub address").fill(server.url.href.replace(/\/$/, ""));
  await page.getByLabel("Device token").fill("fixture");
  await page.getByRole("button",{name:"Connect",exact:true}).click();
  await expect(
    page.getByRole("button", { name: "Fixture record", exact: true }),
  ).toBeVisible({ timeout: 30000 });
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

  let failures=0, dialogs=0;
  owned.on('dialog',()=>dialogs++);
  const close=async()=>{accept=true;if(await editor.isVisible())await editor.getByRole('button',{name:'Close record',exact:true}).click();};
  const fresh=async()=>{await close();await owned.getByRole('button',{name:'New record at bottom',exact:true}).click();await expect(editor).toBeVisible();};
  const local=async(method:string,args:unknown)=>owned.evaluate(async({method,args})=>{
    const {WorkspaceDatabase}=await import('/src/lib/database.ts');const database=new WorkspaceDatabase();
    try{await database.request('open');return await database.request(method as any,args as any);}finally{database.close();}
  },{method,args});
  const all=()=>local('rows',{view:{table:'widgets',limit:200}}) as Promise<any[]>;
  const save=async(title:string)=>{
   await editor.getByLabel('Title',{exact:true}).fill(title);
   await editor.getByRole('button',{name:'Save record',exact:true}).click();
   await expect(editor.getByRole('heading',{name:title,exact:true})).toBeVisible();
   return (await all()).find(r=>r.title===title);
  };
  const check=async(name:string,body:()=>Promise<void>)=>{
   if(process.env.LIFE_UI_CREATION_CASE&&!name.includes(process.env.LIFE_UI_CREATION_CASE))return;
   try{await body();console.log('PASS',name);}catch(error){failures++;console.error('FAIL',name,error);}finally{await close();}
  };
  await check('same-empty clear participates in Close cancellation',async()=>{
   await fresh();await expect(editor.getByLabel('Status',{exact:true})).toHaveValue('');
   await editor.getByRole('button',{name:'Clear Status',exact:true}).click();
   accept=false;const before=dialogs;
   await editor.getByRole('button',{name:'Close record',exact:true}).click();
   expect(dialogs).toBe(before+1);await expect(editor).toBeVisible();
   expect((await save('Explicit null')).status).toBeNull();
  });
  await check('untouched literal preview uses current core default at Save',async()=>{
   await fresh();await expect(editor.getByLabel('literal',{exact:true})).toHaveValue('Old default');
   db.db.exec("UPDATE catalog_properties SET default_value='New default',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id='widgets.literal'");
   await local('sync',{endpoint:server.url.href.replace(/\/$/,''),token:'fixture'});
   expect((await save('Current default')).literal).toBe('New default');
  });
  await check('grid duplicate preserves present empty strings and set-once data',async()=>{
   await close();await cell('title').focus();await cell('title').press('ArrowRight');
   await owned.getByRole('button',{name:'Duplicate record',exact:true}).click();
   await expect(editor).toBeVisible();
   const row=await save('Grid copy');expect(row.empty).toBe('');expect(row.body).toBe('');expect(row.code).toBe('SET-ONCE');expect(row.id).not.toBe('fixture-record');
  });
  await check('record editor exposes Duplicate without creating until Save',async()=>{
   await close();await cell('title').focus();await cell('title').press('Control+Enter');
   await expect(editor).toBeVisible();const count=(await all()).length;
   await editor.getByRole('button',{name:'Duplicate record',exact:true}).click();
   await expect(editor.getByRole('heading',{name:'Untitled',exact:true})).toBeVisible();
   expect((await all()).length).toBe(count);
   const row=await save('Editor copy');expect(row.empty).toBe('');expect(row.body).toBe('');
  });
  const openSource=async()=>{
   await close();await cell('title').focus();await cell('title').press('Control+Enter');
   await expect(editor).toBeVisible();
   await expect(editor.getByRole('button',{name:'Duplicate record',exact:true})).toBeEnabled();
  };
  await check('dirty source cancellation waits for lookup and preserves the editor',async()=>{
   await openSource();await editor.getByLabel('Title',{exact:true}).fill('Keep my source draft');
   const count=(await all()).length;accept=false;const before=dialogs;
   await editor.getByRole('button',{name:'Duplicate record',exact:true}).click();
   await expect.poll(()=>dialogs).toBe(before+1);
   await expect(editor.getByLabel('Title',{exact:true})).toHaveValue('Keep my source draft');
   expect((await all()).length).toBe(count);
  });
  await check('failed permission reply preserves source before any discard',async()=>{
   await openSource();await editor.getByLabel('Title',{exact:true}).fill('Keep on permission failure');
   const before=dialogs;
   await owned.evaluate(()=>{(window as any).gridHold='writeability';});
   await editor.getByRole('button',{name:'Duplicate record',exact:true}).click();
   await expect.poll(()=>owned.evaluate(()=>(window as any).gridHeld.length)).toBe(1);
   await owned.evaluate(()=>(window as any).releaseGrid(true));
   await expect(editor.locator('.failure')).toContainText('late cell lookup');
   await expect(editor.getByLabel('Title',{exact:true})).toHaveValue('Keep on permission failure');
   expect(dialogs).toBe(before);
  });
  await check('superseded permission failure leaves a newer draft and error untouched',async()=>{
   await openSource();await owned.evaluate(()=>{(window as any).gridHold='writeability';});
   await editor.getByRole('button',{name:'Duplicate record',exact:true}).click();
   await expect.poll(()=>owned.evaluate(()=>(window as any).gridHeld.length)).toBe(1);
   await fresh();await editor.getByLabel('Title',{exact:true}).fill('Newer draft');
   await owned.evaluate(()=>(window as any).releaseGrid(true));
   await expect(editor.getByLabel('Title',{exact:true})).toHaveValue('Newer draft');
   await expect(editor.locator('.failure')).toHaveCount(0);
  });
  await check('explicit Clear overrides copied empty text and failed Save retains the copy',async()=>{
   await openSource();await editor.getByRole('button',{name:'Duplicate record',exact:true}).click();
   await expect(editor.getByRole('heading',{name:'Untitled',exact:true})).toBeVisible();
   await editor.getByRole('button',{name:'Clear empty',exact:true}).click();
   await editor.getByRole('button',{name:'Clear Title',exact:true}).click();
   const count=(await all()).length;
   await editor.getByRole('button',{name:'Save record',exact:true}).click();
   await expect(editor.locator('.failure')).toContainText('required');
   expect((await all()).length).toBe(count);
   await expect(editor.getByLabel('code',{exact:true})).toHaveValue('SET-ONCE');
   const row=await save('Corrected copy');expect(row.empty).toBeNull();expect(row.body).toBe('');
   const source=(await all()).find(r=>r.id==='fixture-record');
   expect(source.title).toBe('Fixture record');expect(source.empty).toBe('');expect(source.body).toBe('');
  });
  await check('removing a preview or copied reference is explicit creation input',async()=>{
   for(const copy of [false,true]){
    if(copy){await openSource();await editor.getByRole('button',{name:'Duplicate record',exact:true}).click();await expect(editor.getByRole('heading',{name:'Untitled',exact:true})).toBeVisible();}else await fresh();
    await editor.getByRole('button',{name:'Remove Second record',exact:true}).click();
    expect((await save(copy?'Removed copied reference':'Removed preview reference')).links).toBe('[]');
   }
  });
  expect(pageErrors.filter(e=>!e.startsWith('ResizeObserver loop'))).toEqual([]);
  expect(failures).toBe(0);
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
