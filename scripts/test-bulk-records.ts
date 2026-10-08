import { expect } from "@playwright/test";
import { regressionHub } from "./workspace-regression-hub";
import { disposableOrigin } from "./test-origin";
import {
  sourceNavigationCDP,
  element,
  named,
  js,
} from "./source-navigation-cdp";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const source = process.argv[2];
if (!source) throw Error("Provide the life-data checkout");
const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-grid.localhost:5268/workspace?review";
const origin = disposableOrigin(url);
const { server, db, auth } = await regressionHub(source, origin);
// This suite has one deliberate rejection, the rule below. The shared fixture's
// legacy unavailable tag is exercised by its own editor/rejection tests.
db.db.exec(`UPDATE widgets SET tags='["Dynamic"]' WHERE id='legacy-record'`);
const downloads = await mkdtemp(join(tmpdir(), "life-ui-bulk-download-"));
db.db
  .query(
    "INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)",
  )
  .run(
    "bulk-rule",
    "widgets",
    "invariant",
    1,
    "SELECT id FROM changed WHERE id='second-record' AND quantity=7",
    "Second row refuses seven.",
  );
let page: Awaited<ReturnType<typeof sourceNavigationCDP>> | undefined;
try {
  page = await sourceNavigationCDP(url);
  const cdp = page;
  await cdp.command("Page.setDownloadBehavior", {
    behavior: "allow",
    downloadPath: downloads,
  });
  const button = (name: string) => named("button", name);
  const click = (name: string) => cdp.click(button(name));
  await cdp.navigate(new URL("/", url).href);
  await cdp.command("Storage.clearDataForOrigin", {
    origin,
    storageTypes: "all",
  });
  const installed = await cdp.command("Page.addScriptToEvaluateOnNewDocument", {
    source: `
    window.bulkFixture = {hold:false,writes:0,held:[]};
    const Original = window.Worker;
    window.Worker = class extends Original {
      requests = new Map();
      postMessage(request,...args) { this.requests.set(request.id,request); return super.postMessage(request,...args); }
      set onmessage(handler) {
        super.onmessage = event => {
          const request = this.requests.get(event.data.id);
          this.requests.delete(event.data.id);
          if (request?.method==='write' && !event.data.error) window.bulkFixture.writes++;
          const deliver = () => handler?.(event);
          if (request?.method==='rows' && window.bulkFixture.hold && window.bulkFixture.writes>=1) window.bulkFixture.held.push(deliver);
          else deliver();
        };
      }
    };
  `,
  });
  page.on("Runtime.exceptionThrown", (event) =>
    console.error("Synthetic runtime error", event.exceptionDetails?.text),
  );
  await cdp.navigate(url);
  await cdp.command("Page.removeScriptToEvaluateOnNewDocument", {
    identifier: installed.identifier,
  });
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
  await cdp.click(element('input[aria-label="Select loaded rows"]'));
  await cdp.click(named("summary", "Selection (3)"));
  await cdp.evaluate(
    `(()=>{const e=document.querySelector('select[aria-label="Bulk property"]');e.value='quantity';e.dispatchEvent(new Event('change',{bubbles:true}));})()`,
  );
  await cdp.fill(element("#bulk-value"), "7");
  await click("Apply to selected");
  await cdp.until(
    `document.body.innerText.includes('2 succeeded · 1 failed · 0 unattempted')`,
  );
  const resyncQuantity = await cdp.evaluate("new Date().toISOString()");
  await cdp.until(
    `(document.querySelector('[data-last-sync]')?.getAttribute('data-last-sync') ?? '') > ${JSON.stringify(resyncQuantity)}`,
  );
  await expect
    .poll(() =>
      db.db.query("SELECT id,quantity FROM widgets ORDER BY id").all(),
    )
    .toEqual([
      { id: "fixture-record", quantity: 7 },
      { id: "legacy-record", quantity: 7 },
      { id: "second-record", quantity: 42 },
    ]);
  await cdp.click(named("summary", "Row results"));
  await cdp.until(
    `document.body.innerText.includes('Second row refuses seven.')`,
  );
  await cdp.click(element('[role=row]:has([data-row="fixture-record"]) input[type=checkbox]'));
  await cdp.click(element('[role=row]:has([data-row="legacy-record"]) input[type=checkbox]'));
  await cdp.click(named("summary", "Export"));
  await cdp.until(
    `!!(${button("Export selection")}) && !(${button("Export selection")}).disabled`,
  );
  await click("Export selection");
  await expect
    .poll(
      async () =>
        (await readdir(downloads)).filter((name) => name.endsWith(".json"))
          .length,
    )
    .toBe(1);
  const [file] = (await readdir(downloads)).filter((name) =>
    name.endsWith(".json"),
  );
  const exported = JSON.parse(await readFile(join(downloads, file), "utf8"));
  expect(exported.scope).toEqual({ kind: "selection", rowCount: 2 });
  expect(exported.rows.map((row: any) => row.id)).toEqual([
    "fixture-record",
    "legacy-record",
  ]);
  expect(exported.completeness.rows).toBe("unknown");
  await cdp.evaluate(
    `(()=>{const e=document.querySelector('select[aria-label="Export format"]');e.value='csv';e.dispatchEvent(new Event('change',{bubbles:true}));})()`,
  );
  await click("Export selection");
  await click("Download CSV metadata");
  await expect
    .poll(
      async () =>
        (await readdir(downloads)).filter((name) =>
          name.endsWith(".metadata.json"),
        ).length,
    )
    .toBe(1);
  const files = await readdir(downloads);
  const csv = await readFile(
    join(
      downloads,
      files.find((name) => name.endsWith(".csv"))!,
    ),
    "utf8",
  );
  const sidecar = JSON.parse(
    await readFile(
      join(
        downloads,
        files.find((name) => name.endsWith(".metadata.json"))!,
      ),
      "utf8",
    ),
  );
  expect(csv).toContain("fixture-record");
  expect(csv).toContain("legacy-record");
  expect(csv).not.toContain("second-record");
  expect(sidecar.scope).toEqual({ kind: "selection", rowCount: 2 });
  await cdp.click(named("summary", "Export"));
  await cdp.click(element('input[aria-label="Select loaded rows"]'));
  await cdp.fill(element("#bulk-value"), "8");
  await cdp.evaluate(
    "window.bulkFixture.hold=true;window.bulkFixture.writes=0",
  );
  await click("Apply to selected");
  await cdp.until("window.bulkFixture.held.length>0");
  await click("Cancel remaining");
  await cdp.evaluate(
    "window.bulkFixture.hold=false;window.bulkFixture.held.splice(0).forEach(deliver=>deliver())",
  );
  await cdp.until(
    `document.body.innerText.includes('1 succeeded · 0 failed · 2 unattempted')`,
  );
  expect(await cdp.evaluate("window.bulkFixture.writes")).toBe(1);
  await cdp.click(element('[role=row]:has([data-row="fixture-record"]) input[type=checkbox]'));
  await cdp.click(element('[role=row]:has([data-row="legacy-record"]) input[type=checkbox]'));
  await click("Move selected to trash");
  await cdp.until(
    `document.body.innerText.includes('2 succeeded · 0 failed · 0 unattempted')`,
  );
  const resyncTrash = await cdp.evaluate("new Date().toISOString()");
  await cdp.until(
    `(document.querySelector('[data-last-sync]')?.getAttribute('data-last-sync') ?? '') > ${JSON.stringify(resyncTrash)}`,
  );
  await expect
    .poll(() =>
      db.db
        .query("SELECT id FROM widgets WHERE deleted_at IS NULL ORDER BY id")
        .all(),
    )
    .toEqual([{ id: "second-record" }]);
  if (process.env.LIFE_UI_TEST_SCREENSHOT) {
    const screenshot = await cdp.command("Page.captureScreenshot", {
      format: "png",
    });
    await writeFile(
      process.env.LIFE_UI_TEST_SCREENSHOT,
      Buffer.from(screenshot.data, "base64"),
    );
  }
  console.log(
    "PASS: mounted selection, partial success through actual core writes, JSON/CSV/sidecar readback, cancellation after one committed write, and soft-delete readback",
  );
} catch (error) {
  if (page)
    console.error(
      "Synthetic page at failure:",
      await page.evaluate("document.body.innerText"),
    );
  throw error;
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
  await rm(downloads, { recursive: true });
}
