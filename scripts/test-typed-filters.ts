import { chromium, expect } from '@playwright/test';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin, workspacePage } from './test-origin';

const url = process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-markdown.localhost:5198/workspace?review';
const origin = disposableOrigin(url);
const { server, db } = await regressionHub(process.argv[2], origin);
const ddl = 'ALTER TABLE widgets ADD COLUMN active INTEGER';
db.db.exec(ddl);
db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z', ddl);
db.db.exec(`INSERT INTO catalog_properties(id,tbl,col,label,sort,type) VALUES ('widgets.active','widgets','active','Active',5,'bool');
 UPDATE widgets SET active=1 WHERE id='fixture-record';
 UPDATE widgets SET active=0 WHERE id='second-record';`);
const browser = await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP ?? 'http://127.0.0.1:9222');
try {
 const page = workspacePage(browser.contexts().flatMap(c => c.pages()), url);
 if (!page) throw Error('Open the reserved review page first.');
 page.setDefaultTimeout(5000);
 await page.setViewportSize({width:1280,height:960});
 await page.goto(new URL('/',url).href);
 const cdp=await page.context().newCDPSession(page);
 await cdp.send('Storage.clearDataForOrigin',{origin,storageTypes:'all'}); await cdp.detach();
 await page.goto(url);
 await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
 await page.getByText('Connect to a hub',{exact:true}).click();await page.getByText('Use a device token', {exact:true}).click();
 await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/,''));
 await page.getByLabel('Device token').fill('fixture');
 await page.getByRole('button',{name:'Connect',exact:true}).click();
 await expect(page.getByRole('button',{name:'Fixture record',exact:true})).toBeVisible({timeout:15000});
 if (process.env.LIFE_UI_FILTER_CASE !== 'numeric') {
 await page.getByLabel('Filter property',{exact:true}).selectOption('active');
 await page.getByLabel('Filter value',{exact:true}).selectOption('true');
 await page.getByRole('button',{name:'Apply filter',exact:true}).click();
 await expect(page.getByText('1 record shown',{exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'Fixture record',exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'Second record',exact:true})).not.toBeVisible();
 await page.getByRole('button',{name:'Clear filters',exact:true}).click();
 await page.getByLabel('Filter value',{exact:true}).selectOption('false');
 await page.getByRole('button',{name:'Apply filter',exact:true}).click();
 await expect(page.getByText('1 record shown',{exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'Second record',exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'Fixture record',exact:true})).not.toBeVisible();
 console.log('PASS: True and False boolean filters match checked and unchecked records');
 await page.getByRole('button',{name:'Clear filters',exact:true}).click();
 }
 await page.getByLabel('Filter property',{exact:true}).selectOption('quantity');
 await page.getByLabel('Filter value',{exact:true}).fill('');
 await page.getByRole('button',{name:'Apply filter',exact:true}).click();
 await expect(page.getByRole('alert')).toContainText('Enter a number');
 await expect(page.getByRole('button',{name:/Remove filter/})).toHaveCount(0);
 await expect(page.getByText('3 records shown',{exact:true})).toBeVisible();
 console.log('PASS: Empty numeric input does not silently become a zero filter');
} finally { await browser.close(); server.stop(true); db.db.close(); }
