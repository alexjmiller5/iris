import { workspacePage } from './test-origin';
import {chromium,expect} from '@playwright/test';
import {disposableOrigin} from './test-origin';
const url=process.env.IRIS_TEST_URL??'http://iris-markdown.localhost:5198/workspace?review',origin=disposableOrigin(url);
const browser=await chromium.connectOverCDP('http://127.0.0.1:9222');
try{
 const page=workspacePage(browser.contexts().flatMap(c => c.pages()), url);
 if(!page)throw Error('Owned test page unavailable');
 page.on('dialog',d=>d.accept());page.setDefaultTimeout(5000);page.setDefaultNavigationTimeout(30000);
 await page.goto(new URL('/',url).href);
 const cdp=await page.context().newCDPSession(page);
 await cdp.send('Storage.clearDataForOrigin',{origin,storageTypes:'all'});await cdp.detach();
 await page.context().route(`${origin}/src/lib/database.worker.ts*`, async route => {
   const response = await route.fetch();
   const original = await response.text();
   let body = original.replace("notes: \"title TEXT, status TEXT, body TEXT\"", "notes: \"title TEXT, status TEXT, body TEXT, appendix TEXT DEFAULT 'Keep the appendix'\"");
   // SQL is available only in this disposable Worker artifact, never production.
   body = body.replace('switch (method) {', `switch (method) {
     case '__test_catalog': return db.run("INSERT INTO catalog_properties(id,tbl,col,label,sort,type) VALUES ('notes.appendix','notes','appendix','Appendix',10,'markdown')");`);
   if (!body.includes("appendix TEXT DEFAULT")) throw Error('Demo fixture seed seam moved');
   await route.fulfill({response,body});
 });
 await page.addInitScript(() => {
   const state = window as any;
   state.holdWrites = false; state.heldWrites = []; state.writeRequests = [];
   state.releaseWrites = () => { state.holdWrites = false; state.heldWrites.splice(0).forEach((deliver: () => void) => deliver()); };
   const Original = window.Worker;
   window.Worker = class extends Original {
     writes = new Set<number>();
     postMessage(message: any, ...args: any[]) {
       if (message.method === 'write') { this.writes.add(message.id); state.writeRequests.push(message.args); }
       return super.postMessage(message, ...args as [any]);
     }
     set onmessage(handler: any) {
       super.onmessage = event => {
         const write = this.writes.delete(event.data.id);
         const deliver = () => handler.call(this, event);
         if (write && state.holdWrites) state.heldWrites.push(deliver); else deliver();
       };
     }
   };
 });
 await page.goto(url);
 await page.waitForLoadState('networkidle');
 await page.getByRole('button',{name:'Try sample workspace',exact:true}).click();
 await page.getByRole('button',{name:'A place to start',exact:true}).click();
 await page.getByRole('button', {name:'Body options',exact:true}).click();
  await page.getByRole('menuitem', {name:'Body source',exact:true}).click();
 await page.getByRole('textbox',{name:'Body',exact:true}).fill('Automatically saved offline');
 await expect(page.locator('[aria-label="Body save status"]')).toHaveAttribute('data-state','saved');
 await page.reload();
 await page.getByRole('button',{name:'Try sample workspace',exact:true}).click();
 await page.getByRole('button',{name:'A place to start',exact:true}).click();
 await page.getByRole('button', {name:'Body options',exact:true}).click();
  await page.getByRole('menuitem', {name:'Body source',exact:true}).click();
 await expect(page.getByRole('textbox',{name:'Body',exact:true})).toHaveValue('Automatically saved offline');
 await page.evaluate(() => { (window as any).holdWrites = true; });
 await page.getByRole('textbox',{name:'Body',exact:true}).fill('First in flight');
 await page.waitForFunction(() => (window as any).heldWrites.length === 1);
 await expect(page.locator('[aria-label="Body save status"]')).toHaveAttribute('data-state','saving');
 await expect(page.getByRole('button',{name:'Save record',exact:true})).toBeDisabled();
 await page.getByRole('textbox',{name:'Body',exact:true}).fill('Typed after save started');
 await page.getByRole('textbox',{name:'Title',exact:true}).fill('Unsaved property change');
 await page.evaluate(() => (window as any).releaseWrites());
 await expect(page.locator('[aria-label="Body save status"]')).toHaveAttribute('data-state','saved');
 await expect(page.getByRole('textbox',{name:'Body',exact:true})).toHaveValue('Typed after save started');
 await expect(page.getByRole('textbox',{name:'Title',exact:true})).toHaveValue('Unsaved property change');
 const writes=await page.evaluate(()=>(window as any).writeRequests);
 expect(writes).toHaveLength(2);
 expect(writes[0].patch.body).toBe('First in flight');
 expect(writes[1].patch.body).toBe('Typed after save started');
 expect(writes.every((w:any)=>!('title' in w.patch))).toBe(true);
 expect(writes[1].expectedUpdatedAt).not.toBe(writes[0].expectedUpdatedAt);
 await page.reload();
 await page.getByRole('button',{name:'Try sample workspace',exact:true}).click();
 await page.getByRole('button',{name:'A place to start',exact:true}).click();
 await page.getByRole('button', {name:'Body options',exact:true}).click();
  await page.getByRole('menuitem', {name:'Body source',exact:true}).click();
 await expect(page.getByRole('textbox',{name:'Body',exact:true})).toHaveValue('Typed after save started');
 await expect(page.getByRole('textbox',{name:'Title',exact:true})).toHaveValue('A place to start');
 // A second real database client updates the same record after the editor opened.
 await page.evaluate(async () => {
   const { WorkspaceDatabase } = await import('/src/lib/database.ts');
   const other = new WorkspaceDatabase();
   try {
     await other.request('open', {demo:true});
     const [row] = await other.request('rows', {view:{table:'notes',filters:[{column:'title',op:'eq',value:'A place to start'}],limit:1}});
     await other.request('write', {table:'notes',patch:{id:row.id,body:'A newer edit from another client'},expectedUpdatedAt:row.updated_at});
   } finally { other.close(); }
 });
 await page.clock.install();
 await page.getByRole('textbox',{name:'Body',exact:true}).fill('Conflicting draft kept here');
 await page.clock.runFor(700);
 await expect(page.getByRole('status',{name:'Body save status',exact:true})).toHaveText('Body not saved. Your draft is kept.');
 await expect(page.getByRole('alert')).toContainText(/changed|stale|revision/i);
 await expect(page.getByRole('textbox',{name:'Body',exact:true})).toHaveValue('Conflicting draft kept here');
 const count=await page.evaluate(()=>(window as any).writeRequests.length);
 await page.clock.runFor(2500);
 expect(await page.evaluate(()=>(window as any).writeRequests.length)).toBe(count);
 await page.clock.resume();
 await page.getByRole('button',{name:'Close record',exact:true}).click();
 await page.getByRole('button',{name:'A place to start',exact:true}).click();
 await page.evaluate(async () => {
   const {WorkspaceDatabase}=await import('/src/lib/database.ts');
   const other=new WorkspaceDatabase();
   try {
     await other.request('open',{demo:true});
     await other.request('__test_catalog');
     await other.request('write',{table:'notes',patch:{title:'Catalog refresh event',body:'A different row'}});
   } finally {other.close();}
 });
 await expect(page.getByRole('button',{name:'Catalog refresh event',exact:true})).toBeVisible();
 await page.clock.runFor(2500);
 async function appendix(){return page.evaluate(async()=>{
   const {WorkspaceDatabase}=await import('/src/lib/database.ts');const other=new WorkspaceDatabase();
   try{await other.request('open',{demo:true});const [row]=await other.request('rows',{view:{table:'notes',filters:[{column:'title',op:'eq',value:'A place to start'}],limit:1}});return row.appendix;}finally{other.close();}
 });}
 await expect.poll(appendix).toBe('Keep the appendix');
 await page.getByRole('button', {name:'Body options',exact:true}).click();
  await page.getByRole('menuitem', {name:'Body source',exact:true}).click();
 await page.getByRole('textbox',{name:'Body',exact:true}).fill('Body saved after catalog changed');
 await expect(page.locator('[aria-label="Body save status"]')).toHaveAttribute('data-state','saved');
 await expect(page.getByRole('complementary',{name:'Record editor',exact:true}).locator('.eyebrow')).toContainText('Saved');
 await page.getByRole('textbox',{name:'Title',exact:true}).fill('A place to start');
 await page.getByRole('button',{name:'Save record',exact:true}).click();
 await expect(page.getByRole('button',{name:'Save record',exact:true})).toBeEnabled();
 expect(await appendix()).toBe('Keep the appendix');
 // Each Markdown field owns its own menu dismissal and focus restoration.
 await page.getByRole('button',{name:'Close record',exact:true}).click();
 await page.getByRole('button',{name:'A place to start',exact:true}).click();
 const bodyOptions = page.getByRole('button',{name:'Body options',exact:true});
 const appendixOptions = page.getByRole('button',{name:'Appendix options',exact:true});
 await bodyOptions.click();
 await expect(page.getByRole('menu',{name:'Body options',exact:true})).toBeVisible();
 await appendixOptions.click();
 await expect(page.getByRole('menu',{name:'Body options',exact:true})).toBeHidden();
 await expect(page.getByRole('menu',{name:'Appendix options',exact:true})).toBeVisible();
 await page.keyboard.press('Escape');
 await expect(page.getByRole('menu',{name:'Appendix options',exact:true})).toBeHidden();
 await expect(appendixOptions).toBeFocused();
 console.log('PASS: autosave races/conflicts and catalog refreshes preserve all drafts and unopened fields');
}finally{await browser.contexts()[0]?.unroute(`${origin}/src/lib/database.worker.ts*`);await browser.close()}
