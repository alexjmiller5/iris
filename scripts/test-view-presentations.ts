import { expect } from "@playwright/test";
import { regressionHub } from "./workspace-regression-hub";
import { disposableOrigin } from "./test-origin";
import {
  sourceNavigationCDP,
  element,
  named,
  js,
} from "./source-navigation-cdp";

const source = process.argv[2];
if (!source) throw Error("Provide the life-data checkout");
const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-presentations.localhost:5252/workspace?review";
const origin = disposableOrigin(url);
const { server, db, auth } = await regressionHub(source, origin);
const viewSchema = await Bun.file(
  `${source}/core/schema/saved-views.json`,
).json();
let page: Awaited<ReturnType<typeof sourceNavigationCDP>> | undefined;
try {
  for (const ddl of [
    "ALTER TABLE widgets ADD COLUMN starts TEXT",
    "ALTER TABLE widgets ADD COLUMN ends TEXT",
    "ALTER TABLE widgets ADD COLUMN cover TEXT",
    "ALTER TABLE catalog_properties ADD COLUMN source TEXT",
    "ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT",
    ...viewSchema.ddl,
  ]) {
    db.db.exec(ddl);
    db.db
      .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
      .run("2026-01-01T00:00:00.000Z", ddl);
  }
  db.db
    .exec(`INSERT INTO catalog_tables(id,kind,display) VALUES ('views','table','name');
    INSERT INTO catalog_properties(id,tbl,col,label,sort,type) VALUES
    ('widgets.starts','widgets','starts','Starts',5,'date_or_datetime'),
    ('widgets.ends','widgets','ends','Ends',6,'date_or_datetime'),
    ('widgets.cover','widgets','cover','Cover',7,'url');
    UPDATE catalog_properties SET options='[{"v":"Todo"},{"v":"Doing"},{"v":"Done"}]',options_sql=NULL,default_value=NULL WHERE id='widgets.status';
    UPDATE widgets SET status='Todo';
    UPDATE widgets SET cover='https://images.invalid/gallery.png' WHERE id='fixture-record';
    INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES ('board-fixture','widgets','invariant',1,'SELECT id FROM changed WHERE id=''legacy-record'' AND status=''Done''','Legacy fixture cannot be done.');
    UPDATE widgets SET starts='2026-03-07',ends='2026-03-09' WHERE id='fixture-record';
    UPDATE widgets SET starts='2026-03-08T06:30:00Z',ends='2026-03-09T04:00:00Z' WHERE id='second-record';`);
  for (const p of viewSchema.properties) {
    const keys = Object.keys(p);
    db.db
      .query(
        `INSERT INTO catalog_properties(${keys.join(",")}) VALUES (${keys.map(() => "?").join(",")})`,
      )
      .run(...Object.values(p));
  }
  page = await sourceNavigationCDP(url);
  const cdp = page;
  cdp.on("Fetch.requestPaused", ({ requestId }) => {
    void cdp.command("Fetch.fulfillRequest", {
      requestId,
      responseCode: 200,
      responseHeaders: [{ name: "Content-Type", value: "image/png" }],
      body: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6S0AAAAASUVORK5CYII=",
    });
  });
  await cdp.command("Fetch.enable", {
    patterns: [{ urlPattern: "https://images.invalid/gallery.png" }],
  });
  const button = (name: string) => named("button", name);
  const click = (name: string) => cdp.click(button(name));
  const select = (label: string) => element(`select[aria-label="${label}"]`);
  const choose = async (label: string, value: string) => {
    await cdp.until(`!!(${select(label)}) && !(${select(label)}).disabled`);
    await cdp.evaluate(
      `(()=>{const e=${select(label)};e.value=${js(value)};e.dispatchEvent(new Event('change',{bubbles:true}));})()`,
    );
  };
  const has = (text: string) =>
    cdp.until(`document.body.innerText.includes(${js(text)})`);
  await cdp.navigate(new URL("/", url).href);
  await cdp.command("Storage.clearDataForOrigin", {
    origin,
    storageTypes: "all",
  });
  await cdp.navigate(url);
  await click("Open my workspace");
  for (const label of ["Connect to a hub", "Use a device token"]) {
    const control = named("button,summary", label);
    await cdp.until(`!!(${control})`);
    if (!(await cdp.evaluate(`(${control}).closest('details').open`)))
      await cdp.click(control);
  }
  const input = (label: string) =>
    `(()=>{const e=${named("label", label)};return e?.control??e?.querySelector('input');})()`;
  await cdp.fill(input("Hub address"), server.url.href.replace(/\/$/, ""));
  await cdp.fill(input("Device token"), "fixture");
  await click("Connect");
  await cdp.until(
    `!!(${button("New record")}) && !(${button("New record")}).disabled`,
  );
  await cdp.click(
    named("button", "widgets", element('nav[aria-label="Tables"]')),
  );
  await cdp.until(`document.body.innerText.includes('Fixture record')`);
  await choose("Filter property", "starts");
  expect(
    await cdp.evaluate(
      `Array.from((${select("Filter operator")}).options, option => option.value)`,
    ),
  ).toEqual(["eq", "ne", "empty", "not_empty", "gt", "lt"]);
  await choose("Filter property", "");
  // Calendar uses catalog-selected fields and displays every spanned civil date.
  await choose("View layout", "calendar");
  await choose("Calendar date property", "starts");
  await choose("Calendar end date property", "ends");
  await cdp.click(named("summary", "Filter groups"));
  await cdp.fill(
    element('input[aria-label="Today timezone"]'),
    "America/New_York",
  );
  await cdp.evaluate(
    `(()=>{const e=document.querySelector('input[aria-label="Today timezone"]');e.dispatchEvent(new Event('change',{bubbles:true}));})()`,
  );
  await cdp.evaluate(
    `(()=>{const e=document.querySelector('input[aria-label="Calendar month"]');e.value='2026-03';e.dispatchEvent(new Event('input',{bubbles:true}));})()`,
  );
  const day = (date: string) => element(`section[aria-label="${date}"]`);
  for (const date of ["2026-03-07", "2026-03-08", "2026-03-09"])
    await cdp.until(
      `(${day(date)})?.innerText.includes('Fixture record')===true`,
    );
  await cdp.until(
    `(${day("2026-03-08")})?.innerText.includes('Second record')===true`,
  );
  await cdp.until(
    `(${day("2026-03-09")})?.innerText.includes('Second record')===false`,
  );
  await has("Unscheduled or invalid dates (1)");
  await cdp.fill(element('input[aria-label="View name"]'), "Calendar fixture");
  await click("Save as");
  await cdp.until(
    `(${select("View")})?.selectedOptions[0]?.textContent==='Calendar fixture'`,
  );
  const savedID = await cdp.evaluate<string>(`(${select("View")}).value`);
  await choose("View layout", "gallery");
  await choose("Gallery cover property", "cover");
  await cdp.until(
    `document.querySelectorAll('[aria-label="Gallery view"] button').length===3`,
  );
  await has("No cover");
  await cdp.until(
    `document.querySelector('[aria-label="Gallery view"] img')?.naturalWidth===1`,
  );
  await cdp.until(
    `getComputedStyle(document.querySelector('.gallery-card')).backgroundColor !== 'rgba(0, 0, 0, 0)'`,
  );
  await choose("View", savedID);
  await cdp.until(
    `(${select("View layout")})?.value==='calendar' && (${select("Calendar end date property")})?.value==='ends'`,
  );
  // Board moves reuse the ordinary writer; both drag and accessible menu persist.
  await choose("View layout", "board");
  await choose("Board group property", "status");
  const column = (value: string) =>
    element(`section[aria-label="Column ${value}"]`);
  await cdp.until(
    `(${column("Todo")})?.innerText.includes('Fixture record')===true`,
  );
  await choose("Move Fixture record", "Doing");
  await cdp.until(
    `(${column("Doing")})?.innerText.includes('Fixture record')===true`,
  );
  const grip = element('button[aria-label="Drag Fixture record"]');
  await cdp.evaluate(`(${grip}).scrollIntoView({block:'center'})`);
  const start = await cdp.evaluate<{ x: number; y: number }>(
    `(()=>{const r=(${grip}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`,
  );
  const end = await cdp.evaluate<{ x: number; y: number }>(
    `(()=>{const r=(${column("Done")}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+80};})()`,
  );
  await cdp.command("Input.dispatchMouseEvent", {
    type: "mousePressed",
    ...start,
    button: "left",
    buttons: 1,
    clickCount: 1,
  });
  await cdp.command("Input.dispatchMouseEvent", {
    type: "mouseMoved",
    ...end,
    button: "left",
    buttons: 1,
  });
  await cdp.command("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    ...end,
    button: "left",
    buttons: 0,
    clickCount: 1,
  });
  await cdp.until(
    `(${column("Done")})?.innerText.includes('Fixture record')===true`,
  );
  await choose("Move Legacy record", "Done");
  await has("Legacy fixture cannot be done.");
  await cdp.until(
    `(${column("Todo")})?.innerText.includes('Legacy record')===true`,
  );
  await cdp.until(`(${select("Move Legacy record")})?.value==='Todo'`);
  const presentationResync = await cdp.evaluate("new Date().toISOString()");
  await cdp.until(
    `(document.querySelector('[data-last-sync]')?.getAttribute('data-last-sync') ?? '') > ${js(presentationResync)}`,
  );
  await expect
    .poll(
      () =>
        db.db
          .query("SELECT status FROM widgets WHERE id='fixture-record'")
          .get().status,
    )
    .toBe("Done");
  const saved = JSON.parse(
    db.db.query("SELECT definition FROM views WHERE id=?").get(savedID)
      .definition,
  );
  expect(saved.presentation).toEqual({
    kind: "calendar",
    dateColumn: "starts",
    endDateColumn: "ends",
  });
  expect(saved.timeZone).toBe("America/New_York");
  if (process.env.LIFE_UI_TEST_SCREENSHOT) {
    const shot = await cdp.command("Page.captureScreenshot", { format: "png" });
    await Bun.write(
      process.env.LIFE_UI_TEST_SCREENSHOT,
      Buffer.from(shot.data, "base64"),
    );
  }
  console.log(
    "PASS real Worker/OPFS Calendar ranges, DST, unscheduled rows, Gallery, saved layout round-trip, Board menu and pointer moves with sync readback.",
  );
} catch (failure) {
  if (page) console.error(await page.evaluate("document.body.innerText"));
  throw failure;
} finally {
  if (page) {
    await page.navigate(new URL("/", url).href).catch(() => {});
    await page
      .command("Storage.clearDataForOrigin", { origin, storageTypes: "all" })
      .catch(() => {});
    page.close();
  }
  server.stop(true);
  db.db.close();
  auth.db.close();
}
