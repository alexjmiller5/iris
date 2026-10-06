import { chromium, expect, type Page } from "@playwright/test";
import { mkdir, unlink, rmdir } from "node:fs/promises";
import { resolve } from "node:path";
import { disposableOrigin, workspacePage } from "./test-origin";

// Run against an owned tab and dev server, with no database or personal data.
const address =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-grid.localhost:5267/workspace?review";
const origin = disposableOrigin(address);
const routeName = `grid-focus-fixture-${process.pid}`;
const route = resolve(import.meta.dir, "../apps/web/src/routes", routeName);
const source = `<script lang="ts">
import { onMount } from 'svelte';
import RecordGrid from '$lib/RecordGrid.svelte';
let ready=$state(false), canCreate=$state(true), canTrash=$state(false), reject=$state(false), held=$state(false);
let removeSaved=$state(false), emptyAfterSave=$state(false);
let rows=$state([{id:'a',title:'Alpha',qty:1},{id:'b',title:'Beta',qty:2}]);
let receipt=$state(''), pending=$state(false);
let release: (()=>void)|undefined;
onMount(()=>{ready=true});
</script>
<main data-ready={ready} style="padding:20px">
<label><input type="checkbox" bind:checked={canCreate}/>Allow creation</label>
<label><input type="checkbox" bind:checked={canTrash}/>Allow trash</label>
<label><input type="checkbox" bind:checked={reject}/>Reject save</label>
<label><input type="checkbox" bind:checked={held}/>Hold save</label>
<label><input type="checkbox" bind:checked={removeSaved}/>Saved row leaves view</label>
<label><input type="checkbox" bind:checked={emptyAfterSave}/>Save empties view</label>
<button onclick={()=>release?.()}>Release save</button>
<output aria-label="Receipt">{receipt}</output><output aria-label="Pending">{pending}</output>
<button>Before grid</button>
<button disabled>Disabled before</button><button hidden>Hidden before</button>
<button style="visibility:hidden">Invisible before</button>
<div inert><button>Inert before</button></div>
{#if ready}<RecordGrid {rows} properties={[{col:'title',label:'Title'},{col:'qty',label:'Quantity',type:'int'}]}
 widths={{}} busy={false} {canCreate} {canTrash} format={(_,v)=>String(v??'')} canEdit={()=>true}
 onbegin={async cell=>rows.find(row=>row.id===cell.rowId)??false}
 oncommit={async draft=>{
   pending=true;
   if(held) await new Promise<void>(done=>release=done);
   pending=false;
   if(reject) throw Error('Rejected fixture edit');
   const saved={...draft.baseline,[draft.cell.column]:draft.raw};
   rows=rows.map(row=>row.id===draft.cell.rowId?saved as typeof row:row);
   if(removeSaved) rows=rows.filter(row=>row.id!==draft.cell.rowId);
   if(emptyAfterSave) rows=[];
   receipt=JSON.stringify({id:draft.cell.rowId,column:draft.cell.column,value:draft.raw});
   return saved;
 }} onopen={async()=>true} onnew={async()=>true} onduplicate={async()=>true}/>{/if}
<button hidden>Hidden after</button><fieldset disabled><button>Disabled after</button></fieldset>
<button style="visibility:hidden">Invisible after</button><button tabindex="-1">Untabbable after</button>
<div inert><button>Inert after</button></div><button>After grid</button>
</main>`;

