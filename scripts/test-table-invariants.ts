import { chromium, expect } from '@playwright/test';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin, workspacePage } from './test-origin';

// Catches a host bypass of shared rule checks, incomplete-replica trust, and
// partial rollback of an invalid edit through the actual Worker/OPFS boundary.
const source = process.argv[2];
if (!source) throw Error('Provide the life-data checkout');
const url = process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-markdown.localhost:5198/workspace?review';
const origin = disposableOrigin(url);
let failPull = false;
const { server, db } = await regressionHub(source, origin, 0, {
  wrap: worker => ({ async fetch(request: Request, env: unknown, context: unknown) {
    if (failPull && new URL(request.url).pathname === '/v1/rows/pull')
      return new Response('Fixture offline', {status:503,headers:{'Access-Control-Allow-Origin':origin}});
    return worker.fetch(request,env,context);
  }}),
});
db.db.query('INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)')
  .run('quantity-positive','widgets','invariant',1,'SELECT id FROM changed WHERE quantity < 0','Quantity cannot be negative.');
db.db.exec("INSERT INTO catalog_tables(id,kind,display) VALUES ('history','system','col')");
const browser = await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP ?? 'http://127.0.0.1:9222');
let ownedPage: import('@playwright/test').Page | undefined;
try {
  const page = ownedPage = workspacePage(browser.contexts().flatMap(c => c.pages()), url);
  if (!page) throw Error('Open the reserved review page');
  page.setDefaultTimeout(10000);
  await page.setViewportSize({width:1440,height:1000});
  page.on('dialog',dialog=>dialog.accept());
  await page.goto(new URL('/',url).href);
  const cdp=await page.context().newCDPSession(page);
  await cdp.send('Storage.clearDataForOrigin',{origin,storageTypes:'all'});
  await cdp.detach();
  await page.addInitScript(()=>{
    const state=window as any;
    state.holdPermissionTable='';state.heldPermissions=[];
    state.releasePermissions=()=>{state.holdPermissionTable='';state.heldPermissions.splice(0).forEach((deliver:()=>void)=>deliver());};
    const Original=window.Worker;
    window.Worker=class extends Original {
      tables=new Map<number,string>();
      postMessage(message:any,...args:any[]){if(message.method==='writeability')this.tables.set(message.id,message.args.table);return super.postMessage(message,...args as [any]);}
      set onmessage(handler:any){super.onmessage=event=>{const table=this.tables.get(event.data.id);this.tables.delete(event.data.id);const deliver=()=>handler.call(this,event);if(table&&table===state.holdPermissionTable)state.heldPermissions.push(deliver);else deliver();};}
    };
  });
  await page.goto(url);
  const open=async()=>{
    await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
    await page.getByText('Connect to a hub',{exact:true}).click();await page.getByText('Use a device token', {exact:true}).click();
    await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/,''));
    await page.getByLabel('Device token').fill('fixture');
  };
  const sync=async()=>{
    await page.getByRole('button',{name:'Sync now',exact:true}).click();
    await expect(page.getByRole('button',{name:'Sync now',exact:true})).toBeEnabled({timeout:30000});
  };
  await open();await sync();
  await expect(page.getByRole('button',{name:'New record',exact:true})).toBeEnabled();
  await page.getByRole('button',{name:'Fixture record',exact:true}).click();
  await page.getByLabel('Quantity',{exact:true}).fill('-1');
  await page.getByRole('button',{name:'Save record',exact:true}).click();
  await expect(page.getByRole('alert')).toContainText('Quantity cannot be negative.');
  await expect(page.getByLabel('Quantity',{exact:true})).toHaveValue('-1');
  await expect(page.getByText('Pending edits: 0',{exact:true})).toBeVisible();
  await page.getByRole('button',{name:'Close record',exact:true}).click();
  await page.getByRole('button',{name:'Fixture record',exact:true}).click();
  await expect(page.getByLabel('Quantity',{exact:true})).toHaveValue('42');
  await page.getByLabel('Quantity',{exact:true}).fill('43');
  await page.getByRole('button',{name:'Save record',exact:true}).click();
  await expect(page.getByText('Pending edits: 1',{exact:true})).toBeVisible();
  await page.getByRole('button',{name:'Close record',exact:true}).click();
  await sync();
  expect(db.db.query("SELECT quantity FROM widgets WHERE id='fixture-record'").get()).toEqual({quantity:43});
  expect(db.db.query("SELECT col,old,new FROM history WHERE row_id='fixture-record'").all()).toEqual([{col:'quantity',old:'42',new:'43'}]);
  console.log('PASS: valid table rules allow edits; invalid edits retain the draft and roll back rows, history and pending state');

  // Omit even a read-only dependency: arbitrary rule SQL can reference it.
  await page.getByRole('button',{name:'Switch workspace',exact:true}).click();
  await page.evaluate(()=>localStorage.setItem('life-ui:replica',JSON.stringify({maxRows:50000,tables:{history:false}})));
  await open();await sync();
  await expect(page.getByRole('button',{name:'New record',exact:true})).toBeDisabled();
  await expect(page.getByRole('status',{name:'Editing availability'})).toContainText('history');
  await page.getByRole('button',{name:'Fixture record',exact:true}).click();
  await expect(page.getByLabel('Quantity',{exact:true})).toBeDisabled();
  await page.getByRole('button',{name:'Close record',exact:true}).click();
  await page.getByRole('button',{name:'Switch workspace',exact:true}).click();
  await page.evaluate(()=>localStorage.setItem('life-ui:replica',JSON.stringify({maxRows:50000,tables:{}})));
  await open();await sync();
  await expect(page.getByRole('button',{name:'New record',exact:true})).toBeEnabled();
  console.log('PASS: skipped history blocks invariant writes and a complete backfill restores editing');

  failPull=true;await sync();
  await expect(page.getByRole('button',{name:'New record',exact:true})).toBeDisabled();
  await expect(page.getByRole('status',{name:'Editing availability'})).toContainText('incomplete');
  failPull=false;await sync();
  await expect(page.getByRole('button',{name:'New record',exact:true})).toBeEnabled();
  await page.reload();
  await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
  await expect(page.getByRole('button',{name:'New record',exact:true})).toBeEnabled();
  console.log('PASS: interrupted sync revokes editing until recovery, and successful coverage survives reopen');

  await page.evaluate(()=>{(window as any).holdPermissionTable='history';});
  await page.getByRole('navigation',{name:'Tables'}).getByRole('button',{name:'history',exact:true}).click();
  await page.waitForFunction(()=>(window as any).heldPermissions.length>0);
  await page.getByRole('navigation',{name:'Tables'}).getByRole('button',{name:'widgets',exact:true}).click();
  await expect(page.getByRole('button',{name:'New record',exact:true})).toBeEnabled();
  await page.evaluate(()=>(window as any).releasePermissions());
  await expect(page.getByRole('button',{name:'New record',exact:true})).toBeEnabled();
  await page.getByRole('button',{name:'New record',exact:true}).click();
  await expect(page.getByLabel('Quantity',{exact:true})).toBeEnabled();
  console.log('PASS: a delayed read-only advisory cannot lock a subsequently selected writable table');

  await page.getByRole('button',{name:'Close record',exact:true}).click();
  const ddl='CREATE TRIGGER widgets_marker AFTER UPDATE ON widgets BEGIN SELECT 1; END';
  db.db.exec(ddl);
  db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run(new Date().toISOString(),ddl);
  await page.getByText('Connect to a hub',{exact:true}).click();await page.getByText('Use a device token', {exact:true}).click();
  await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/,''));
  await page.getByLabel('Device token').fill('fixture');
  await sync();
  await expect(page.getByRole('button',{name:'New record',exact:true})).toBeDisabled();
  await expect(page.getByRole('status',{name:'Editing availability'})).toContainText('Unsupported trigger');
  await page.getByRole('button',{name:'Fixture record',exact:true}).click();
  await expect(page.getByLabel('Quantity',{exact:true})).toHaveValue('43');
  await expect(page.getByLabel('Quantity',{exact:true})).toBeDisabled();
  console.log('PASS: unsupported effects explain read-only state while records remain browsable');
} finally {
  const page = ownedPage;
  await page?.evaluate(()=>(window as any).releasePermissions?.()).catch(()=>{});
  await browser.close();
  server.stop(true);
  db.db.close();
}
