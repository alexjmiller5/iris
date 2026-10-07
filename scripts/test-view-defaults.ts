import { expect } from '@playwright/test';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin } from './test-origin';
import { sourceNavigationCDP, element, named, js } from './source-navigation-cdp';
const source=process.argv[2];
if(!source)throw Error('Provide matching life-data source');
const url=process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-navigation.localhost:5274/workspace?review';
const origin=disposableOrigin(url);
expect(await Bun.file(`${source}/core/contract/core.json`).text()).toBe(await Bun.file(new URL('../packages/core/contract/core.json',import.meta.url)).text());
const {server,db,auth}=await regressionHub(source,origin);
let page:Awaited<ReturnType<typeof sourceNavigationCDP>>|undefined;
try {
 for(const ddl of ['ALTER TABLE catalog_properties ADD COLUMN source TEXT','ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT']){
  db.db.exec(ddl);db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z',ddl);
 }
 for(const name of ['saved-views','view-defaults']){
  const storage=await Bun.file(`${source}/core/schema/${name}.json`).json();
  for(const ddl of storage.ddl){db.db.exec(ddl);db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z',ddl);}
  for(const [table,rows] of [['catalog_tables',[storage.table]],['catalog_properties',storage.properties]] as const)for(const row of rows){
   const keys=Object.keys(row);db.db.query(`INSERT INTO ${table}(${keys.join(',')}) VALUES (${keys.map(()=>'?').join(',')})`).run(...Object.values(row));
  }
 }
 db.db.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)').run('preferred-opaque','Z chosen','widgets',JSON.stringify({version:1,filters:[{column:'id',op:'eq',value:'fixture-record'}]}));
 db.db.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)').run('other-opaque','A all','widgets',JSON.stringify({version:1}));
 page=await sourceNavigationCDP(url);const cdp=page;
 const button=(name:string)=>named('button',name);
 const click=(name:string)=>cdp.click(button(name));
 const select=element('select[aria-label="View"]');
 const choose=async(id:string)=>{await cdp.until(`!!(${select})&&!(${select}).disabled && [...(${select}).options].some(o=>o.value===${js(id)})`);await cdp.evaluate(`(()=>{const e=${select};e.value=${js(id)};e.dispatchEvent(new Event('change',{bubbles:true}));})()`);};
 const waitSelected=(id:string)=>cdp.until(`(${select})?.value===${js(id)}`);
 await cdp.navigate(new URL('/',url).href);await cdp.command('Storage.clearDataForOrigin',{origin,storageTypes:'all'});await cdp.navigate(url);
 await click('Open my workspace');
 for(const label of ['Connect to a hub','Use a device token']){const control=named('button,summary',label);await cdp.until(`!!(${control})`);if(!(await cdp.evaluate(`(${control}).closest('details').open`)))await cdp.click(control);}
 const input=(label:string)=>`(()=>{const e=${named('label',label)};return e?.control??e?.querySelector('input');})()`;
 await cdp.fill(input('Hub address'),server.url.href.replace(/\/$/,''));await cdp.fill(input('Device token'),'fixture');await click('Sync now');
 await cdp.until(`!!(${button('New record')})&&!(${button('New record')}).disabled`);
 const table=(id:string)=>named('button',id,element('nav[aria-label="Tables"]'));
 const openTable=async(id:string)=>{await cdp.click(table(id));await cdp.until(`!!(${named('h1',id)})`);};
 await openTable('widgets');await waitSelected('');
 await choose('preferred-opaque');await waitSelected('preferred-opaque');
 await click('Use current view by default');
 await cdp.until("document.body.innerText.includes('Default view saved.')");
 await openTable('views');await openTable('widgets');await waitSelected('preferred-opaque');
 await cdp.until("document.querySelector('[aria-label=\"Records\"]')?.innerText.includes('Fixture record')===true && document.querySelector('[aria-label=\"Records\"]')?.innerText.includes('Second record')===false");
 await click('Sync now');
 await expect.poll(()=>db.db.query('SELECT view_id FROM view_defaults WHERE tbl=? AND deleted_at IS NULL').get('widgets')?.view_id).toBe('preferred-opaque');
 // An explicit view wins over the persisted pointer, including after an OPFS reopen.
 await cdp.navigate(new URL('/workspace?table=widgets&view=other-opaque',url).href);await click('Open my workspace');await waitSelected('other-opaque');
 // Unsaved search must survive a real OPFS reopen without modifying either saved definition.
 const priorViews=db.db.query('SELECT id,definition FROM views ORDER BY id').all();
 await cdp.fill(element('input[aria-label="Search records"]'),'Second record');
 await cdp.until("JSON.parse(new URL(location.href).searchParams.get('state')??'{}').search==='Second record'");
 await cdp.until("document.querySelector('[aria-label=\"Records\"]')?.innerText.includes('Second record')===true && document.querySelector('[aria-label=\"Records\"]')?.innerText.includes('Fixture record')===false");
 const transientLink=await cdp.evaluate<string>('location.href');
 await cdp.navigate(transientLink);await click('Open my workspace');await waitSelected('other-opaque');
 await cdp.until("document.querySelector('input[aria-label=\"Search records\"]')?.value==='Second record'");
 await cdp.until("document.querySelector('[aria-label=\"Records\"]')?.innerText.includes('Second record')===true && document.querySelector('[aria-label=\"Records\"]')?.innerText.includes('Fixture record')===false");
 expect(db.db.query('SELECT id,definition FROM views ORDER BY id').all()).toEqual(priorViews);
 console.log('PASS transient URL search, explicit saved identity, OPFS reopen, preferred-view precedence and unchanged saved rows.');
 await cdp.navigate(new URL('/workspace?table=widgets',url).href);await click('Open my workspace');await waitSelected('preferred-opaque');
 await click('Delete view');await click('Confirm delete');
 await openTable('views');await openTable('widgets');await waitSelected('');
 await cdp.until("document.body.innerText.includes('preferred view is unavailable')");
 await click('Use catalog default');await cdp.until("document.body.innerText.includes('Default view saved.')");
 await openTable('views');await openTable('widgets');await waitSelected('');
 expect(await cdp.evaluate("document.body.innerText.includes('preferred view is unavailable')")).toBe(false);
 console.log('PASS preferred ID persistence, table navigation, explicit destination, OPFS reopen, deleted-target fallback, and clear through real Worker/core.');
} catch(error) { if(page)console.error(await page.evaluate("document.body.innerText"));throw error;
} finally {
 if(page){await page.navigate(new URL('/',url).href).catch(()=>{});await page.command('Storage.clearDataForOrigin',{origin,storageTypes:'all'}).catch(()=>{});page.close();}
 server.stop(true);db.db.close();auth.db.close();
}