await mkdir(route);
let browser: Awaited<ReturnType<typeof chromium.connectOverCDP>> | undefined;
let page: Page | undefined;
try {
  await Bun.write(resolve(route, "+page.svelte"), source);
  browser = await chromium.connectOverCDP(
    process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
  );
  page = workspacePage(
    browser.contexts().flatMap((context) => context.pages()),
    address,
  );
  if (!page) throw Error("Open the reserved focus fixture workspace tab first");
  const owned = page;
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.setDefaultTimeout(5000);
  page.setDefaultNavigationTimeout(15000);
  await expect
    .poll(async () =>
      (await owned.request.get(origin + "/" + routeName)).status(),
    )
    .toBe(200);
  await page.waitForLoadState("load");
  async function reset() {
    await owned.goto(origin + "/" + routeName);
    await expect(owned.locator('main[data-ready="true"]')).toBeVisible();
  }
  const cell = (row: string, col: string) =>
    owned.locator(`[data-row="${row}"][data-column="${col}"]`);
  const field = (col: string) =>
    owned
      .getByRole("group", {
        name: `Edit ${col === "title" ? "Title" : "Quantity"}`,
        exact: true,
      })
      .getByLabel(col === "title" ? "Title" : "Quantity", { exact: true });
  async function begin(row: string, col: string, value: string) {
    await cell(row, col).focus();
    await cell(row, col).press("Enter");
    await field(col).fill(value);
  }
  async function receipt(row: string, col: string, value: string) {
    await expect(owned.getByLabel("Receipt")).toHaveText(
      JSON.stringify({ id: row, column: col, value }),
    );
    await expect(owned.locator("[data-cell-editor]")).toHaveCount(0);
  }
  async function check(name: string, body: () => Promise<void>) {
    if (
      process.env.LIFE_UI_FOCUS_CASE &&
      !name.includes(process.env.LIFE_UI_FOCUS_CASE)
    )
      return;
    await reset();
    try {
      await body();
    } catch (error) {
      console.error(
        "FAIL",
        name,
        "focused:",
        await owned.evaluate(() => document.activeElement?.outerHTML),
      );
      throw error;
    }
    console.log("PASS", name);
  }
  await check(
    "backward first edited cell saves and exits before the grid",
    async () => {
      await begin("a", "title", "Saved backwards");
      await field("title").press("Shift+Tab");
      await receipt("a", "title", "Saved backwards");
      await expect(
        owned.getByRole("button", { name: "Before grid", exact: true }),
      ).toBeFocused();
      await owned.keyboard.press("Tab");
      await expect(cell("a", "title")).toBeFocused();
    },
  );
  await check(
    "forward last edited cell saves and reaches creation",
    async () => {
      await begin("b", "qty", "42");
      await field("qty").press("Tab");
      await receipt("b", "qty", "42");
      await expect(
        owned.getByRole("button", { name: "New record at bottom" }),
      ).toBeFocused();
      await owned.keyboard.press("Shift+Tab");
      await expect(cell("b", "qty")).toBeFocused();
    },
  );
  await check(
    "forward exit skips disabled creation and hidden/inert controls",
    async () => {
      await owned.getByLabel("Allow creation").uncheck();
      await begin("b", "qty", "43");
      await field("qty").press("Tab");
      await receipt("b", "qty", "43");
      await expect(
        owned.getByRole("button", { name: "After grid", exact: true }),
      ).toBeFocused();
    },
  );
  await check(
    "forward exit reaches an enabled trash action when creation is unavailable",
    async () => {
      await owned.getByLabel("Allow creation").uncheck();
      await owned.getByLabel("Allow trash").check();
      await begin("b", "qty", "46");
      await field("qty").press("Tab");
      await receipt("b", "qty", "46");
      await expect(
        owned.getByRole("button", {
          name: "Trash selected record",
          exact: true,
        }),
      ).toBeFocused();
    },
  );
  for (const refresh of ["Saved row leaves view", "Save empties view"]) {
    for (const [row, col, key, value, target] of [
      ["a", "title", "Shift+Tab", "Hidden after save", "Before grid"],
      ["b", "qty", "Tab", "47", "New record at bottom"],
    ]) {
      await check(`${refresh}: ${key} still exits after refresh`, async () => {
        await owned.getByLabel(refresh).check();
        await begin(row, col, value);
        await field(col).press(key);
        await receipt(row, col, value);
        await expect(cell(row, col)).toHaveCount(0);
        await expect(
          owned.getByRole("button", { name: target, exact: true }),
        ).toBeFocused();
      });
    }
  }
  await check("unedited edges keep native traversal", async () => {
    await cell("a", "title").press("Shift+Tab");
    await expect(
      owned.getByRole("button", { name: "Before grid", exact: true }),
    ).toBeFocused();
    await cell("b", "qty").press("Tab");
    await expect(
      owned.getByRole("button", { name: "New record at bottom" }),
    ).toBeFocused();
    await expect(owned.getByLabel("Receipt")).toBeEmpty();
  });
  await check("interior tabs save and move in both directions", async () => {
    await begin("a", "qty", "44");
    await field("qty").press("Tab");
    await receipt("a", "qty", "44");
    await expect(cell("b", "title")).toBeFocused();
    await begin("b", "title", "Back one cell");
    await field("title").press("Shift+Tab");
    await receipt("b", "title", "Back one cell");
    await expect(cell("a", "qty")).toBeFocused();
  });
  for (const [row, col, key, value] of [
    ["a", "title", "Shift+Tab", "Unsaved title"],
    ["b", "qty", "Tab", "45"],
  ]) {
    await check(
      `rejected ${key} retains the draft and recovery actions`,
      async () => {
        await owned.getByLabel("Reject save").check();
        await begin(row, col, value);
        await field(col).press(key);
        await expect(owned.getByRole("alert")).toHaveText(
          "Rejected fixture edit",
        );
        await expect(field(col)).toHaveValue(value);
        await expect(field(col)).toBeFocused();
        await expect(owned.getByLabel("Receipt")).toBeEmpty();
        await field(col).press("Tab");
        await expect(
          owned.getByRole("button", {
            name: `Clear ${col === "title" ? "Title" : "Quantity"}`,
            exact: true,
          }),
        ).toBeFocused();
        await owned.keyboard.press("Tab");
        await expect(
          owned.getByRole("button", { name: "Save cell", exact: true }),
        ).toBeFocused();
        await owned.keyboard.press("Tab");
        await expect(
          owned.getByRole("button", { name: "Discard", exact: true }),
        ).toBeFocused();
        await expect(field(col)).toHaveValue(value);
      },
    );
  }
  await check(
    "held receipt never exits early or loses the pending draft",
    async () => {
      await owned.getByLabel("Hold save").check();
      await begin("a", "title", "Awaited title");
      await field("title").press("Shift+Tab");
      await expect(owned.getByLabel("Pending")).toHaveText("true");
      await expect(field("title")).toHaveValue("Awaited title");
      await expect(
        owned.getByRole("button", { name: "Before grid", exact: true }),
      ).not.toBeFocused();
      await owned
        .getByRole("button", { name: "Release save", exact: true })
        .click();
      await receipt("a", "title", "Awaited title");
      await expect(
        owned.getByRole("button", { name: "Before grid", exact: true }),
      ).toBeFocused();
    },
  );
  expect(
    errors.filter((error) => !error.startsWith("ResizeObserver loop")),
  ).toEqual([]);
} finally {
  await page?.goto(address).catch(() => {});
  await browser?.close();
  await unlink(resolve(route, "+page.svelte"));
  await rmdir(route);
}
