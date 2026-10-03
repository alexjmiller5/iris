import { chromium, expect, type Page } from '@playwright/test';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin, workspacePage } from './test-origin';

const source = process.argv[2];
if (!source) throw Error('Provide the life-data checkout');
const url = process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-markdown.localhost:5198/workspace?review';
const origin = disposableOrigin(url);
let capped = false, firstSchemaFailure = true;
const pulls: Record<string, unknown>[] = [];
const { server, db } = await regressionHub(source, origin, 0, {
  wrap: worker => ({ async fetch(request: Request, env: unknown, context: unknown) {
    if (request.method === 'POST' && new URL(request.url).pathname === '/v1/schema/pull' && firstSchemaFailure) return new Response('Fixture initial sync failure', {status:503,headers:{'Access-Control-Allow-Origin':origin}});
    if (request.method === 'POST' && new URL(request.url).pathname === '/v1/rows/pull') {
      const body = await request.clone().json() as Record<string, unknown>;
      if (body.table === 'widgets') {
        pulls.push(body);
        if (capped) return new Response(JSON.stringify({error:'usage_cap',message:'Monthly read allowance reached.',metric:'rows_read',used:100,cap:100}),{status:429,headers:{'Content-Type':'application/json','Access-Control-Allow-Origin':origin}});
      }
    }
    return worker.fetch(request,env,context);
  }})
});
db.db.exec('DELETE FROM widgets');
const stamp = new Date().toISOString();
for (let i=0; i<205; i++) db.db.query('INSERT INTO widgets(id,title,body,status,deleted_at,updated_at) VALUES (?,?,?,?,?,?)').run(
  `remote-${String(i).padStart(3,'0')}`, `Online entry ${String(i).padStart(3,'0')}`, '# Online body\n\nA **complete** record.', 'Dynamic', i===10?stamp:null,stamp
);
const browser = await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP ?? 'http://127.0.0.1:9222');
let ownedPage: Page | undefined;
try {
  const page = ownedPage = workspacePage(browser.contexts().flatMap(c=>c.pages()),url);
  if (!page) throw Error('Open the reserved review page');
  page.setDefaultTimeout(10000);
  await page.setViewportSize({width:1440,height:1000});
  page.on('dialog',dialog=>dialog.accept());
  await page.goto(new URL('/',url).href);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Storage.clearDataForOrigin',{origin,storageTypes:'all'});
  await cdp.detach();
  await page.addInitScript(()=>{
    const state=window as any;state.holdOnline=false;state.heldOnline=[];
    state.releaseOnline=()=>{state.holdOnline=false;state.heldOnline.splice(0).forEach((deliver:()=>void)=>deliver());};
    const Original=window.Worker;
    window.Worker=class extends Original {
      methods=new Map<number,string>();
      postMessage(message:any,...args:any[]){this.methods.set(message.id,message.method);return super.postMessage(message,...args as [any]);}
      set onmessage(handler:any){super.onmessage=event=>{const method=this.methods.get(event.data.id);this.methods.delete(event.data.id);const deliver=()=>handler.call(this,event);if(method==='remoteRow'&&state.holdOnline)state.heldOnline.push(deliver);else deliver();};}
    };
  });
  await page.goto(url);
  await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
  await page.getByText('Connect to a hub',{exact:true}).click();await page.getByText('Use a device token', {exact:true}).click();
  await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/,''));
  await page.getByLabel('Device token').fill('fixture');
  await page.getByLabel('Automatic sync row limit').fill('0');
  const sync = page.getByRole('button',{name:'Sync now',exact:true});
  await sync.click(); await expect(sync).toBeEnabled({timeout:30000});
  await expect(page.getByRole('alert')).toContainText('503');
  firstSchemaFailure=false;
  await sync.click(); await expect(sync).toBeEnabled({timeout:30000});
  await expect(page.getByRole('alert')).toHaveCount(0);
  console.log('PASS: the first sync failure is visible before any tables exist and explicit retry recovers');
  await expect(page.getByText('This table is excluded from sync. Its local records may be incomplete.',{exact:true})).toBeVisible();
  expect(pulls).toHaveLength(0);
  await page.getByRole('button',{name:'New record',exact:true}).click();
  await page.getByRole('textbox',{name:'Title',exact:true}).fill('Keep this local draft');
  await page.getByRole('button',{name:'Browse online',exact:true}).click();
  const dialog = page.getByRole('dialog',{name:'Online widgets',exact:true});
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('button',{name:'Online entry 000',exact:true})).toBeVisible();
  await expect(dialog.getByRole('status')).toContainText('50 records loaded');
  await page.keyboard.press('Meta+k');
  await expect(page.getByRole('dialog',{name:'Find records',exact:true})).toHaveCount(0);
  expect(pulls).toHaveLength(1);
  expect(pulls[0]).toMatchObject({table:'widgets',since:'',limit:50});
  expect(pulls[0]).not.toHaveProperty('after');
  for (const count of [100,150,200,205]) {
    await dialog.getByRole('button',{name:'Load more',exact:true}).click();
    await expect(dialog.getByRole('status')).toContainText(`${count} records loaded`);
  }
  await expect(dialog.getByRole('button',{name:'Load more',exact:true})).toHaveCount(0);
  expect(pulls).toHaveLength(5);
  console.log('PASS: a skipped table loads 205 online records with one bounded request per page');

  db.db.query('UPDATE widgets SET title=?,updated_at=? WHERE id=?').run('Fresh online title',new Date().toISOString(),'remote-000');
  await dialog.getByRole('button',{name:'Online entry 000',exact:true}).click();
  await expect(dialog.getByRole('heading',{name:'Fresh online title',exact:true})).toBeVisible();
  expect(pulls.at(-1)).toMatchObject({limit:2,where:{id:'remote-000'}});
  await expect(dialog.getByText('A complete record.',{exact:true})).toBeVisible();
  await expect(dialog.getByRole('button',{name:'Save record',exact:true})).toHaveCount(0);
  await dialog.getByRole('button',{name:'Back to online records',exact:true}).click();
  await dialog.getByLabel('Record ID',{exact:true}).fill('remote-010');
  await dialog.getByRole('button',{name:'Find ID',exact:true}).click();
  await expect(dialog.getByText('This record is in the trash.',{exact:true})).toBeVisible();
  await dialog.getByRole('button',{name:'Back to online records',exact:true}).click();
  await dialog.getByLabel('Record ID',{exact:true}).fill('absent');
  await dialog.getByRole('button',{name:'Find ID',exact:true}).click();
  await expect(dialog.getByRole('alert')).toContainText('not found');
  await expect(dialog.getByRole('button',{name:'Online entry 204',exact:true})).toBeVisible();
  console.log('PASS: opening and exact-ID lookup fetch fresh full rows; deleted and missing records stay explicit and read-only');

  await page.evaluate(()=>{(window as any).holdOnline=true;});
  await dialog.getByRole('button',{name:'Online entry 000',exact:true}).click();
  await page.waitForFunction(()=>(window as any).heldOnline.length===1);
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('textbox',{name:'Title',exact:true})).toHaveValue('Keep this local draft');
  await page.getByRole('button',{name:'Browse online',exact:true}).click();
  await expect(dialog.getByRole('status')).toContainText('50 records loaded');
  await page.evaluate(()=>(window as any).releaseOnline());
  await expect(dialog.getByRole('heading',{name:'Fresh online title',exact:true})).toHaveCount(0);
  console.log('PASS: closing and reopening ignores a delayed online record without losing the local draft');

  capped=true; const beforeCap=pulls.length;
  await dialog.getByRole('button',{name:'Refresh',exact:true}).click();
  await expect(dialog.getByRole('alert')).toContainText('429');
  expect(pulls).toHaveLength(beforeCap+1);
  capped=false;
  await dialog.getByRole('button',{name:'Refresh',exact:true}).click();
  await expect(dialog.getByRole('status')).toContainText('50 records loaded');
  await expect(dialog.getByRole('button',{name:'Fresh online title',exact:true})).toBeVisible();
  expect(pulls.at(-1)).not.toHaveProperty('after');
  console.log('PASS: a usage cap is surfaced once; explicit refresh starts at the first page');

  await page.setViewportSize({width:390,height:844});
  await expect(dialog).toBeVisible();
  expect(await dialog.evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
  const screenshot=process.env.LIFE_UI_TEST_SCREENSHOT;
  if(screenshot){
    await page.screenshot({path:screenshot});
    await page.emulateMedia({colorScheme:'dark'});
    await page.screenshot({path:screenshot.replace(/\.png$/, '-dark.png')});
    await page.setViewportSize({width:1440,height:1000});
    await page.screenshot({path:screenshot.replace(/\.png$/, '-desktop-dark.png')});
    await page.emulateMedia({colorScheme:null});
  }
  await dialog.getByRole('button',{name:'Close online browsing',exact:true}).click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('textbox',{name:'Title',exact:true})).toHaveValue('Keep this local draft');
  await expect(page.getByText('Pending edits: 0',{exact:true})).toBeVisible();
  await expect(page.getByText('This table is excluded from sync. Its local records may be incomplete.',{exact:true})).toBeVisible();
  await expect(page.getByRole('button',{name:'Fresh online title',exact:true})).toHaveCount(0);
  await page.reload();
  await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
  await expect(page.getByRole('button',{name:'Fresh online title',exact:true})).toHaveCount(0);
  console.log('PASS: online browsing fits a narrow screen and leaves the local replica and pending edits untouched across reopen');
} finally {
  await ownedPage?.setViewportSize({width:1440,height:1000}).catch(()=>{});
  await browser.close();server.stop(true);db.db.close();
}
