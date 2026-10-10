import { workspacePage, synced, recordSaved } from './test-origin';
import {chromium,expect} from '@playwright/test';
const url=process.env.IRIS_TEST_URL??'http://localhost:5196/workspace';
const hub=process.env.IRIS_TEST_HUB??'http://127.0.0.1:5201';
async function pattern(value:string|null){
  const response=await fetch(`${hub}/v1/rows/push`,{method:'POST',headers:{Authorization:'Bearer fixture','Content-Type':'application/json'},body:JSON.stringify({table:'catalog_properties',columns:['id','pattern','updated_at'],rows:[{id:'widgets.title',pattern:value,updated_at:new Date().toISOString()}]})});
  const result=await response.json() as {upserted:number};
  expect(result.upserted).toBe(1);
}
const browser=await chromium.connectOverCDP(process.env.IRIS_TEST_CDP??'http://127.0.0.1:9222');
try{
  await pattern(null);
  const page=workspacePage(browser.contexts().flatMap(c => c.pages()), url);
  if(!page)throw new Error(`Open dedicated rejection test page: ${url}`);
  page.setDefaultTimeout(10000);
  await page.reload();
  await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
  await page.getByText('Connect to a hub',{exact:true}).click();await page.getByText('Use a device token', {exact:true}).click();
  await page.getByLabel('Hub address').fill(hub);
  await page.getByLabel('Device token').fill('fixture');
  await page.getByRole('button',{name:'Connect',exact:true}).click();
  await expect(page.getByRole('heading',{name:'widgets',exact:true})).toBeVisible();
  await page.getByRole('button',{name:'New record',exact:true}).click();
  await page.getByRole('textbox',{name:'Title',exact:true}).fill('Rejected draft');
  await recordSaved(page);
  await page.getByRole('button',{name:'Close record',exact:true}).click();
  await pattern('Allowed');
  await expect(page.getByText(/rejected edits? needs? attention/)).toBeVisible({ timeout: 15000 });
  await page.getByText(/rejected edits? needs? attention/).click();
  await expect(page.locator('.rejections')).toContainText('not in the expected form');
  await page.getByRole('button',{name:'Review rejected edit',exact:true}).first().click();
  await expect(page.getByRole('textbox',{name:'Title',exact:true})).toHaveValue('Rejected draft');
  await page.getByRole('textbox',{name:'Title',exact:true}).fill('Allowed');
  await recordSaved(page);
  await page.getByRole('button',{name:'Close record',exact:true}).click();
  await synced(page);
  await expect(page.locator('.rejections')).toHaveCount(0);
  console.log('PASS: server-side rule change rejects pending edit; inbox preserves, explains and repairs it');
}finally{try{await pattern(null);}finally{await browser.close();}}
