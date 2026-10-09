import { expect } from '@playwright/test';
import { installCoreSchemas, regressionHub } from './workspace-regression-hub';
import { disposableOrigin } from './test-origin';
import { sourceNavigationCDP, element, named, js } from './source-navigation-cdp';
// Preferred table views through the View settings menu: set, sync, reopen, explicit
// view links, a deleted preferred view's notice, and clearing it.
// LIFE_UI_TEST_TARGET is the owned page's CDP target ID (already on the fixture origin).
const url=process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-navigation.localhost:5274/workspace?review';
const origin=disposableOrigin(url);
const source=process.argv[2];
if(!source)throw Error('Provide matching life-data source');
expect(await Bun.file(`${source}/core/contract/core.json`).text()).toBe(await Bun.file(new URL('../packages/core/contract/core.json',import.meta.url)).text());
const {server,db,auth}=await regressionHub(source,origin);
let page:Awaited<ReturnType<typeof sourceNavigationCDP>>|undefined;
try {
 await installCoreSchemas(db,source,['saved-views','view-defaults']);
 db.db.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)').run('preferred-opaque','Z chosen','widgets',JSON.stringify({version:1,filters:[{column:'id',op:'eq',value:'fixture-record'}]}));
 db.db.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)').run('other-opaque','A all','widgets',JSON.stringify({version:1}));
 page=await sourceNavigationCDP(url);const cdp=page;
 // Background tabs throttle rendering and the 2 s sync loop.
 await cdp.command('Page.bringToFront');
 await cdp.command('Emulation.setDeviceMetricsOverride',{width:1280,height:900,deviceScaleFactor:1,mobile:false});
 const button=(name:string)=>named('button',name);
 const click=(name:string)=>cdp.click(button(name));
 const select=element('select[aria-label="View"]');
 const choose=async(id:string)=>{await cdp.until(`!!(${select})&&!(${select}).disabled && [...(${select}).options].some(o=>o.value===${js(id)})`);await cdp.evaluate(`(()=>{const e=${select};e.value=${js(id)};e.dispatchEvent(new Event('change',{bubbles:true}));})()`);};
 const waitSelected=(id:string)=>cdp.until(`(${select})?.value===${js(id)}`);
 // Every table opens on a real saved view; without a preference it is the catalog default.
 const catalogDefault=`catalog-default:v1:${Buffer.from('widgets').toString('hex')}`;
 const notice="The preferred view is unavailable for this table. Showing the catalog default.";
 const records=(text:string)=>`document.querySelector('[aria-label="Records"]')?.innerText.includes(${js(text)})`;
 const settings=async(name:string)=>{
  if(!(await cdp.evaluate(`!!document.querySelector('[role="dialog"][aria-label="View settings"]:popover-open')`)))await click('View settings');
  await click(name);
 };
 // A click before hydration does nothing; retry until the personal workspace shell is up.
 const enter=()=>expect.poll(async()=>(await cdp.evaluate(`!!document.querySelector('#hub-connect')`))||(await click('Open my workspace').then(()=>false,()=>false)),{timeout:60000}).toBe(true);
 await cdp.navigate(new URL('/',url).href);await cdp.command('Storage.clearDataForOrigin',{origin,storageTypes:'all'});await cdp.navigate(url);
 await enter();
 for(const label of ['Connect to a hub','Use a device token']){const control=named('button,summary',label);await cdp.until(`!!(${control})`);if(!(await cdp.evaluate(`(${control}).closest('details').open`)))await cdp.click(control);}
 const input=(label:string)=>`(()=>{const e=${named('label',label)};return e?.control??e?.querySelector('input');})()`;
 await cdp.fill(input('Hub address'),server.url.href.replace(/\/$/,''));await cdp.fill(input('Device token'),'fixture');await click('Connect');
 await cdp.until(`!!(${button('New record')})&&!(${button('New record')}).disabled`);
 const table=(id:string)=>named('button',id,element('nav[aria-label="Tables"]'));
 const openTable=async(id:string)=>{await cdp.click(table(id));await cdp.until(`!!(${named('h1',id)})`);};
 await openTable('widgets');await waitSelected(catalogDefault);
 await choose('preferred-opaque');await waitSelected('preferred-opaque');
 await settings('Use current view by default');
 await cdp.until("document.body.innerText.includes('Default view saved.')");
 await openTable('views');await openTable('widgets');await waitSelected('preferred-opaque');
 await cdp.until(`${records('Fixture record')}===true && ${records('Second record')}===false`);
 await expect.poll(()=>(db.db.query('SELECT view_id FROM view_defaults WHERE tbl=? AND deleted_at IS NULL').get('widgets') as any)?.view_id,{timeout:15000}).toBe('preferred-opaque');
 // An explicit view wins over the persisted pointer, including after an OPFS reopen.
 await cdp.navigate(new URL('/workspace?table=widgets&view=other-opaque',url).href);await enter();await waitSelected('other-opaque');
 await cdp.until(`${records('Second record')}===true`);
 await cdp.navigate(new URL('/workspace?table=widgets',url).href);await enter();await waitSelected('preferred-opaque');
 console.log('PASS preferred view set from View settings, synced pointer, table navigation, explicit view link precedence and OPFS reopen.');
 await settings('Delete view');await click('Confirm delete');
 await waitSelected(catalogDefault);
 await cdp.until(`document.body.innerText.includes(${js(notice)})`);
 await openTable('views');await openTable('widgets');await waitSelected(catalogDefault);
 await cdp.until(`document.body.innerText.includes(${js(notice)})`);
 await settings('Use catalog default');await cdp.until("document.body.innerText.includes('Default view saved.')");
 await openTable('views');await openTable('widgets');await waitSelected(catalogDefault);
 expect(await cdp.evaluate(`document.body.innerText.includes(${js(notice)})`)).toBe(false);
 console.log('PASS deleted preferred view falls back to the catalog default with a notice, and Use catalog default clears it through real Worker/core.');
} catch(error) { if(page)console.error(await page.evaluate("document.body.innerText"));throw error;
} finally {
 if(page){await page.command('Emulation.clearDeviceMetricsOverride').catch(()=>{});await page.navigate(new URL('/',url).href).catch(()=>{});await page.command('Storage.clearDataForOrigin',{origin,storageTypes:'all'}).catch(()=>{});page.close();}
 server.stop(true);db.db.close();auth.db.close();
}
