import { chromium, expect } from '@playwright/test';
import { resolve } from 'node:path';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin, workspacePage } from './test-origin';

const url=process.env.LIFE_UI_TEST_URL??'http://life-ui-markdown.localhost:5198/workspace?review';
const origin=disposableOrigin(url);
const source=process.argv[2];
if(!source)throw Error('Provide the life-data checkout');
const {server,db}=await regressionHub(source,origin);
const schema=await Bun.file(resolve(source,'core/schema/saved-views.json')).json();
for(const ddl of ['ALTER TABLE catalog_properties ADD COLUMN source TEXT','ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT',...schema.ddl]){
 db.db.exec(ddl);db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z',ddl);
}
for(const [table,records] of [['catalog_tables',[schema.table]],['catalog_properties',schema.properties]] as const){
 for(const record of records){
  const columns=Object.keys(record);db.db.query(`INSERT INTO ${table} (${columns.map(c=>'"'+c+'"').join(',')}) VALUES (${columns.map(()=>'?').join(',')})`).run(...Object.values(record));
 }
}
db.db.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)').run('agent-view','Only the second record','widgets',JSON.stringify({version:1,columns:['title','body'],filters:[{column:'title',op:'eq',value:'Second record'}],sort:[{column:'title',direction:'desc'},{column:'quantity',direction:'asc'}],widths:{body:430}}));
db.db.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)').run('future-view','A newer definition','widgets',JSON.stringify({version:2}));
const browser=await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP??'http://127.0.0.1:9222');
let ownedPage: import('@playwright/test').Page | undefined;
try{
 const page = ownedPage = workspacePage(browser.contexts().flatMap(c => c.pages()), url);
 if(!page)throw Error('Open the reserved review page');
 page.setDefaultTimeout(7000);await page.setViewportSize({width:1440,height:1000});
 let acceptDialog=true;
 page.on('dialog',dialog=>acceptDialog?dialog.accept():dialog.dismiss());
 await page.goto(new URL('/',url).href);
 const cdp=await page.context().newCDPSession(page);await cdp.send('Storage.clearDataForOrigin',{origin,storageTypes:'all'});await cdp.detach();
 await page.addInitScript(() => {
  const state=window as any;state.holdViewWrites=false;state.heldViewWrites=[];
  state.releaseViewWrites=()=>{state.holdViewWrites=false;state.heldViewWrites.splice(0).forEach((deliver:()=>void)=>deliver());};
  const Original=window.Worker;
  window.Worker=class extends Original {
   writes=new Set<number>();
   postMessage(message:any,...args:any[]){if(message.method==='saveView')this.writes.add(message.id);return super.postMessage(message,...args as [any]);}
   set onmessage(handler:any){super.onmessage=event=>{const write=this.writes.delete(event.data.id);const deliver=()=>handler.call(this,event);if(write&&state.holdViewWrites)state.heldViewWrites.push(deliver);else deliver();};}
  };
 });
 await page.goto(url);
 await page.getByRole('button' ,{name:'Open my workspace',exact:true}).click();
 await page.getByText('Connect to a hub',{exact:true}).click();await page.getByText('Use a device token', {exact:true}).click();
 await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/,''));await page.getByLabel('Device token').fill('fixture');
 await page.getByRole('button',{name:'Sync now',exact:true}).click();
 await page.getByRole('navigation',{name:'Tables'}).getByRole('button',{name:'widgets',exact:true}).click();
 const views=page.getByRole('combobox',{name:'View',exact:true});
 await expect(views).toContainText('Only the second record');
 await expect(views.locator('option[value="future-view"]')).toHaveJSProperty('disabled',true);
 await expect(views.locator('option[value="future-view"]')).toContainText('Unsupported');
 await views.selectOption('agent-view');
 await expect(page.getByRole('button',{name:'Second record',exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'Fixture record',exact:true})).not.toBeVisible();
 await expect(page.getByRole('columnheader')).toHaveText(['Record','Body']);
 // Projection controls display only. Editing must still load every original field.
 await page.getByRole('button',{name:'Second record',exact:true}).click();
 await expect(page.getByLabel('Quantity',{exact:true})).toHaveValue('42');
 await page.getByRole('button',{name:'Close record',exact:true}).click();
 console.log('PASS: synced saved view applies filters and layout while keeping hidden edit values');
 await page.getByText('Columns',{exact:true}).click();
 await expect(page.getByLabel('Width Body',{exact:true})).toHaveValue('430');
 await page.getByLabel('Width Body',{exact:true}).fill('360');
 await page.getByLabel('Width Body',{exact:true}).press('Tab');
 await page.getByText('Columns',{exact:true}).click();
 await expect(page.getByText('Modified',{exact:true})).toBeVisible();
 await page.getByLabel('View name',{exact:true}).fill('A saved copy');
 await page.evaluate(() => { (window as any).holdViewWrites=true; });
 await page.getByRole('button',{name:'Save as',exact:true}).click();
 await page.waitForFunction(()=>(window as any).heldViewWrites.length>0);
 await expect(page.getByRole('button',{name:'Switch workspace',exact:true})).toBeDisabled();
 await expect(page.getByRole('button',{name:'Second record',exact:true})).toBeDisabled();
 await page.evaluate(() => (window as any).releaseViewWrites());
 await expect(views).not.toHaveValue('agent-view');
 await expect(page.getByText('Modified',{exact:true})).not.toBeVisible();
 const copyId=await views.inputValue();
 expect(copyId).not.toBe('');
 await page.getByRole('button',{name:'Sync now',exact:true}).click();
 await expect(page.getByRole('button',{name:'Sync now',exact:true})).toBeEnabled();
 const stored=db.db.query('SELECT * FROM views WHERE id=?').get(copyId) as any;
 expect(stored?.name).toBe('A saved copy');
 expect(JSON.parse(stored.definition)).toMatchObject({columns:['title','body'],filters:[{column:'title',op:'eq',value:'Second record'}],widths:{body:360},sort:[{column:'title',direction:'desc'},{column:'quantity',direction:'asc'}]});
 console.log('PASS: save-as writes a guarded synced row with the current layout');
 await page.reload();
 await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
 await page.getByRole('navigation',{name:'Tables'}).getByRole('button',{name:'widgets',exact:true}).click();
 await expect(views).toContainText('A saved copy');
 await views.selectOption(copyId);
 await expect(page.getByRole('columnheader')).toHaveText(['Record','Body']);
 await expect(page.getByRole('button',{name:'Second record',exact:true})).toBeVisible();
 await page.getByRole('button',{name:'Second record',exact:true}).click();
 await page.getByRole('textbox',{name:'Title',exact:true}).fill('Unsaved title');
 acceptDialog=false;
 await views.selectOption('');
 await expect(views).toHaveValue(copyId);
 await expect(page.getByRole('textbox',{name:'Title',exact:true})).toHaveValue('Unsaved title');
 acceptDialog=true;
 await page.getByRole('button',{name:'Close record',exact:true}).click();
 console.log('PASS: reopen keeps saved views and canceling discard preserves the current view and record draft');
 // Simulate another device editing this same synced definition.
 await page.getByLabel('View name',{exact:true}).fill('My unsaved rename');
 const remoteRevision=new Date(Date.now()+1000).toISOString();
 db.db.query('UPDATE views SET name=?,updated_at=?,hub_at=? WHERE id=?').run('Renamed elsewhere',remoteRevision,remoteRevision,copyId);
 await page.getByText('Connect to a hub',{exact:true}).click();await page.getByText('Use a device token', {exact:true}).click();
 await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/,''));
 await page.getByLabel('Device token').fill('fixture');
 await page.getByRole('button',{name:'Sync now',exact:true}).click();
 await expect(page.getByRole('button',{name:'Sync now',exact:true})).toBeEnabled();
 await expect(views).toContainText('Renamed elsewhere');
 await expect(page.getByLabel('View name',{exact:true})).toHaveValue('My unsaved rename');
 await page.getByRole('button',{name:'Update selected',exact:true}).click();
 await expect(page.getByRole('group',{name:'Saved views',exact:true}).getByRole('alert')).toContainText('changed');
 await expect(page.getByLabel('View name',{exact:true})).toHaveValue('My unsaved rename');
 expect((db.db.query('SELECT name FROM views WHERE id=?').get(copyId) as any).name).toBe('Renamed elsewhere');
 await expect(page.locator('.record-link')).toHaveText(['Second record']);
 console.log('PASS: a remote edit refuses a stale update and preserves the local name and configuration');
 await views.selectOption(copyId);
 await expect(page.getByRole('button',{name:'Update selected',exact:true})).toBeEnabled();
 await page.getByLabel('View name',{exact:true}).fill('Reviewed rename');
 await page.getByRole('button',{name:'Update selected',exact:true}).click();
 await expect(views).toContainText('Reviewed rename');
 await page.getByRole('button',{name:'Delete view',exact:true}).click();
 await page.getByRole('button',{name:'Confirm delete',exact:true}).click();
 await expect(views).toHaveValue('');
 await expect(page.locator('.record-link')).toHaveText(['Fixture record','Legacy record','Second record']);
 await expect(views).not.toContainText('Reviewed rename');
 await page.getByRole('button',{name:'Sync now',exact:true}).click();
 await expect(page.getByRole('button',{name:'Sync now',exact:true})).toBeEnabled();
 expect((db.db.query('SELECT deleted_at FROM views WHERE id=?').get(copyId) as any).deleted_at).toBeTruthy();
 expect((db.db.query('SELECT COUNT(*) AS n FROM widgets WHERE deleted_at IS NULL').get() as any).n).toBe(3);
 console.log('PASS: deleting a view returns to all records without deleting records');
 await page.getByRole('button',{name:'Switch workspace',exact:true}).click();
 await page.getByRole('button',{name:'Try sample workspace',exact:true}).click();
 await expect(page.getByRole('button',{name:'A place to start',exact:true})).toBeVisible();
 await page.getByLabel('View name',{exact:true}).fill('Sample drafts');
 await page.getByRole('button',{name:'Save as',exact:true}).click();
 await expect(views).toContainText('Sample drafts');
 const sampleId=await views.inputValue();expect(sampleId).not.toBe('');
 await page.reload();
 await page.getByRole('button',{name:'Try sample workspace',exact:true}).click();
 await expect(views).toContainText('Sample drafts');
 await views.selectOption(sampleId);
 await expect(page.getByRole('button',{name:'A place to start',exact:true})).toBeVisible();
 console.log('PASS: the separate sample workspace provisions views locally and retains them across reopen');
 await page.screenshot({path:'/tmp/life-ui-saved-views-desktop.png',fullPage:true});
 await page.setViewportSize({width:390,height:844});await page.emulateMedia({colorScheme:'dark'});
 await page.screenshot({path:'/tmp/life-ui-saved-views-mobile.png',fullPage:true});
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
}finally{const page = ownedPage;await page?.evaluate(()=>(window as any).releaseViewWrites?.()).catch(()=>{});await browser.close();server.stop(true);db.db.close();}
