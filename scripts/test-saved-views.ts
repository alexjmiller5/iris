import { chromium, expect as base } from '@playwright/test';
import { installCoreSchemas, regressionHub } from './workspace-regression-hub';
import { disposableOrigin, workspacePage, synced } from './test-origin';

// Synced saved views on a synthetic hub: projection with full edit rows, unsupported
// definitions, Save as new view under a held write, discard cancellation, stale
// Rename refusal, Delete keeping records, and local views in the sample workspace.
// Open the reserved review page in a disposable Chrome first.
// Shared build hosts can be slow; waits are generous, never fixed sleeps.
const expect=base.configure({timeout:15000});
const url=process.env.IRIS_TEST_URL??'http://iris-markdown.localhost:5198/workspace?review';
const origin=disposableOrigin(url);
const source=process.argv[2];
if(!source)throw Error('Provide the soma checkout');
const {server,db,auth}=await regressionHub(source,origin);
await installCoreSchemas(db,source,['saved-views','view-defaults']);
db.db.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)').run('agent-view','Only the second record','widgets',JSON.stringify({version:1,columns:['title','body'],filters:[{column:'title',op:'eq',value:'Second record'}],sort:[{column:'title',direction:'desc'},{column:'quantity',direction:'asc'}],widths:{body:430}}));
db.db.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)').run('future-view','A newer definition','widgets',JSON.stringify({version:99}));
const browser=await chromium.connectOverCDP(process.env.IRIS_TEST_CDP??'http://127.0.0.1:9222');
let ownedPage: import('@playwright/test').Page | undefined;
try{
 const page = ownedPage = workspacePage(browser.contexts().flatMap(c => c.pages()), url);
 if(!page)throw Error('Open the reserved review page');
 page.setDefaultTimeout(15000);await page.bringToFront();await page.setViewportSize({width:1440,height:1000});
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
 // Device tokens are session credentials: a reopened workspace connects again to sync.
 const connect=async()=>{
  await page.getByText('Connect to a hub',{exact:true}).click({timeout:30000});await page.getByText('Use a device token', {exact:true}).click();
  await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/,''));await page.getByLabel('Device token').fill('fixture');
  await page.getByRole('button',{name:'Connect',exact:true}).click();
 };
 await page.goto(url);
 await page.getByRole('button' ,{name:'Open my workspace',exact:true}).click({timeout:30000});
 await connect();
 const widgets=page.getByRole('navigation',{name:'Tables'}).getByRole('button',{name:'widgets',exact:true});
 await widgets.click({timeout:15000});
 const views=page.getByRole('combobox',{name:'View',exact:true});
 const headers=page.locator('[role="columnheader"]:not(.selection)');
 const menu=page.getByRole('dialog',{name:'View settings',exact:true});
 const settings=async()=>{if(!await menu.isVisible())await page.getByRole('button',{name:'View settings',exact:true}).click();await expect(menu).toBeVisible();};
 /** A view's definition as the hub stores it once the automatic push lands. */
 const hub=(id:string)=>{const row=db.db.query('SELECT definition FROM views WHERE id=?').get(id) as any;return row?JSON.parse(row.definition):null;};
 await expect(views).toContainText('Only the second record');
 await expect(views.locator('option[value="future-view"]')).toHaveJSProperty('disabled',true);
 await expect(views.locator('option[value="future-view"]')).toContainText('Unsupported');
 await views.selectOption('agent-view');
 await expect(page.getByRole('button',{name:'Second record',exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'Fixture record',exact:true})).not.toBeVisible();
 await expect(headers).toHaveText(['Record','Body']);
 // Projection controls display only. Editing must still load every original field.
 await page.getByRole('button',{name:'Second record',exact:true}).click();
 await expect(page.getByLabel('Quantity',{exact:true})).toHaveValue('42');
 await page.getByRole('button',{name:'Close record',exact:true}).click();
 console.log('PASS: synced saved view applies filters and layout while keeping hidden edit values');
 await page.getByRole('button',{name:/^Sort/}).click();
 await page.getByRole('dialog',{name:'Sort'}).getByLabel('Sort 1 property').selectOption('id');
 await page.keyboard.press('Escape');
 await page.getByText('Columns',{exact:true}).click();
 await expect(page.getByLabel('Width Body',{exact:true})).toHaveValue('430');
 await page.getByLabel('Width Body',{exact:true}).fill('360');
 await page.getByLabel('Width Body',{exact:true}).press('Tab');
 await page.getByText('Columns',{exact:true}).click();
 // Settings save into the applied view on their own; wait so only Save as is held below.
 await expect.poll(()=>hub('agent-view')?.widths,{timeout:30000}).toEqual({body:360});
 await settings();
 await menu.getByLabel('View name',{exact:true}).fill('A saved copy');
 await page.evaluate(() => { (window as any).holdViewWrites=true; });
 await menu.getByRole('button',{name:'Save as new view',exact:true}).click();
 await page.waitForFunction(()=>(window as any).heldViewWrites.length>0);
 await expect(page.getByRole('button',{name:'Switch workspace',exact:true})).toBeDisabled();
 await expect(page.getByRole('button',{name:'Second record',exact:true})).toBeDisabled();
 await page.evaluate(() => (window as any).releaseViewWrites());
 await expect(views).not.toHaveValue('agent-view');
 await page.keyboard.press('Escape');
 const copyId=await views.inputValue();
 expect(copyId).not.toBe('');
 await synced(page);
 const stored=db.db.query('SELECT * FROM views WHERE id=?').get(copyId) as any;
 expect(stored?.name).toBe('A saved copy');
 expect(JSON.parse(stored.definition)).toMatchObject({columns:['title','body'],filters:[{column:'title',op:'eq',value:'Second record'}],widths:{body:360},sort:[{column:'id',direction:'desc'},{column:'quantity',direction:'asc'}]});
 console.log('PASS: Save as new view writes a guarded synced row with the current layout');
 await page.reload();
 await page.getByRole('button',{name:'Open my workspace',exact:true}).click({timeout:30000});
 await connect();
 await widgets.click();
 await expect(views).toContainText('A saved copy');
 await views.selectOption(copyId);
 await expect(views).toHaveValue(copyId);
 await expect(headers).toHaveText(['Record','Body']);
 await expect(page.getByRole('button',{name:'Second record',exact:true})).toBeVisible();
 await page.getByRole('button',{name:'Second record',exact:true}).click();
 await page.getByRole('textbox',{name:'Title',exact:true}).fill('Unsaved title');
 acceptDialog=false;
 await views.selectOption('agent-view');
 await expect(views).toHaveValue(copyId);
 await expect(page.getByRole('textbox',{name:'Title',exact:true})).toHaveValue('Unsaved title');
 acceptDialog=true;
 await page.getByRole('button',{name:'Close record',exact:true}).click();
 console.log('PASS: reopen keeps saved views and canceling discard preserves the current view and record draft');
 // Another device renames the same synced definition while a local rename is typed.
 await settings();
 await menu.getByLabel('View name',{exact:true}).fill('My unsaved rename');
 const remoteRevision=new Date(Date.now()+1000).toISOString();
 db.db.query('UPDATE views SET name=?,updated_at=?,hub_at=? WHERE id=?').run('Renamed elsewhere',remoteRevision,remoteRevision,copyId);
 await expect(views).toContainText('Renamed elsewhere',{timeout:15000});
 await expect(menu.getByLabel('View name',{exact:true})).toHaveValue('My unsaved rename');
 await menu.getByRole('button',{name:'Rename',exact:true}).click();
 await expect(menu.getByRole('alert')).toContainText('changed');
 await expect(menu.getByLabel('View name',{exact:true})).toHaveValue('My unsaved rename');
 expect((db.db.query('SELECT name FROM views WHERE id=?').get(copyId) as any).name).toBe('Renamed elsewhere');
 await expect(page.locator('.record-link')).toHaveText(['Second record']);
 console.log('PASS: a remote edit refuses a stale rename and preserves the local name and configuration');
 await page.keyboard.press('Escape');
 await views.selectOption(copyId);
 await settings();
 await menu.getByLabel('View name',{exact:true}).fill('Reviewed rename');
 await menu.getByRole('button',{name:'Rename',exact:true}).click();
 await expect(views).toContainText('Reviewed rename');
 await menu.getByRole('button',{name:'Delete view',exact:true}).click();
 await menu.getByRole('button',{name:'Confirm delete',exact:true}).click();
 await expect(views).not.toHaveValue(copyId);
 await expect(page.getByText('View deleted; records kept',{exact:true})).toBeVisible();
 await page.keyboard.press('Escape');
 await expect(page.locator('.record-link')).toHaveText(['Fixture record','Legacy record','Second record']);
 await expect(views).not.toContainText('Reviewed rename');
 await synced(page);
 expect((db.db.query('SELECT deleted_at FROM views WHERE id=?').get(copyId) as any).deleted_at).toBeTruthy();
 expect((db.db.query('SELECT COUNT(*) AS n FROM widgets WHERE deleted_at IS NULL').get() as any).n).toBe(3);
 console.log('PASS: deleting a view opens the table default without deleting records');
 await page.getByRole('button',{name:'Switch workspace',exact:true}).click();
 await page.getByRole('button',{name:'Try sample workspace',exact:true}).click();
 await expect(page.getByRole('button',{name:'A place to start',exact:true})).toBeVisible();
 await settings();
 await menu.getByLabel('View name',{exact:true}).fill('Sample drafts');
 await menu.getByRole('button',{name:'Save as new view',exact:true}).click();
 await expect(views).toContainText('Sample drafts');
 await page.keyboard.press('Escape');
 const sampleId=await views.inputValue();expect(sampleId).not.toBe('');
 await page.reload();
 await page.getByRole('button',{name:'Try sample workspace',exact:true}).click({timeout:30000});
 await expect(views).toContainText('Sample drafts');
 await views.selectOption(sampleId);
 await expect(page.getByRole('button',{name:'A place to start',exact:true})).toBeVisible();
 console.log('PASS: the separate sample workspace provisions views locally and retains them across reopen');
 if(process.env.IRIS_TEST_SHOTS)await page.screenshot({path:`${process.env.IRIS_TEST_SHOTS}/saved-views-desktop.png`,fullPage:true});
 await page.setViewportSize({width:390,height:844});await page.emulateMedia({colorScheme:'dark'});
 if(process.env.IRIS_TEST_SHOTS)await page.screenshot({path:`${process.env.IRIS_TEST_SHOTS}/saved-views-mobile.png`,fullPage:true});
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
}finally{const page = ownedPage;await page?.evaluate(()=>(window as any).releaseViewWrites?.()).catch(()=>{});await page?.emulateMedia({colorScheme:null}).catch(()=>{});await browser.close();server.stop(true);db.db.close();auth.db.close();}
