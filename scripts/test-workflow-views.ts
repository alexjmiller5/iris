import {chromium,expect} from '@playwright/test';
import {resolve} from 'node:path';
import {regressionHub} from './workspace-regression-hub';
import { disposableOrigin, workspacePage, synced } from './test-origin';
const url=process.env.IRIS_TEST_URL??'http://iris-markdown.localhost:5252/workspace?review';
const source=process.argv[2];if(!source)throw Error('Provide the Soma source checkout');
const {server,db,auth}=await regressionHub(source,disposableOrigin(url));
const schema=await Bun.file(resolve(source,'core/schema/saved-views.json')).json();
for(const ddl of ['ALTER TABLE catalog_properties ADD COLUMN source TEXT','ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT','ALTER TABLE widgets ADD COLUMN due TEXT',...schema.ddl]){
 db.db.exec(ddl);db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z',ddl);
}
for(const [table,records] of [['catalog_tables',[schema.table]],['catalog_properties',schema.properties]] as const)for(const record of records){const columns=Object.keys(record);db.db.query(`INSERT INTO ${table} (${columns.map(c=>'"'+c+'"').join(',')}) VALUES (${columns.map(()=>'?').join(',')})`).run(...Object.values(record));}
db.db.exec(`INSERT INTO catalog_properties(id,tbl,col,type,label) VALUES ('widgets.due','widgets','due','date','Due');
 UPDATE catalog_properties SET options_sql=NULL,default_value=NULL,options='[{"v":"Open","sort":0},{"v":"Pending","sort":1},{"v":"Reviewed","sort":2},{"v":"Problem","sort":3}]' WHERE id='widgets.status';
 UPDATE widgets SET status='Open',due='2026-03-08' WHERE id='fixture-record';
 UPDATE widgets SET status='Pending',due='2026-03-09' WHERE id='second-record';
 UPDATE widgets SET status='Open',due=NULL WHERE id='legacy-record';`);
