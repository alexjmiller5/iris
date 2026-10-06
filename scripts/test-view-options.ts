import { chromium, expect } from '@playwright/test';
import { resolve } from 'node:path';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin, workspacePage } from './test-origin';

const url = process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-markdown.localhost:5252/workspace?review';
const source = process.argv[2];
if (!source) throw Error('Provide the Life Data source checkout');
const mode = process.argv[3] ?? 'all';
const { server, db, auth } = await regressionHub(source, disposableOrigin(url));
const schema = await Bun.file(resolve(source, 'core/schema/saved-views.json')).json();
for (const ddl of [
  'ALTER TABLE catalog_properties ADD COLUMN source TEXT',
  'ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT',
  'ALTER TABLE widgets ADD COLUMN due TEXT',
  'ALTER TABLE widgets ADD COLUMN done INTEGER',
  'ALTER TABLE widgets ADD COLUMN related TEXT',
  ...schema.ddl
]) {
  db.db.exec(ddl);
  db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z', ddl);
}
for (const [table, records] of [['catalog_tables', [schema.table]], ['catalog_properties', schema.properties]] as const)
  for (const record of records) {
    const columns = Object.keys(record);
    db.db.query(`INSERT INTO ${table} (${columns.map(c => '"' + c + '"').join(',')}) VALUES (${columns.map(() => '?').join(',')})`).run(...Object.values(record));
  }
db.db.exec(`INSERT INTO catalog_properties(id,tbl,col,type,label,ref_table) VALUES
  ('widgets.due','widgets','due','date','Due',NULL),
  ('widgets.done','widgets','done','bool','Done',NULL),
  ('widgets.related','widgets','related','ref','Related','widgets');
  UPDATE widgets SET due='2026-06-01' WHERE id='fixture-record';
  UPDATE widgets SET due='2026-06-02' WHERE id='second-record';`);
db.db.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)').run('late-day', 'Late day', 'widgets', JSON.stringify({
  version: 2, filters: [{ column: 'due', op: 'lte', relative: 'today' }],
  timeZone: 'America/New_York', dayStartMinutes: 180
}));
const browser = await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP ?? 'http://127.0.0.1:9222');
const page = workspacePage(browser.contexts().flatMap(c => c.pages()), url);
if (!page) throw Error('Open the reserved fixture page');
try {
  page.setDefaultTimeout(8000);
  await page.goto(new URL('/', url).href);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Storage.clearDataForOrigin', { origin: new URL(url).origin, storageTypes: 'all' });
  await cdp.detach();
  await page.clock.install({ time: new Date('2026-06-02T06:59:50Z') });
  await page.goto(url);
  await page.getByRole('button', { name: 'Open my workspace', exact: true }).click();
  await page.getByText('Connect to a hub', { exact: true }).click();
  await page.getByText('Use a device token', { exact: true }).click();
  await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/, ''));
  await page.getByLabel('Device token').fill('fixture');
  await page.getByRole('button', { name: 'Sync now', exact: true }).click();
  await page.getByRole('navigation', { name: 'Tables' }).getByRole('button', { name: 'widgets', exact: true }).click();
  const views = page.getByRole('combobox', { name: 'View', exact: true });
  if (mode === 'all' || mode === 'rollover') {
    await views.selectOption('late-day');
    await expect(page.locator('.record-link')).toHaveText(['Fixture record']);
    await page.getByText('Filter groups (0)', { exact: true }).click();
    await expect(page.getByLabel('Day starts at', { exact: true })).toHaveValue('03:00');
    await page.clock.runFor(11000);
    await expect(page.locator('.record-link')).toHaveText(['Fixture record', 'Second record']);
    await page.getByLabel('Day starts at', { exact: true }).fill('04:00');
    await expect(page.locator('.record-link')).toHaveText(['Fixture record']);
    await page.getByLabel('View name', { exact: true }).fill('Boundary copy');
    await page.getByRole('button', { name: 'Save as', exact: true }).click();
    const copied = await views.inputValue();
    expect(copied).not.toBe('late-day');
    await views.selectOption('');
    await expect(page.getByLabel('Day starts at', { exact: true })).toHaveValue('00:00');
    await views.selectOption(copied);
    await expect(page.getByLabel('Day starts at', { exact: true })).toHaveValue('04:00');
    await expect(page.locator('.record-link')).toHaveText(['Fixture record']);
    console.log('PASS: configured rollover, changed-policy refresh, save/reopen and midnight reset');
  }
  if (mode === 'all' || mode === 'options') {
    await views.selectOption('');
    const group = page.locator('details').filter({ has: page.locator('summary', { hasText: /^Filter groups/ }) });
    await group.evaluate(node => (node as HTMLDetailsElement).open = true);
    await page.getByRole('button', { name: 'Add filter group', exact: true }).click();
    await page.getByLabel('Rule property', { exact: true }).selectOption('quantity');
    await expect(page.getByLabel('Rule property', { exact: true })).toHaveValue('quantity');
    await page.getByLabel('Rule condition', { exact: true }).selectOption('eq');
    await page.getByLabel('Rule value', { exact: true }).fill('42');
    await expect(page.locator('.record-link')).toHaveCount(3);
    await page.getByLabel('Rule property', { exact: true }).selectOption('done');
    await expect(page.getByLabel('Rule property', { exact: true })).toHaveValue('done');
    await page.getByRole('button', { name: 'Remove group', exact: true }).click();
    console.log('PASS: numeric and boolean property changes remain editable');
  }
  if (mode === 'all' || mode === 'actions') {
    await views.selectOption('');
    const actions = page.locator('details').filter({ has: page.locator('summary', { hasText: /^Row actions/ }) });
    await actions.evaluate(node => (node as HTMLDetailsElement).open = true);
    await page.getByRole('button', { name: 'Add action', exact: true }).click();
    await page.getByLabel('Add value to action 1').selectOption('status');
    await expect(page.locator('select[id^="action-"][id$="-status"] option[value="Dynamic"]')).toHaveCount(1);
    await page.getByLabel('Add value to action 1').selectOption('tags');
    await expect(page.locator('select[id^="action-"][id$="-tags"] option[value="Dynamic"]')).toHaveCount(1);
    await page.getByLabel('Add value to action 1').selectOption('related');
    await page.getByLabel('Search Related', { exact: true }).fill('Second');
    await expect(page.locator('select[id^="action-"][id$="-related"] option[value="second-record"]')).toHaveCount(1);
    console.log('PASS: row actions load dynamic select/multi-select and reference choices');
  }
} finally {
  await page.clock.resume();
  await page.clock.setSystemTime(new Date());
  await page.goto(new URL('/', url).href);
  await browser.close();
  server.stop(true); db.db.close(); auth.db.close();
}
