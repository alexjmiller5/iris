import { mkdirSync } from "node:fs";
import { expect } from "@playwright/test";
import { installCoreSchemas, logDDL, regressionHub } from "./workspace-regression-hub";
import { disposableOrigin } from "./test-origin";
import { sourceNavigationCDP, element, named } from "./source-navigation-cdp";

// Synthetic people table and a widgets Markdown body: insert a person mention and
// a saved-view embed through the slash menu, sync, reload, rename the person on
// the hub, then click through to the record and its Linked from backlink.
const source = process.argv[2];
if (!source) throw Error("Provide matching soma source");
const url = process.env.IRIS_TEST_URL ?? "http://iris-markdown.localhost:5391/workspace?review";
const shots = process.env.IRIS_TEST_SHOTS;
if (shots) mkdirSync(shots, { recursive: true });
const origin = disposableOrigin(url);
const { server, db, auth } = await regressionHub(source, origin);
const hubBody = () =>
  String((db.db.query("SELECT body FROM widgets WHERE id='fixture-record'").get() as { body: string }).body);
let page: Awaited<ReturnType<typeof sourceNavigationCDP>> | undefined;
try {
  await installCoreSchemas(db, source, ["saved-views"]);
  const system =
    "id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),deleted_at TEXT,hub_at TEXT";
  logDDL(db, `CREATE TABLE "people" (${system},full_name TEXT)`);
  db.db.exec(`INSERT INTO catalog_tables(id,kind,display) VALUES ('people','table','full_name');
    INSERT INTO catalog_properties(id,tbl,col,label,sort,type,required) VALUES ('people.full_name','people','full_name','Full name',0,'text',1);
    INSERT INTO people(id,full_name) VALUES ('p-ada','Ada Lovelace'),('p-grace','Grace Hopper');
    UPDATE widgets SET body='Mentions [Gone person](iris://table/people/row/p-gone) here.' WHERE id='second-record';`);
  db.db
    .query("INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)")
    .run("open-widgets", "Open widgets", "widgets", JSON.stringify({ version: 1, columns: ["title", "quantity"], sort: [{ column: "title", direction: "asc" }] }));

  page = await sourceNavigationCDP(url);
  const cdp = page;
  const shot = async (name: string) => {
    if (!shots) return;
    const { data } = await cdp.command("Page.captureScreenshot", { format: "png" });
    await Bun.write(`${shots}/${name}.png`, Buffer.from(data, "base64"));
  };
  const tables = element('nav[aria-label="Tables"]');
  const enter = () =>
    expect
      .poll(
        async () =>
          (await cdp.evaluate(`!!(${tables})`)) ||
          (await cdp.click(named("button", "Open my workspace")).then(() => false, () => false)),
        { timeout: 30000 },
      )
      .toBe(true);
  // Client-side navigation keeps the session-only hub connection (a reload drops it).
  const open = async (path: string) => {
    await cdp.evaluate(
      `(()=>{const a=document.createElement('a');a.href=${JSON.stringify(path)};document.body.appendChild(a);a.click();a.remove();})()`,
    );
    await cdp.until(`location.search===${JSON.stringify(new URL(path, url).search)}`);
  };
  await cdp.navigate(new URL("/", url).href);
  await cdp.command("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.navigate(url);
  await enter();
  for (const label of ["Connect to a hub", "Use a device token"]) {
    const control = named("button,summary", label);
    await cdp.until(`!!(${control})`);
    if (!(await cdp.evaluate(`(${control}).closest('details').open`))) await cdp.click(control);
  }
  const input = (label: string) =>
    `(()=>{const e=${named("label", label)};return e?.control??e?.querySelector('input');})()`;
  await cdp.fill(input("Hub address"), server.url.href.replace(/\/$/, ""));
  await cdp.fill(input("Device token"), "fixture");
  await cdp.click(named("button", "Connect"));
  await cdp.until(`!!(${named("button", "people", tables)})`);

  // 1. Slash menu: /person inserts a mention, /view embeds a saved view.
  await open("/workspace?table=widgets&row=fixture-record");
  const body = element('.record-panel .rich-document [role="textbox"], aside .rich-document [role="textbox"]');
  const editor = `(${body}) ?? [...document.querySelectorAll('.rich-document [role="textbox"]')].at(-1)`;
  await cdp.until(`!!(${editor})?.textContent.includes('Original body')`);
  await cdp.evaluate(
    `(()=>{const e=${editor};e.focus();const p=e.lastElementChild;const s=getSelection();s.selectAllChildren(p);s.collapseToEnd();})()`,
  );
  const slash = async () => {
    await cdp.key("Enter");
    await cdp.command("Input.dispatchKeyEvent", { type: "keyDown", key: "/", text: "/", windowsVirtualKeyCode: 191 });
    await cdp.command("Input.dispatchKeyEvent", { type: "keyUp", key: "/", windowsVirtualKeyCode: 191 });
    await cdp.until(`document.activeElement?.getAttribute('aria-label')==='Filter blocks'`);
  };
  await slash();
  await cdp.command("Input.insertText", { text: "person" });
  await cdp.until(`!![...document.querySelectorAll('.block-menu button')].find(b=>b.textContent.includes('Person'))`);
  await shot("1-slash-person");
  await cdp.key("Enter");
  await cdp.until(`document.activeElement?.getAttribute('aria-label')==='Mention a person'`);
  await cdp.command("Input.insertText", { text: "ada" });
  await cdp.until(`!![...document.querySelectorAll('.link-picker button')].find(b=>b.textContent.includes('Ada Lovelace'))`);
  await shot("2-person-picker");
  await cdp.key("Enter");
  await cdp.until(`(${editor}).querySelector('.iris-mention')?.textContent==='Ada Lovelace'`);
  await slash();
  await cdp.command("Input.insertText", { text: "view" });
  await cdp.key("Enter");
  await cdp.until(`!![...document.querySelectorAll('.link-picker button')].find(b=>b.textContent.includes('Open widgets'))`);
  await cdp.command("Input.insertText", { text: "open" });
  await cdp.until(`[...document.querySelectorAll('.link-picker button')].length===1`);
  await shot("3-view-picker");
  await cdp.key("Enter");
  const embed = `(${editor}).querySelector('.iris-embed')`;
  await cdp.until(`!!(${embed})?.querySelector('table') && (${embed}).innerText.includes('Legacy record')`);
  await shot("4-mention-and-embed");

  // 2. Autosave stores plain Markdown links and sync delivers them to the hub.
  await expect.poll(hubBody, { timeout: 20000 }).toContain("[Ada Lovelace](iris://table/people/row/p-ada)");
  expect(hubBody()).toContain("[Open widgets](iris://table/widgets/view/open-widgets)");
  expect(hubBody()).toContain("Original body");

  // 3. Labels resolve at render time: rename on the hub, reopen, the stored text stays.
  db.db.exec(
    "UPDATE people SET full_name='Ada King',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),hub_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id='p-ada'",
  );
  await open("/workspace?table=people&row=p-ada");
  await cdp.until(`document.body.innerText.includes('Ada King')`);
  await open("/workspace?table=widgets&row=fixture-record");
  await cdp.until(`(${editor})?.querySelector('.iris-mention')?.textContent==='Ada King'`);
  await cdp.until(`!!(${embed})?.querySelector('td')`);
  expect(hubBody()).toContain("[Ada Lovelace](iris://table/people/row/p-ada)");
  await shot("5-reloaded-live-label");

  // 4. Clicking the mention opens the person; Linked from lists the widget.
  await cdp.click(`(${editor}).querySelector('.iris-mention')`);
  const linked = element('section[aria-label="Linked from"]');
  await cdp.until(`location.search.includes('table=people') && (${linked})?.innerText.includes('Fixture record')`);
  expect(await cdp.evaluate(`!!document.querySelector('section[aria-label="Referenced by"]')`)).toBe(true);
  await shot("6-linked-from");
  await cdp.click(named("button", "Open Fixture record", linked));
  await cdp.until(`location.search.includes('table=widgets') && !!(${embed})?.querySelector('td')`);

  // 5. The embed's Open view goes to the saved view itself.
  await cdp.click(`(${embed}).querySelector('button')`);
  await cdp.until(`document.querySelector('select[aria-label="View"]')?.value==='open-widgets'`);
  await shot("7-open-view");

  // 6. A mention whose record is gone keeps its stored text, marked unavailable.
  await open("/workspace?table=widgets&row=second-record");
  await cdp.until(
    `[...document.querySelectorAll('.iris-mention')].some(m=>m.textContent==='Gone person (unavailable)' && m.dataset.state==='unavailable')`,
  );
  await shot("8-unavailable");
  console.log(
    "PASS slash /person mention and /view embed, Markdown link storage synced, render-time label, mention click-through, Linked from, Open view, unavailable target.",
  );
} catch (error) {
  if (page)
    console.error(
      await page.evaluate(
        "document.body.innerText + '\\nFOCUS ' + document.activeElement?.outerHTML.slice(0, 300) + '\\nEDITORS ' + [...document.querySelectorAll('.rich-document [role=textbox]')].map(e => e.outerHTML.slice(0, 3000)).join('\\n')",
      ),
    );
  throw error;
} finally {
  if (page) {
    await page.navigate(new URL("/", url).href).catch(() => {});
    await page.command("Storage.clearDataForOrigin", { origin, storageTypes: "all" }).catch(() => {});
    page.close();
  }
  server.stop(true);
  db.db.close();
  auth.db.close();
}
