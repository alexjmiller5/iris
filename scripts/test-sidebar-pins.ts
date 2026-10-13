import { expect } from '@playwright/test';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { sourceNavigationCDP, named, element } from './source-navigation-cdp';
import { disposableOrigin } from './test-origin';
import { regressionHub } from './workspace-regression-hub';

const address = process.env.IRIS_TEST_URL;
const source = process.argv[2];
if (!address || !source || !process.env.IRIS_TEST_TARGET)
  throw Error('Set an owned IRIS_TEST_URL / IRIS_TEST_TARGET and pass a matching core checkout');
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
  await cdp.navigate(new URL("/favicon.svg", address).href);
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
    await cdp.click(named('button', 'Connect'));
    await cdp.until(`!!(${named('button', 'Connect')}) && !(${named('button', 'Connect')}).disabled`);
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
  const artifacts=process.env.IRIS_TEST_ARTIFACT_DIR;
  async function shot(name: string) {
    if (!artifacts) return;
    mkdirSync(artifacts,{recursive:true});
    const image=await cdp.command('Page.captureScreenshot',{format:'png'});
    await Bun.write(resolve(artifacts,name),Buffer.from(image.data,'base64'));
  }
  const centre = (selector: string) => cdp.evaluate(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,h:r.height};})()`);
  const mouse = (type: string, x: number, y: number, button = 'left', buttons = 1) =>
    cdp.command('Input.dispatchMouseEvent', { type, x, y, button, buttons, clickCount: 1 });
  const menuOpen = `!!document.querySelector('[role="menu"][aria-label^="Pin actions"]')?.matches(':popover-open')`;
  await cdp.click(named('button', 'Fixture record'));
  await cdp.fill(element('input[aria-label="Title"]'), 'Unsent pin fixture');
  // Drag the projects handle above widgets: the row follows the pointer, then the
  // acknowledged order replaces it.
  const handle = (table: string) => `[data-pin-table="${table}"] .handle`;
  const from = await centre(handle('projects'));
  await mouse('mouseMoved', from.x, from.y, 'none', 0);
  await mouse('mousePressed', from.x, from.y);
  for (const step of [8, 20, 34, 46]) await mouse('mouseMoved', from.x, from.y - step);
  expect(await cdp.evaluate(`getComputedStyle(document.querySelector('[data-pin-table="projects"]')).transform`)).not.toBe('none');
  await shot('sidebar-pins-drag.png');
  await mouse('mouseReleased', from.x, from.y - 46, 'left', 0);
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['projects', 'widgets']);
  expect(await cdp.evaluate(`document.querySelector('input[aria-label="Title"]').value`)).toBe('Unsent pin fixture');
  // Keyboard: Alt+Arrow moves the focused pin, announces it and keeps focus on its handle.
  await cdp.evaluate(`document.querySelector(${JSON.stringify(handle('projects'))}).focus()`);
  await cdp.key('ArrowDown', 1);
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['widgets', 'projects']);
  await cdp.until(`document.querySelector('[aria-live="polite"]')?.textContent === 'projects moved to position 2 of 2.'`);
  await cdp.until(`document.activeElement?.getAttribute('aria-label') === 'Reorder projects'`);
  await cdp.key('ArrowUp', 1);
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['projects', 'widgets']);
  await cdp.until(`document.activeElement?.getAttribute('aria-label') === 'Reorder projects'`);
  // Shift+F10 opens the pin menu from the keyboard; Escape returns focus.
  await cdp.key('F10', 8);
  await cdp.until(menuOpen);
  await cdp.until(`document.activeElement?.getAttribute('role') === 'menuitem'`);
  await cdp.key('Escape');
  await cdp.until(`!(${menuOpen})`);
  await cdp.until(`document.activeElement?.getAttribute('aria-label') === 'Reorder projects'`);
  // Autosave stores ordinary typing on leave; a refused value (the required title
  // emptied) asks first, and Cancel keeps it while pins stay usable.
  await cdp.fill(element('input[aria-label="Title"]'), '');
  await cdp.evaluate('document.activeElement?.blur()');
  await cdp.until(`document.querySelector('[aria-label="Record save status"]')?.dataset.state === 'failed'`);
  acceptDiscard=false;
  const beforeNavigationDialogs=dialogs;
  await cdp.click(element('[aria-label="Open pinned projects"]'));
  await expect.poll(()=>dialogs).toBe(beforeNavigationDialogs+1);
  expect(await cdp.evaluate(`document.querySelector('input[aria-label="Title"]').value`)).toBe('');
  // Right-click opens the menu; its Unpin removes the pin.
  const widgets = await centre('[aria-label="Open pinned widgets"]');
  await mouse('mouseMoved', widgets.x, widgets.y, 'none', 0);
  await mouse('mousePressed', widgets.x, widgets.y, 'right', 2);
  await mouse('mouseReleased', widgets.x, widgets.y, 'right', 0);
  await cdp.until(menuOpen);
  await shot('sidebar-pins-menu.png');
  await cdp.click(named('[role="menuitem"]', 'Unpin'));
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['projects']);
  // The last pin write: a sync after it pushes the final order to the hub.
  const pinsResync = await cdp.evaluate("new Date().toISOString()");
  await cdp.click(element('[aria-label="Pin widgets"]'));
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['projects', 'widgets']);
  // A long press opens the same menu and stays open after release, without navigating.
  const dialogsBeforePress = dialogs;
  const press = await centre('[aria-label="Open pinned widgets"]');
  await mouse('mouseMoved', press.x, press.y, 'none', 0);
  await mouse('mousePressed', press.x, press.y);
  await Bun.sleep(700);
  await cdp.until(menuOpen);
  await mouse('mouseReleased', press.x, press.y, 'left', 0);
  await Bun.sleep(150);
  expect(await cdp.evaluate(menuOpen)).toBe(true);
  expect(dialogs).toBe(dialogsBeforePress);
  expect(await cdp.evaluate(`document.querySelector('input[aria-label="Title"]').value`)).toBe('');
  await cdp.key('Escape');
  await cdp.until(`!(${menuOpen})`);
  acceptDiscard=true;
  await cdp.click(element('[aria-label="Open pinned projects"]'));
  await cdp.until(`(document.querySelector('[data-last-sync]')?.getAttribute('data-last-sync') ?? '') > ${JSON.stringify(pinsResync)}`);
  await expect.poll(()=>hub.db.db.query('SELECT tbl FROM sidebar_pins WHERE deleted_at IS NULL ORDER BY position').all()).toEqual([{tbl:'projects'},{tbl:'widgets'}]);
  // The workspace reopens by itself, its pins read from the local replica. The
  // discarded draft's table switch lands first, so no unload prompt races the reopening page.
  await cdp.until("new URL(location.href).searchParams.get('table') === 'projects'");
  await cdp.navigate(address);
  await cdp.until("!!document.querySelector('#svelte-announcer')");
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['projects', 'widgets']);
  // Erase this synthetic replica, then recover the pins from the real service.
  await cdp.navigate(new URL("/favicon.svg", address).href);
  await cdp.command('Storage.clearDataForOrigin',{origin,storageTypes:'all'});
  await cdp.navigate(address);
  await cdp.until("!!document.querySelector('#svelte-announcer')");
  await cdp.click(named('button','Open my workspace'));
  await connect();
  await expect.poll(() => cdp.evaluate(pinned)).toEqual(['projects','widgets']);
  await cdp.evaluate('window.scrollTo(0,0)');
  await shot('sidebar-pins-pass.png');
} catch (error) {
  const artifacts = process.env.IRIS_TEST_ARTIFACT_DIR;
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
      await page.navigate(new URL("/favicon.svg", address).href);
      await page.command('Storage.clearDataForOrigin', { origin, storageTypes: 'all' });
    } finally { page.close(); }
  }
  hub.server.stop(true);
  hub.db.db.close();
  hub.auth.db.close();
}

console.log('PASS: pin, drag and keyboard reorder, menu by right-click, Shift+F10 and long press, unpin/restore, dirty navigation cancellation, reopen, fresh replica sync and cleanup');
