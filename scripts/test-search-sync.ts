import { chromium, expect } from '@playwright/test';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin, workspacePage } from './test-origin';

const url = process.env.IRIS_TEST_URL ?? 'http://iris-markdown.localhost:5198/workspace?review';
const source = process.argv[2];
if (!source) throw new Error('Usage: bun scripts/test-search-sync.ts <soma-checkout>');
const origin = disposableOrigin(url);
const { server, db } = await regressionHub(source, origin);
// A second catalogued table with a different display column catches navigation
// that opens the right ID using the previous table's property definitions.
const ddl = `CREATE TABLE journals (id TEXT PRIMARY KEY NOT NULL,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT,headline TEXT,body TEXT)`;
db.db.exec(ddl);
db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z', ddl);
db.db.exec(`INSERT INTO catalog_tables(id,kind,display,purpose) VALUES ('journals','table','headline','Synthetic search records');
 INSERT INTO catalog_properties(id,tbl,col,label,sort,type) VALUES
 ('journals.headline','journals','headline','Headline',0,'text'),
 ('journals.body','journals','body','Body',1,'markdown');
 INSERT INTO journals(id,headline,body,updated_at,hub_at) VALUES
 ('journal-1','Field guide','# Celestial observations','2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z');`);
const browser = await chromium.connectOverCDP(process.env.IRIS_TEST_CDP ?? 'http://127.0.0.1:9222');
try {
 const page = workspacePage(browser.contexts().flatMap(c => c.pages()), url);
 if (!page) throw new Error('Open the reserved search review page');
 page.setDefaultTimeout(8000);
 page.on('dialog', d => d.accept());
 await page.goto(new URL('/', url).href);
 const cdp = await page.context().newCDPSession(page);
 await cdp.send('Storage.clearDataForOrigin', {origin, storageTypes:'all'});
 await cdp.detach();
 await page.goto(url);
 await page.getByRole('button', {name:'Open my workspace', exact:true}).click();
 await page.getByText('Connect to a hub', {exact:true}).click();await page.getByText('Use a device token', {exact:true}).click();
 await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/, ''));
 await page.getByLabel('Device token').fill('fixture');
 const sync = page.getByRole('button', {name:'Connect', exact:true});
 await sync.click();
 await expect(page.getByRole('button', {name:'Find records'})).toBeEnabled({timeout:15000});
 await page.getByRole('button', {name:'widgets', exact:true}).click();
 await expect(page.getByRole('button', {name:'Fixture record', exact:true})).toBeVisible();
 await page.keyboard.press('Control+k');
 const search = page.getByRole('dialog', {name:'Find records', exact:true});
 const input = search.getByRole('combobox', {name:'Search records', exact:true});
 await input.fill('celest');
 const result = search.getByRole('option').filter({hasText:'Field guide'});
 await expect(result).toContainText('journals');
 await result.click();
 await expect(page.getByRole('heading', {name:'journals', exact:true})).toBeVisible();
 await expect(page.getByRole('textbox', {name:'Headline', exact:true})).toHaveValue('Field guide');
 await page.getByRole('button', {name:'Close record', exact:true}).click();
 // A remote update must invalidate the durable local index on the next pull.
 db.db.query('UPDATE journals SET body=?,updated_at=?,hub_at=? WHERE id=?').run('# Oceanic observations','2026-01-02T00:00:00.000Z','2026-01-02T00:00:00.000Z','journal-1');
 await sync.click();
 await expect(sync).toBeEnabled();
 await page.keyboard.press('Meta+k');
 await input.fill('ocean');
 await expect(result).toBeVisible();
 await input.fill('celest');
 await expect(search).toContainText('No matches.');
 await expect(search.getByRole('option')).toHaveCount(0);
 await page.keyboard.press('Escape');
 await page.getByRole('button', {name:'Field guide', exact:true}).click();
 await page.getByRole('button', {name:'Move to trash', exact:true}).click();
 await expect(sync).toBeEnabled();
 await page.keyboard.press('Meta+k');
 await input.fill('ocean');
 await expect(search).toContainText('No matches.');
 await expect(search.getByRole('option')).toHaveCount(0);
 await page.keyboard.press('Escape');
 console.log('PASS: search crosses table schemas, reindexes sync pulls and excludes trash');
} finally {
 await browser.close();
 server.stop(true);
 db.db.close();
}
