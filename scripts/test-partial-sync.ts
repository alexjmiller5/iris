import { chromium, expect } from '@playwright/test';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin, workspacePage, recordSaved } from './test-origin';

const source=process.argv[2];
if(!source)throw Error('Provide the soma checkout');
const url=process.env.IRIS_TEST_URL??'http://iris-markdown.localhost:5198/workspace?review';
const origin=disposableOrigin(url);
const observerUrl=url+'&observer=1';
let failHistory=false;
const {server,db}=await regressionHub(source,origin,0,{wrap:worker=>({async fetch(request:Request,env:unknown,context:unknown){
  if(failHistory&&new URL(request.url).pathname==='/v1/rows/pull'&&(await request.clone().json() as any).table==='history')
    return new Response('Fixture history failure',{status:503,headers:{'Access-Control-Allow-Origin':origin}});
  return worker.fetch(request,env,context);
}})});
db.db.query('INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)')
 .run('positive','widgets','invariant',1,'SELECT id FROM changed WHERE quantity<0','Quantity cannot be negative.');
const browser=await chromium.connectOverCDP(process.env.IRIS_TEST_CDP??'http://127.0.0.1:9222');
let ownedObserver: import('@playwright/test').Page | undefined;
try{
 const pages=browser.contexts().flatMap(c=>c.pages());
 const page=workspacePage(pages,url);
 const observer=ownedObserver=workspacePage(pages,observerUrl);
 if(!page||!observer)throw Error(`Open both dedicated review pages, including ${observerUrl}`);
 for(const tab of [page,observer]){
  tab.setDefaultTimeout(10000);await tab.setViewportSize({width:1440,height:1000});
  tab.on('dialog',dialog=>dialog.accept());await tab.goto(new URL('/',url).href);
 }
 const cdp=await page.context().newCDPSession(page);
 await cdp.send('Storage.clearDataForOrigin',{origin,storageTypes:'all'});await cdp.detach();
 await page.addInitScript(()=>{
  const state=window as any;state.failSnapshotReply=false;
  const Original=window.Worker;
  window.Worker=class extends Original {
   methods=new Map<number,string>();
   postMessage(message:any,...args:any[]){this.methods.set(message.id,message.method);return super.postMessage(message,...args as [any]);}
   set onmessage(handler:any){super.onmessage=event=>{
    const method=this.methods.get(event.data.id);this.methods.delete(event.data.id);
    if(method==='snapshot'&&state.failSnapshotReply)handler.call(this,{data:{...event.data,error:{message:'Fixture local refresh failure'}}});
    else handler.call(this,event);
   };}
  };
 });
 await page.goto(url);await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
 await page.getByText('Connect to a hub',{exact:true}).click();await page.getByText('Use a device token', {exact:true}).click();
 await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/,''));
 await page.getByLabel('Device token').fill('fixture');
 const sync=page.getByRole('button',{name:'Connect',exact:true});
 await sync.click();await expect(sync).toBeEnabled({timeout:30000});
 await observer.goto(observerUrl);
 await observer.getByRole('button',{name:'Open my workspace',exact:true}).click();
 await observer.getByRole('button',{name:'Fixture record',exact:true}).click();
 await observer.getByRole('textbox',{name:'Title',exact:true}).fill('Keep this unsaved draft');
 await page.getByRole('button',{name:'Fixture record',exact:true}).click();
 await page.getByLabel('Quantity',{exact:true}).fill('43');
 await recordSaved(page);
 for(const tab of [page,observer])await expect(tab.locator('[data-pending="1"]')).toBeVisible();
 await page.getByRole('button',{name:'Close record',exact:true}).click();
 const stamp=new Date(Date.now()+1000).toISOString();
 db.db.query('UPDATE widgets SET title=?,updated_at=?,hub_at=? WHERE id=?').run('Received before failure',stamp,stamp,'second-record');
 failHistory=true;await sync.click();await expect(sync).toBeEnabled({timeout:30000});
 expect(db.db.query("SELECT quantity FROM widgets WHERE id='fixture-record'").get()).toEqual({quantity:43});
 for(const tab of [page,observer]){
  await expect(tab.locator('[data-pending="0"]')).toBeVisible();
  await expect(tab.getByRole('button',{name:'Received before failure',exact:true})).toBeVisible();
  await expect(tab.getByRole('button',{name:'New record',exact:true})).toBeDisabled();
  await expect(tab.getByRole('status',{name:'Editing availability'})).toContainText('incomplete');
 }
 await expect(observer.getByRole('textbox',{name:'Title',exact:true})).toHaveValue('Keep this unsaved draft');
 await expect(observer.getByRole('textbox',{name:'Title',exact:true})).toBeDisabled();
 await expect(page.getByRole('alert')).toContainText('503');
 console.log('PASS: failed sync refreshes committed rows, partial receipts and editing availability in both tabs without replacing a draft');
 failHistory=false;await sync.click();await expect(sync).toBeEnabled({timeout:30000});
 for(const tab of [page,observer])await expect(tab.getByRole('button',{name:'New record',exact:true})).toBeEnabled();
 await expect(observer.getByRole('textbox',{name:'Title',exact:true})).toHaveValue('Keep this unsaved draft');
 await expect(observer.getByRole('textbox',{name:'Title',exact:true})).toBeEnabled();
 console.log('PASS: successful retry restores editing in every open tab and retains the unsaved draft');
 failHistory=true;
 await page.evaluate(()=>{(window as any).failSnapshotReply=true;});
 await sync.click();await expect(sync).toBeEnabled({timeout:30000});
 await expect.poll(async()=>({error:await page.getByRole('alert').innerText(),blocked:await page.getByRole('button',{name:'New record',exact:true}).isDisabled()}))
  .toMatchObject({error:expect.stringContaining('503'),blocked:true});
 await expect(page.getByRole('alert')).toContainText('Fixture local refresh failure');
 console.log('PASS: a failed local refresh retains the original sync error');
}finally{
 // Reload the reserved observer page to close its worker without losing its
 // identity for a subsequent regression run. A new page opens no database.
 await ownedObserver?.goto(observerUrl).catch(()=>{});
 await browser.close();server.stop(true);db.db.close();
}
