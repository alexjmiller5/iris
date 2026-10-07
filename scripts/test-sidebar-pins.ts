import { expect } from '@playwright/test';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { sourceNavigationCDP, named, element } from './source-navigation-cdp';
import { disposableOrigin } from './test-origin';
import { regressionHub } from './workspace-regression-hub';

const address = process.env.LIFE_UI_TEST_URL;
const source = process.argv[2];
if (!address || !source || !process.env.LIFE_UI_TEST_TARGET)
  throw Error('Set an owned LIFE_UI_TEST_URL / LIFE_UI_TEST_TARGET and pass a matching core checkout');
const origin = disposableOrigin(address);
const root = resolve(import.meta.dir, '..');
if (!readFileSync(resolve(root, 'packages/core/contract/core.json')).equals(
  readFileSync(resolve(source, 'core/contract/core.json'))))
  throw Error('UI and synthetic service core contracts must match');
const hub = await regressionHub(source, origin);
let acceptDiscard=true,dialogs=0;
let page: Awaited<ReturnType<typeof sourceNavigationCDP>> | undefined;
try {
  const ddls = [
    'ALTER TABLE catalog_properties ADD COLUMN source TEXT',
    'ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT',
    'CREATE TABLE projects(id TEXT PRIMARY KEY, title TEXT, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT)',
  ];
  const manifestPath = resolve(root, 'packages/core/schema/sidebar-pins.json');
  // The pre-implementation RED has no packaged manifest. After implementation
  // the real service fixture receives exactly the canonical product schema.
  const manifest = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, 'utf8')) : null;
  if (manifest) ddls.push(...manifest.ddl);
  for (const ddl of ddls) {
    hub.db.db.exec(ddl);
    hub.db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z', ddl);
  }
  hub.db.db.exec("INSERT INTO catalog_tables(id,kind,display) VALUES ('projects','table','title')");
  hub.db.db.exec("INSERT INTO catalog_properties(id,tbl,col,type) VALUES ('projects.title','projects','title','text')");
  if (manifest) for (const [table, rows] of [
    ['catalog_tables', [manifest.table]], ['catalog_properties', manifest.properties],
  ] as const) for (const row of rows) {
    const columns = Object.keys(row);
    hub.db.db.query(`INSERT INTO ${table} (${columns.map(c => '"' + c + '"').join(',')}) VALUES (${columns.map(() => '?').join(',')})`)
      .run(...Object.values(row));
  }
  page = await sourceNavigationCDP(address);
  const cdp = page;
  cdp.on('Page.javascriptDialogOpening',()=>{dialogs++;void cdp.command('Page.handleJavaScriptDialog',{accept:acceptDiscard});});
  await cdp.command('Page.handleJavaScriptDialog',{accept:true}).catch(()=>{});
  await cdp.command('Page.addScriptToEvaluateOnNewDocument',{source:`
    window.pinTrace=[];
    const add=(kind,value)=>{window.pinTrace.push({at:performance.now(),kind,value});if(window.pinTrace.length>200)window.pinTrace.shift();};
    window.addEventListener('focus',()=>add('focus',document.visibilityState));
    document.addEventListener('click',event=>{const b=event.target.closest?.('button');if(b)add('click',b.getAttribute('aria-label')||b.textContent.trim());},true);
    const WorkerBase=window.Worker;
    window.Worker=class extends WorkerBase {postMessage(request,...rest){add('request',request.method);return super.postMessage(request,...rest);}};
  `});
  await cdp.command('Page.bringToFront');
  await cdp.navigate(new URL('/', address).href);
  await cdp.command('Storage.clearDataForOrigin', { origin, storageTypes: 'all' });
  await cdp.navigate(address);
  await cdp.until("!!document.querySelector('#svelte-announcer')");
  await cdp.click(named('button', 'Open my workspace'));
  const input = (label: string) => `(${named('label', label)})?.control`;
  async function connect() {
    await cdp.click(named('button,summary', 'Connect to a hub'));
    await cdp.click(named('button,summary', 'Use a device token'));
    await cdp.fill(input('Hub address'), hub.server.url.href.replace(/\/$/, ''));
    await cdp.fill(input('Device token'), 'fixture');
    await cdp.click(named('button', 'Sync now'));
    await cdp.until(`!!(${named('button', 'Sync now')}) && !(${named('button', 'Sync now')}).disabled`);
  }
  await connect();
  await cdp.click(named('nav[aria-label="Tables"] button', 'widgets'));
  await cdp.until(`!!(${named('button', 'Fixture record')})`, 'Synced fixture is mounted');
  await cdp.click(element('[aria-label="Pin widgets"]'));
  await cdp.click(element('[aria-label="Pin projects"]'));
  const pinned = `Array.from(document.querySelectorAll('[aria-label="Pinned tables"] [data-pin-table]')).map(e=>e.getAttribute('data-pin-table'))`;
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['widgets', 'projects']);
  expect(await cdp.evaluate(`!!document.querySelector('[aria-label="Recent destinations"]') && !!(document.querySelector('[aria-label="Recent destinations"]').compareDocumentPosition(document.querySelector('[aria-label="Pinned tables"]')) & Node.DOCUMENT_POSITION_FOLLOWING)`)).toBe(true);
  expect(await cdp.evaluate(`Array.from(document.querySelectorAll('nav[aria-label="Tables"] button')).some(e=>['widgets','projects'].includes(e.textContent.trim()))`)).toBe(false);
  const focusReads=await cdp.evaluate("window.pinTrace.filter(e=>e.kind==='request'&&e.value==='listSidebarPins').length");
  await cdp.evaluate("new Promise(resolve=>{window.dispatchEvent(new Event('focus'));requestAnimationFrame(()=>requestAnimationFrame(resolve));})");
  expect(await cdp.evaluate("window.pinTrace.filter(e=>e.kind==='request'&&e.value==='listSidebarPins').length")).toBe(focusReads);
  await cdp.click(named('button', 'Fixture record'));
  await cdp.fill(element('input[aria-label="Title"]'), 'Unsent pin fixture');
  await cdp.click(element('[aria-label="Move projects up"]'));
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['projects', 'widgets']);
  expect(await cdp.evaluate(`document.querySelector('input[aria-label="Title"]').value`)).toBe('Unsent pin fixture');
  acceptDiscard=false;
  const beforeNavigationDialogs=dialogs;
  await cdp.click(element('[aria-label="Open pinned projects"]'));
  await expect.poll(()=>dialogs).toBe(beforeNavigationDialogs+1);
  expect(await cdp.evaluate(`document.querySelector('input[aria-label="Title"]').value`)).toBe('Unsent pin fixture');
  await cdp.click(element('[aria-label="Unpin widgets"]'));
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['projects']);
  await cdp.click(element('[aria-label="Pin widgets"]'));
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['projects', 'widgets']);
  acceptDiscard=true;
  await cdp.click(element('[aria-label="Open pinned projects"]'));
  await cdp.click(named('button','Sync now'));
  await expect.poll(()=>hub.db.db.query('SELECT tbl FROM sidebar_pins WHERE deleted_at IS NULL ORDER BY position').all()).toEqual([{tbl:'projects'},{tbl:'widgets'}]);
  await cdp.navigate(address);
  await cdp.until("!!document.querySelector('#svelte-announcer')");
  await cdp.click(named('button', 'Open my workspace'));
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['projects', 'widgets']);
  // Erase this synthetic replica, then recover the pins from the real service.
  await cdp.navigate(new URL('/',address).href);
  await cdp.command('Storage.clearDataForOrigin',{origin,storageTypes:'all'});
  await cdp.navigate(address);
  await cdp.until("!!document.querySelector('#svelte-announcer')");
  await cdp.click(named('button','Open my workspace'));
  await connect();
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['projects','widgets']);
  await cdp.evaluate('window.scrollTo(0,0)');
  const artifacts=process.env.LIFE_UI_TEST_ARTIFACT_DIR;
  if(artifacts){mkdirSync(artifacts,{recursive:true});const shot=await cdp.command('Page.captureScreenshot',{format:'png'});await Bun.write(resolve(artifacts,'sidebar-pins-pass.png'),Buffer.from(shot.data,'base64'));}
} catch (error) {
  const artifacts = process.env.LIFE_UI_TEST_ARTIFACT_DIR;
  if (page && artifacts) {
    mkdirSync(artifacts, { recursive: true });
    await Bun.write(resolve(artifacts, 'sidebar-pins.txt'), await page.evaluate('document.body.innerText'));
    await Bun.write(resolve(artifacts,'pin-trace.json'),JSON.stringify(await page.evaluate('window.pinTrace'),null,2));
    const shot = await page.command('Page.captureScreenshot', { format: 'png' });
    await Bun.write(resolve(artifacts, 'sidebar-pins.png'), Buffer.from(shot.data, 'base64'));
  }
  throw error;
} finally {
  if (page) {
    acceptDiscard=true;
    try {
      await page.navigate(new URL('/', address).href);
      await page.command('Storage.clearDataForOrigin', { origin, storageTypes: 'all' });
    } finally { page.close(); }
  }
  hub.server.stop(true);
  hub.db.db.close();
  hub.auth.db.close();
}

console.log('PASS: pin/order/unpin/restore, dirty navigation cancellation, reopen, fresh replica sync and cleanup');
