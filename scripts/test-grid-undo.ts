import { chromium, expect } from "@playwright/test";
import { disposableOrigin, workspacePage } from "./test-origin";
import { regressionHub } from "./workspace-regression-hub";
const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-grid-enrollment.localhost:5234/workspace?review";
const origin = disposableOrigin(url),
  source = process.argv[2];
if (!source) throw Error("Provide the life-data checkout");
const browser = await chromium.connectOverCDP(
  process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
);
const page = workspacePage(
  browser.contexts().flatMap((c) => c.pages()),
  url,
);
page.setDefaultTimeout(10000);
page.on("dialog", (d) => d.accept());
page.on("pageerror", (error) => console.error("Page error:", error.message));
const save = () =>
  page.getByRole("button", { name: "Save record", exact: true });
const undo = () =>
  page.getByRole("button", { name: "Undo last saved change", exact: true });
const title = () => page.getByRole("textbox", { name: "Title", exact: true });
const close = () =>
  page.getByRole("button", { name: "Close record", exact: true }).click();
async function body() {
  if (!await page.locator('textarea[aria-label="Body"]').isVisible()) {
    await page.getByRole("button", {name:"Body options",exact:true}).click();
    await page.getByRole("menuitem", {name:"Body source",exact:true}).click();
  }
  return page.getByRole("textbox", { name: "Body", exact: true });
}
async function rows() {
  return page.evaluate(async () => {
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const other = new WorkspaceDatabase();
    try {
      await other.request("open");
      return [
        ...(await other.request("rows", { view: { table: "widgets" } })),
        ...(await other.request("rows", {
          view: { table: "widgets", trash: true },
        })),
      ];
    } finally {
      other.close();
    }
  });
}
async function closeFixture() {
  const close = page.getByRole("button", {name:"Close record",exact:true});
  if (await close.count()) await close.click();
  const leave = page.getByRole("button", {name:"Switch workspace",exact:true});
  if (await leave.count()) await leave.click();
  await expect.poll(() => page.workers().length, {timeout:15000}).toBe(0);
}
async function check(name: string, run: () => Promise<void>) {
  if (
    process.env.LIFE_UI_GRID_UNDO_CASE &&
    !name.includes(process.env.LIFE_UI_GRID_UNDO_CASE)
  )
    return;
  console.log("RUN: " + name);
  const { server, db } = await regressionHub(source, origin, 0);
  db.db.exec(
    "INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES ('positive','widgets','invariant',1,'SELECT id FROM changed WHERE quantity<0','Quantity cannot be negative.')",
  );
  try {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await closeFixture();
    await page.goto(new URL("/", url).href);
    await expect(
      page.getByRole("button", { name: "Open my workspace", exact: true }),
    ).toBeEnabled({ timeout: 30000 });
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Storage.clearDataForOrigin", {
      origin,
      storageTypes: "all",
    });
    await cdp.detach();
    await page.goto(url);
    await page
      .getByRole("button", { name: "Open my workspace", exact: true })
      .click({ timeout: 30000 });
    await page.getByText("Connect to a hub", { exact: true }).click();
  await page.getByText("Use a device token", { exact: true }).click();
    await page
      .getByLabel("Hub address")
      .fill(server.url.href.replace(/\/$/, ""));
    await page.getByLabel("Device token").fill("fixture");
    const sync = page.getByRole("button", { name: "Sync now", exact: true });
    await sync.click();
    await expect(sync).toBeEnabled({ timeout: 30000 });
    await expect(
      page.getByRole("button", { name: "Fixture record", exact: true }),
    ).toBeVisible();
    await run();
    console.log("PASS: " + name);
  } finally {
    await closeFixture();
    await page.goto(url);
    await expect(
      page.getByRole("button", { name: "Open my workspace", exact: true }),
    ).toBeEnabled({ timeout: 30000 });
    server.stop(true);
    db.db.close();
  }
}const panel = () => page.getByRole('complementary', {name:'Record editor',exact:true});
const gridGroup = (label:string) => page.getByRole('group', {name:`Edit ${label}`,exact:true});
async function beginCell(column:string, label:string, id='fixture-record') {
 const cell=page.getByRole('grid',{name:'Records',exact:true}).locator(`[data-row="${id}"][data-column="${column}"]`);
 await cell.focus(); await cell.press('Enter'); await expect(gridGroup(label)).toBeVisible();
}
async function saveGridQuantity() {
 await beginCell('quantity','Quantity');
 await gridGroup('Quantity').getByLabel('Quantity',{exact:true}).fill('43');
 await gridGroup('Quantity').getByRole('button',{name:'Save cell',exact:true}).click();
 await expect(page.locator('[data-cell-editor]')).toHaveCount(0);
 await expect(undo()).toBeEnabled();
}
async function stored(id='fixture-record') {return (await rows()).find(r=>r.id===id)!;}
async function assertPaused() {
 await expect(page.getByRole('status',{name:'Draft review',exact:true})).toBeVisible();
 await page.waitForTimeout(900);
}
try {
 await check('dirty same-row cell promotes only changed raw over undo receipt', async()=>{
  await saveGridQuantity(); await beginCell('title','Title');
  await gridGroup('Title').getByLabel('Title',{exact:true}).fill('Retained grid draft');
  await undo().click(); await expect(page.getByText('Undid the last saved change in widgets',{exact:false})).toBeVisible(); await expect(panel()).toBeVisible();
  await expect(panel().getByLabel('Title',{exact:true})).toHaveValue('Retained grid draft');
  await expect(panel().getByLabel('Quantity',{exact:true})).toHaveValue('42');
  await expect(page.locator('[data-cell-editor]')).toHaveCount(0);
  await assertPaused(); expect((await stored()).title).toBe('Fixture record');
  expect((await stored()).quantity).toBe(42);
  await save().click(); await expect(save()).toBeEnabled();
  expect((await stored()).title).toBe('Retained grid draft'); expect((await stored()).quantity).toBe(42);
 });
 await check('dirty same-property cell preserves raw and saves from receipt revision',async()=>{
  await saveGridQuantity(); await beginCell('quantity','Quantity');
  await gridGroup('Quantity').getByLabel('Quantity',{exact:true}).fill('44');
  await undo().click(); await expect(page.getByText('Undid the last saved change in widgets',{exact:false})).toBeVisible();await expect(panel().getByLabel('Quantity',{exact:true})).toHaveValue('44');
  await assertPaused(); expect((await stored()).quantity).toBe(42);
  await save().click(); await expect(save()).toBeEnabled(); expect((await stored()).quantity).toBe(44);
 });
 await check('Markdown cell waits for explicit Save after undo',async()=>{
  await saveGridQuantity();
  const columns=page.locator('details').filter({has:page.locator('summary').filter({hasText:/^\s*Columns\s*$/})}); await columns.locator('summary').click(); await columns.getByRole('checkbox',{name:'Show Body',exact:true}).check(); await columns.locator('summary').click();
  await beginCell('body','Body');
  await gridGroup('Body').getByRole('button', {name:'Body options',exact:true}).click();
  await gridGroup('Body').getByRole('menuitem', {name:'Body source',exact:true}).click();
  await gridGroup('Body').getByRole('textbox',{name:'Body',exact:true}).fill('Unsaved **cell** body');
  await undo().click(); await expect(page.getByText('Undid the last saved change in widgets',{exact:false})).toBeVisible();await expect(panel()).toBeVisible();
  await expect(await body()).toHaveValue('Unsaved **cell** body');
  await assertPaused(); expect((await stored()).body).toBe('Original body'); expect((await stored()).quantity).toBe(42);
  await save().click(); await expect(save()).toBeEnabled(); expect((await stored()).body).toBe('Unsaved **cell** body');
 });
 await check('clean same-row cell clears without copying the undone value back',async()=>{
  await saveGridQuantity(); await beginCell('quantity','Quantity');
  await undo().click(); await expect(page.getByText('Undid the last saved change in widgets',{exact:false})).toBeVisible();await expect(page.locator('[data-cell-editor]')).toHaveCount(0);
  await expect(panel()).toHaveCount(0);
  await expect(page.locator('[data-row="fixture-record"][data-column="quantity"]')).toContainText('42');
  expect((await stored()).quantity).toBe(42);
 });
 await check('other-row dirty cell stays editable with its original draft',async()=>{
  await saveGridQuantity(); await beginCell('title','Title','second-record');
  await gridGroup('Title').getByLabel('Title',{exact:true}).fill('Other draft');
  await undo().click(); await expect(page.getByText('Undid the last saved change in widgets',{exact:false})).toBeVisible();await expect(undo()).toBeDisabled();
  await expect(panel()).toHaveCount(0); await expect(gridGroup('Title').getByLabel('Title',{exact:true})).toHaveValue('Other draft');
  expect((await stored()).quantity).toBe(42); expect((await stored('second-record')).title).toBe('Second record');
  await gridGroup('Title').getByRole('button',{name:'Save cell',exact:true}).click();
  await expect(page.locator('[data-cell-editor]')).toHaveCount(0); expect((await stored('second-record')).title).toBe('Other draft');
 });
 await check('creation undo promotes a read-only tombstone and Restore keeps raw',async()=>{
  await page.getByRole('button',{name:'New record',exact:true}).click();
  await title().fill('New grid record'); await save().click(); await expect(save()).toBeEnabled();
  const created=(await rows()).find(r=>r.title==='New grid record')!; await close();
  await beginCell('title','Title',String(created.id)); await gridGroup('Title').getByLabel('Title',{exact:true}).fill('Retained creation draft');
  await undo().click(); await expect(page.getByText('Undid the last saved change in widgets',{exact:false})).toBeVisible();await expect(panel()).toBeVisible();
  await expect(panel().getByLabel('Title',{exact:true})).toHaveValue('Retained creation draft');
  await expect(panel().getByLabel('Title',{exact:true})).toBeDisabled(); await expect(save()).toBeDisabled();
  expect((await stored(String(created.id))).deleted_at).not.toBeNull();
  await page.setViewportSize({width:390,height:844}); expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true); await page.screenshot({path:'/tmp/life-ui-grid-undo-review.png'});
  await page.getByRole('button',{name:'Restore record',exact:true}).click();
  await expect(panel().getByLabel('Title',{exact:true})).toBeEnabled(); await expect(panel().getByLabel('Title',{exact:true})).toHaveValue('Retained creation draft');
  await assertPaused(); expect((await stored(String(created.id))).title).toBe('New grid record');
  expect((await stored(String(created.id))).deleted_at).toBeNull();
  await save().click(); await expect(save()).toBeEnabled(); expect((await stored(String(created.id))).title).toBe('Retained creation draft');
 });
 await check('failed undo retains cell and receipt without rebasing a stale draft',async()=>{
  await saveGridQuantity(); await beginCell('title','Title');
  await gridGroup('Title').getByLabel('Title',{exact:true}).fill('Keep conflicting draft');
  await page.evaluate(async()=>{const {WorkspaceDatabase}=await import('/src/lib/database.ts');const other=new WorkspaceDatabase();try{await other.request('open');const [r]=await other.request('rows',{view:{table:'widgets',filters:[{column:'id',op:'eq',value:'fixture-record'}]}});await other.request('write',{table:'widgets',patch:{id:r.id,quantity:45},expectedUpdatedAt:r.updated_at});}finally{other.close();}});
  await undo().click(); await expect(page.getByRole('alert')).toContainText(/changed|revision/i);
  await expect(undo()).toBeEnabled(); await expect(panel()).toHaveCount(0); await expect(gridGroup('Title').getByLabel('Title',{exact:true})).toHaveValue('Keep conflicting draft');
  await gridGroup('Title').getByRole('button',{name:'Save cell',exact:true}).click();
  await expect(gridGroup('Title').getByRole('alert')).toContainText(/changed|revision/i);
  expect((await stored()).quantity).toBe(45); expect((await stored()).title).toBe('Fixture record');
 });
} finally {await browser.close();}
