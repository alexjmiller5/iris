import { expect } from '@playwright/test';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin } from './test-origin';
import { sourceNavigationCDP, element, named, js } from './source-navigation-cdp';
const source=process.argv[2];
if(!source)throw Error('Provide the matching Life Data source');
const url=process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-catalog.localhost:5282/workspace?review';
const origin=disposableOrigin(url);
expect(await Bun.file(`${source}/core/contract/core.json`).text()).toBe(await Bun.file(new URL('../packages/core/contract/core.json',import.meta.url)).text());
const {server,db,auth}=await regressionHub(source,origin);
let page:Awaited<ReturnType<typeof sourceNavigationCDP>>|undefined;
try {
 const storage=await Bun.file(`${source}/core/schema/catalog-log.json`).json();
 for(const ddl of ['ALTER TABLE catalog_properties ADD COLUMN source TEXT','ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT',...storage.ddl]){
  db.db.exec(ddl);db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z',ddl);
 }
 for(const [table,rows] of [['catalog_tables',[storage.table]],['catalog_properties',storage.properties]] as const)for(const row of rows){
  const keys=Object.keys(row);db.db.query(`INSERT INTO ${table}(${keys.join(',')}) VALUES (${keys.map(()=>'?').join(',')})`).run(...Object.values(row));
 }
 page=await sourceNavigationCDP(url);const cdp=page;
 await cdp.command('Emulation.setDeviceMetricsOverride',{width:1440,height:1100,deviceScaleFactor:1,mobile:false});
 const button=(name:string)=>named('button',name);
 const click=(name:string)=>cdp.click(button(name));
 const field=(label:string)=>element(`[aria-label=${JSON.stringify(label)}]`);
 const select=async(label:string,value:string)=>{
  const target=field(label);await cdp.until(`!!(${target})`);
  await cdp.evaluate(`(()=>{const e=${target};e.value=${js(value)};e.dispatchEvent(new Event('change',{bubbles:true}));})()`);
 };
 const has=(text:string)=>cdp.until(`document.body.innerText.includes(${js(text)})`);
 await cdp.navigate(new URL('/',url).href);await cdp.command('Storage.clearDataForOrigin',{origin,storageTypes:'all'});await cdp.navigate(url);
 await click('Open my workspace');
 for(const label of ['Connect to a hub','Use a device token']){
  const control=named('button,summary',label);await cdp.until(`!!(${control})`);
  if(!(await cdp.evaluate(`(${control}).closest('details').open`)))await cdp.click(control);
 }
 const input=(label:string)=>`(()=>{const e=${named('label',label)};return e?.control??e?.querySelector('input');})()`;
 await cdp.fill(input('Hub address'),server.url.href.replace(/\/$/,''));await cdp.fill(input('Device token'),'fixture');
 const sync=async()=>{await click('Sync now');await cdp.until(`!!(${button('Sync now')})&&!(${button('Sync now')}).disabled`);};
 await sync();await cdp.until(`!!(${button('New record')})&&!(${button('New record')}).disabled`);
 await click('Edit catalog');await click('Status');await click('Add option');
 await cdp.fill(field('Option 1 value'),'Ready');await cdp.fill(field('Option 1 description'),'Reviewed and ready');await click('Save property');await has('Saved to the catalog and its change log.');
 await click('Add property');await cdp.fill(field('Property ID'),'review_score');await select('Property type','number');await cdp.fill(field('Property description'),'Synthetic review score');await click('Save property');await has('Saved to the catalog and its change log.');
 await click('Close catalog');await sync();await click('Edit catalog');await click('Rules');await click('Add rule');await cdp.fill(field('Rule ID'),'nonnegative');await cdp.fill(field('Rule guidance'),'Quantity cannot be negative.');await select('Rule kind','invariant');await cdp.fill(field('Rule SQL'),'SELECT * FROM missing_table');
 await cdp.click(`Array.from(document.querySelectorAll('label')).find(e=>e.textContent.replace(/\\s+/g,' ').includes('Reject record writes that violate this invariant'))?.querySelector('input')`);
 await click('Save rule');await cdp.until(`!!(${element('[role="alert"]')})`);
 expect(await cdp.evaluate(`(${field('Rule SQL')}).value`)).toBe('SELECT * FROM missing_table');
 expect(await cdp.evaluate(`(${field('Rule guidance')}).value`)).toBe('Quantity cannot be negative.');
 await cdp.fill(field('Rule SQL'),'SELECT id FROM changed WHERE quantity < 0');await click('Save rule');await has('Saved to the catalog and its change log.');await click('Close catalog');
 // New logged DDL invalidates old coverage. Real sync must reestablish it before ordinary writes.
 await sync();
 await expect.poll(()=>db.db.query('SELECT count(*) AS n FROM catalog_log').get()?.n).toBe(3);
 expect(JSON.parse(String(db.db.query("SELECT options FROM catalog_properties WHERE col='status'").get()?.options))[0].d).toBe('Reviewed and ready');
 expect(db.db.query('PRAGMA table_info(widgets)').all().some((r:any)=>r.name==='review_score')).toBe(true);
 await click('Fixture record');await cdp.fill(element('#field-quantity'),'-1');await click('Save record');await has('Quantity cannot be negative.');
 expect(await cdp.evaluate(`(${element('#field-quantity')}).value`)).toBe('-1');
 expect(db.db.query("SELECT quantity FROM widgets WHERE id='fixture-record'").get()?.quantity).toBe(42);
 await cdp.fill(element('#field-quantity'),'43');await click('Save record');await has('Saved on this device');await click('Close record');await sync();
 await expect.poll(()=>db.db.query("SELECT quantity FROM widgets WHERE id='fixture-record'").get()?.quantity).toBe(43);
 console.log('PASS catalog property/options/column/rule editing, failed-rule draft retention, catalog_log hub readback, coverage refresh, actual rule failure and corrected record save.');
} catch(error) {if(page)console.error(await page.evaluate('document.body.innerText'));throw error;}
finally {
 if(page){await page.navigate(new URL('/',url).href).catch(()=>{});await page.command('Storage.clearDataForOrigin',{origin,storageTypes:'all'}).catch(()=>{});page.close();}
 server.stop(true);db.db.close();auth.db.close();
}
