import {chromium,expect} from '@playwright/test';
import {disposableOrigin,workspacePage} from './test-origin';
import {enrollmentHub} from './enrollment-hub';
const url=process.env.LIFE_UI_TEST_URL??'http://life-ui-enrollment.localhost:5230/workspace?review';
const origin=disposableOrigin(url);
if(!['http://life-ui-enrollment.localhost:5230','http://life-ui-grid-enrollment.localhost:5234'].includes(origin))throw Error('Enrollment runner requires its exact reserved origin');
const source=process.argv[2];if(!source)throw Error('Provide life-data fixture source checkout');
const hub=await enrollmentHub(source,origin),other=await enrollmentHub(source,origin);
const browser=await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP??'http://127.0.0.1:9222');
try {
 const page=workspacePage(browser.contexts().flatMap(c=>c.pages()),url);if(!page)throw Error('Open the dedicated enrollment fixture page');
 page.setDefaultTimeout(10000);
 await page.goto(new URL('/',url).href);
 const cdp=await page.context().newCDPSession(page);await cdp.send('Storage.clearDataForOrigin',{origin,storageTypes:'all'});await cdp.detach();
 await page.goto(url);await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
 await page.getByText('Connect to a hub',{exact:true}).click();
 const endpoint=hub.server.url.href.replace(/\/$/,'');
 await page.getByLabel('Hub address').fill(endpoint);
 await page.getByRole('button',{name:'Approve this browser',exact:true}).click();
 const link=page.getByRole('link',{name:'Open approval page'});await expect(link).toBeVisible();
 const approval=await link.getAttribute('href');expect(approval).not.toContain('lt_');expect(approval).toContain('/login?key=');
 await expect(page.getByText(/Approval code:/)).toContainText(new URL(approval!).searchParams.get('key')!.slice(0,8));
 // Exercise the explicit link and actual Worker approval form in its isolated popup.
 const popupPromise=page.waitForEvent('popup');await link.click();const popup=await popupPromise;
 await popup.getByRole('button',{name:'Approve device',exact:true}).click();await expect(popup.getByRole('heading')).toContainText('approved');await popup.close();
 await expect(page.getByRole('button',{name:'Fixture record',exact:true})).toBeVisible({timeout:30000});
 console.log('PASS: explicit fingerprint/code, actual Worker approval and replica sync');
 await page.getByText('Use a device token',{exact:true}).click();
 const approved=await page.getByLabel('Device token').inputValue();expect(approved).toMatch(/^lt_[a-f0-9]{48}$/);
 const state=await page.evaluate(()=>({url:location.href,local:JSON.stringify(localStorage),session:JSON.stringify(sessionStorage)}));expect(JSON.stringify(state)).not.toContain(approved);
 for(const bad of ['fixture-root','fixture-restricted','fixture-revoked']){
  await page.getByLabel('Device token').fill(bad);await page.getByRole('button',{name:'Sync now',exact:true}).click();
  await expect(page.getByRole('alert')).toBeVisible();await expect(page.getByRole('button',{name:'Fixture record',exact:true})).toBeVisible();
 }
 await page.getByLabel('Device token').fill('fixture');await page.getByRole('button',{name:'Sync now',exact:true}).click();await expect(page.getByText('Connected. The device token stays in memory for this browser session.')).toBeVisible();
 console.log('PASS: dedicated manual token; admin/restricted/revoked rejection preserves existing workspace');
 await page.getByLabel('Hub address').fill(other.server.url.href.replace(/\/$/,''));
 await page.getByRole('button',{name:'Sync now',exact:true}).click();await expect(page.getByRole('alert')).toContainText('hub changed');expect(other.requests.filter(r=>r.authenticated)).toEqual([]);
 await page.getByLabel('Hub address').fill(endpoint);await page.getByRole('button',{name:'Approve this browser',exact:true}).click();await expect(link).toBeVisible();
 const abandoned=await link.getAttribute('href');await page.getByRole('button',{name:'Cancel approval',exact:true}).click();
 await expect(page.getByText(/may still be approved later/)).toBeVisible();expect((await hub.approve(abandoned!)).status).toBe(200);
 await page.waitForTimeout(5500);await expect(link).toHaveCount(0);expect(await page.getByLabel('Device token').inputValue()).toBe('fixture');
 console.log('PASS: endpoint isolation and cancelled late approval cannot replace the connection');
 await page.setViewportSize({width:390,height:844});
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);
 await page.getByRole('button',{name:'Approve this browser',exact:true}).focus();await page.keyboard.press('Enter');await expect(link).toBeVisible();
 const switched=await link.getAttribute('href');await page.getByRole('button',{name:'Switch workspace',exact:true}).click();expect((await hub.approve(switched!)).status).toBe(200);
 await page.getByRole('button',{name:'Open my workspace',exact:true}).click();await expect(page.getByRole('button',{name:'Fixture record',exact:true})).toBeVisible();
 await page.getByText('Connect to a hub',{exact:true}).click();await page.getByText('Use a device token',{exact:true}).click();await expect(page.getByLabel('Device token')).toHaveValue('');await expect(page.getByRole('button',{name:'Approve this browser',exact:true})).toBeEnabled();
 console.log('PASS: keyboard/narrow layout, workspace-close isolation and session-only credentials');
} finally {await browser.close();hub.server.stop(true);other.server.stop(true);hub.db.db.close();hub.auth.db.close();other.db.db.close();other.auth.db.close();}
