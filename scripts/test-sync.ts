import { chromium,expect, type CDPSession } from '@playwright/test';

const url=process.env.LIFE_UI_TEST_URL??'http://127.0.0.1:5197/workspace';
const hub=process.env.LIFE_UI_TEST_HUB??'http://127.0.0.1:5200';
const browser=await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP??'http://127.0.0.1:9222');
let network: CDPSession | undefined;
try{
  const page=browser.contexts().flatMap(c=>c.pages()).find(p=>p.url()===url);
  if(!page)throw new Error(`Open this dedicated test page first: ${url}`);
  await page.reload();
  await page.getByRole('button',{name:'Open my workspace',exact:true}).click();
  await page.getByText('Connect to a hub',{exact:true}).click();
  await page.getByLabel('Hub address').fill(hub);
  await page.getByLabel('Device token').fill('fixture');
  await page.getByRole('button',{name:'Sync now',exact:true}).click();
  await expect(page.getByRole('heading',{name:'widgets',exact:true})).toBeVisible({timeout:15000});
  await expect(page.getByRole('button',{name:'Fixture record',exact:true})).toBeVisible();
  const title=`Synced draft ${Date.now()}`;
  network=await page.context().newCDPSession(page);
  await network.send('Network.enable');
  await network.send('Network.emulateNetworkConditions',{offline:true,latency:0,downloadThroughput:-1,uploadThroughput:-1});
  await expect(page.getByText('Device offline - edits stay here',{exact:true})).toBeVisible();
  await page.getByRole('button',{name:'New record',exact:true}).click();
  await page.getByRole('textbox',{name:'Title',exact:true}).fill(title);
  await page.getByLabel('Body',{exact:true}).fill('# Local to hub');
  await page.getByLabel('Quantity',{exact:true}).fill('7');
  await page.getByRole('button',{name:'Save record',exact:true}).click();
  await expect(page.getByRole('heading',{name:title,exact:true})).toBeVisible();
  await expect(page.getByRole('button',{name:'Save record',exact:true})).toBeEnabled();
  await expect(page.getByRole('alert')).toHaveCount(0);
  await page.getByRole('button',{name:'Close record',exact:true}).click();
  await expect(page.getByRole('complementary',{name:'Record editor',exact:true})).toHaveCount(0);
  await expect(page.getByText(/^Pending edits: [1-9]\d*$/)).toBeVisible();
  await network.send('Network.emulateNetworkConditions',{offline:false,latency:0,downloadThroughput:-1,uploadThroughput:-1});
  await network.detach();
  network=undefined;
  await page.getByRole('button',{name:'Sync now',exact:true}).click();
  await expect.poll(async()=>{
    const response=await fetch(`${hub}/v1/rows/pull`,{method:'POST',headers:{Authorization:'Bearer fixture','Content-Type':'application/json'},body:JSON.stringify({table:'widgets',columns:['id','title','body','quantity'],since:'',limit:200})});
    const result=await response.json() as {rows:Record<string,unknown>[]};
    return result.rows.find(row=>row.title===title);
  },{timeout:15000}).toMatchObject({title,body:'# Local to hub',quantity:7});
  await expect(page.getByRole('alert')).toHaveCount(0);
  if(await page.getByRole('button',{name:'Use automatic size rule',exact:true}).count())await page.getByRole('button',{name:'Use automatic size rule',exact:true}).click();
  await page.getByLabel('Automatic sync row limit').fill('0');
  await page.getByRole('button',{name:'Sync now',exact:true}).click();
  await expect(page.getByText(/This table is excluded from sync/)).toBeVisible();
  await page.getByRole('button',{name:'Include this table',exact:true}).click();
  await page.getByRole('button',{name:'Sync now',exact:true}).click();
  await expect(page.getByText(/This table is excluded from sync/)).toHaveCount(0);
  console.log('PASS: browser OPFS pulled the real Worker schema/catalog, created a typed row and synced it back');
}finally{
  if(network){
    await network.send('Network.emulateNetworkConditions',{offline:false,latency:0,downloadThroughput:-1,uploadThroughput:-1}).catch(()=>{});
    await network.detach().catch(()=>{});
  }
  await browser.close();
}