const actions=[{id:'review',label:'Mark reviewed',values:{status:'Reviewed'}},{id:'problem',label:'Flag problem',values:{status:'Problem'}},{id:'retry',label:'Try again',values:{status:'Pending'}},{id:'test',label:'Test capture',values:{status:'Reviewed'}},{id:'dismiss',label:'Dismiss capture',values:{status:'Reviewed'}}];
const definition={version:2,columns:['title','status','due'],filters:[{column:'due',op:'lte',relative:'today'}],groups:[{match:'any',filters:[{column:'status',op:'eq',value:'Open'},{column:'status',op:'eq',value:'Pending'}]}],timeZone:'America/New_York',sort:[{column:'status',direction:'desc',mode:'options'},{column:'title',direction:'asc'}],actions,layout:[{kind:'column',id:'title'},...actions.map(a=>({kind:'action',id:a.id})),{kind:'column',id:'status'},{kind:'column',id:'due'}]};
db.db.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)').run('workflow','Daily queue','widgets',JSON.stringify(definition));
const browser=await chromium.connectOverCDP(process.env.IRIS_TEST_CDP??'http://127.0.0.1:9222');
const page=workspacePage(browser.contexts().flatMap(c=>c.pages()),url);if(!page)throw Error('Open the reserved fixture page');
try{
 page.setDefaultTimeout(10000);await page.setViewportSize({width:1440,height:1000});
 await page.goto(new URL('/',url).href);const cdp=await page.context().newCDPSession(page);await cdp.send('Storage.clearDataForOrigin',{origin:new URL(url).origin,storageTypes:'all'});await cdp.detach();
 await page.clock.install({time:new Date('2026-03-09T03:59:50Z')});
 await page.goto(url);await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
 await page.getByText('Connect to a hub',{exact:true}).click();await page.getByText('Use a device token',{exact:true}).click();
 await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/,''));await page.getByLabel('Device token').fill('fixture');
 await page.getByRole('button',{name:'Connect',exact:true}).click();
 await page.getByRole('navigation',{name:'Tables'}).getByRole('button',{name:'widgets',exact:true}).click();
 const views=page.getByRole('combobox',{name:'View',exact:true});await views.selectOption('workflow');await expect(views).toHaveValue('workflow');
 await expect(page.locator('.record-link')).toHaveText(['Fixture record']);
 // The first header is the row-selection checkbox.
 await expect(page.getByRole('columnheader')).toHaveText(['','Title',...actions.map(a=>a.label),'Status','Due']);
 if(process.env.IRIS_TEST_SCREENSHOT)await page.screenshot({path:process.env.IRIS_TEST_SCREENSHOT,fullPage:true});
 await page.clock.runFor(11000);
 await expect(page.locator('.record-link')).toHaveText(['Second record','Fixture record']);
 console.log('PASS: OR filters exclude undated rows and Today refreshes across local midnight');
 // The same callback handles resuming after sleep, even when no timer fired.
 await page.clock.setSystemTime(new Date('2026-03-08T12:00:00Z'));
 await page.evaluate(()=>window.dispatchEvent(new Event('focus')));
 await expect(page.locator('.record-link')).toHaveText(['Fixture record']);
 console.log('PASS: foreground refresh re-resolves the current local calendar day');
 await page.getByRole('button',{name:'Mark reviewed',exact:true}).click();
 await expect(page.locator('.record-link')).toHaveCount(0);
 // The table's default view has no filters: every record, including the reviewed one.
 const plain=(await views.locator('option').evaluateAll(o=>o.map(x=>(x as HTMLOptionElement).value))).find(v=>v&&v!=='workflow')!;
 await views.selectOption(plain);await expect(page.locator('.record-link')).toHaveCount(3);
 await page.getByRole('button',{name:'Fixture record',exact:true}).click();
 await expect(page.getByLabel('Status',{exact:true})).toHaveValue('Reviewed');
 await page.getByRole('button',{name:'Close record',exact:true}).click();
 await views.selectOption('workflow');
 // Sync runs on its own timers, which the installed clock holds; let time flow.
 await page.clock.resume();
 await synced(page); expect((db.db.query('SELECT status FROM widgets WHERE id=?').get('fixture-record') as any).status).toBe('Reviewed');
 console.log('PASS: action commits through ordinary sync and remains available in All records');
 // Preserve the definition across save/reopen, including action IDs, groups and option order.
 const settings=page.getByRole('button',{name:'View settings',exact:true});
 await settings.click();await page.getByLabel('View name',{exact:true}).fill('Queue copy');
 await page.getByRole('button',{name:'Save as new view',exact:true}).click();
 await expect(views).not.toHaveValue('workflow');const copy=await views.inputValue();expect(copy).not.toBe('');
 await page.reload();await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
 await page.getByRole('navigation',{name:'Tables'}).getByRole('button',{name:'widgets',exact:true}).click();await views.selectOption(copy);await expect(views).toHaveValue(copy);
 await settings.click();
 await page.getByText('Row actions (5)',{exact:true}).click();await expect(page.getByLabel('Button label')).toHaveCount(5);
 await page.getByText('Today',{exact:true}).click();await expect(page.getByLabel('Today timezone')).toHaveValue('America/New_York');
 await page.keyboard.press('Escape');
 // The any-of status group shows as one Status chip with both options checked.
 await page.getByRole('group',{name:'Sort and filters'}).getByRole('button',{name:/^Status/}).click();
 const editor=page.getByRole('dialog',{name:'Edit filter'});
 await expect(editor.getByRole('checkbox',{name:'Open'})).toBeChecked();await expect(editor.getByRole('checkbox',{name:'Pending'})).toBeChecked();
 await page.keyboard.press('Escape');
 console.log('PASS: reopen preserves action identities, grouped filters and timezone');
}finally{
 await page.clock.resume();
 await page.clock.setSystemTime(new Date());
 await page.goto(new URL('/',url).href);
 await browser.close();server.stop(true);db.db.close();auth.db.close();
}
