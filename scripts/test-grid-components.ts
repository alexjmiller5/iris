import { chromium, expect, type Page } from "@playwright/test";
import { mkdir, unlink, rmdir } from "node:fs/promises";
import { resolve } from "node:path";
import { disposableOrigin, workspacePage } from "./test-origin";
const address =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-grid.localhost:5228/workspace?review";
const origin = disposableOrigin(address);
const routeName = `grid-test-fixture-${process.pid}`;
const route = resolve(import.meta.dir, "../apps/web/src/routes", routeName);
// Test-only route exists only during this runner, never in published assets.
const source = `<script lang="ts">
import {onMount} from 'svelte';
import RecordGrid from '$lib/RecordGrid.svelte';
import FieldEditor from '$lib/FieldEditor.svelte';
import type {CellDraft} from '$lib/record-grid';
let rows = $state(Array.from({length:10000},(_,i)=>({id:'r'+i,title:'Record '+i,qty:i,updated_at:'2026-01-01T00:00:00.000Z'})));
let edit = $state<CellDraft|null>(null), saved = $state(''), fail = $state(false);
let ready=$state(false); onMount(()=>{ready=true});
let editable=$state(true);
let showDuplicates=$state(false), duplicateRaw=$state('["r1","r1"]'), referenceChanges=$state(0);
let properties=$state([{col:'title',label:'Title'},{col:'qty',label:'Quantity',type:'int'}]);
</script>
<main data-ready={ready} style="padding:20px;max-width:100%;">
<button onclick={()=>rows=[...rows].reverse()}>Reverse rows</button>
<button onclick={()=>rows=rows.filter(row=>row.id!==edit?.cell.rowId)}>Remove edited row</button>
<button onclick={()=>fail=!fail}>Toggle failure</button>
<button onclick={()=>editable=!editable}>Toggle readonly</button>
<button onclick={()=>properties=properties.filter(p=>p.col!=='qty')}>Remove quantity column</button>
<output aria-label="Saved patch">{saved}</output>
<button onclick={()=>showDuplicates=true}>Open duplicate references</button>
{#if showDuplicates}<section aria-label="Duplicate references"><FieldEditor id="duplicate-ref" property={{col:'links',type:'multi_ref'}} bind:value={duplicateRaw} references={[{id:'r1',label:'Target'}]} onchange={()=>referenceChanges++} /><output aria-label="Raw references">{duplicateRaw}</output><output aria-label="Reference changes">{referenceChanges}</output></section>{/if}
{#if ready}<RecordGrid {rows} {properties} widths={{qty:96}} busy={false} canCreate={false} bind:edit format={(_,v)=>String(v??'')} canEdit={()=>editable} onbegin={async cell=>rows.find(row=>row.id===cell.rowId)??false} oncommit={async draft=>{if(fail)throw Error('Rejected cell');saved=JSON.stringify(draft);return draft.baseline;}} onopen={async()=>true} onnew={async()=>false} onduplicate={async()=>false} />{/if}
</main>`;
await mkdir(route); // Refuse to overwrite an existing route.
let browser: Awaited<ReturnType<typeof chromium.connectOverCDP>> | undefined;
let page: Page | undefined;
try {
  await Bun.write(resolve(route, "+page.svelte"), source);
  browser = await chromium.connectOverCDP(
    process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
  );
  page = workspacePage(
    browser.contexts().flatMap((c) => c.pages()),
    address,
  );
  if (!page) throw Error("Open the reserved grid fixture workspace page first");
  const errors: string[] = [];
  page.on("pageerror", (error) => {
    errors.push(error.message);
    console.error("PAGE ERROR", error.message);
  });
  page.on("console", (message) => {
    if (message.type() === "error") console.error("CONSOLE", message.text());
  });
  page.on("requestfailed", (request) =>
    console.error("REQUEST FAILED", request.url(), request.failure()),
  );
  const pending = new Set<string>();
  page.on("request", (request) => pending.add(request.url()));
  page.on("requestfinished", (request) => pending.delete(request.url()));
  page.setDefaultTimeout(8000);
  // Register the temporary route before navigating; route generation reloads
  // the currently open page on first compilation.
  await expect
    .poll(async () =>
      (await page!.request.get(origin + "/" + routeName)).status(),
    )
    .toBe(200);
  await page.waitForLoadState("load");
  await page.goto(origin + "/" + routeName);
  await expect(page.locator('main[data-ready="true"]'))
    .toBeVisible({ timeout: 8000 })
    .catch(async (error) => {
      console.error(
        "HYDRATION",
        [...pending],
        await page!.evaluate(() => ({
          ready: document.querySelector("main")?.getAttribute("data-ready"),
          url: location.href,
          resources: performance
            .getEntriesByType("resource")
            .slice(-10)
            .map((r) => r.name),
        })),
      );
      throw error;
    });
  const cells = page.getByRole("gridcell");
  await expect(page.getByRole("grid", { name: "Records" })).toBeVisible();
  await expect.poll(() => cells.count()).toBeGreaterThan(0);
  expect(await cells.count()).toBeLessThan(100);
  await page
    .locator(".grid-scroll")
    .evaluate((el) => (el.scrollTop = el.scrollHeight));
  await expect(
    page.locator('[data-row="r9999"][data-column="qty"]'),
  ).toBeVisible();
  expect(await cells.count()).toBeLessThan(100);
  console.log(
    "PASS 10k render fixture has bounded DOM and reaches the last row (no database query)",
  );
  const cell = page.locator('[data-row="r9999"][data-column="qty"]');
  await cell.click();
  await cell.press("Enter");
  const editor = page.getByRole("group", { name: "Edit Quantity" });
  await editor.getByLabel("Quantity", { exact: true }).fill("17");
  expect((await cell.boundingBox())!.width).toBeCloseTo(
    (await page
      .getByRole("columnheader", { name: "Quantity", exact: true })
      .boundingBox())!.width,
    1,
  );
  await page
    .getByRole("button", { name: "Toggle readonly", exact: true })
    .click();
  await expect(editor.getByLabel("Quantity", { exact: true })).toBeDisabled();
  await expect(
    editor.getByRole("button", { name: "Save cell", exact: true }),
  ).toBeDisabled();
  await expect(
    editor.getByRole("button", { name: "Discard", exact: true }),
  ).toBeEnabled();
  await page
    .getByRole("button", { name: "Toggle readonly", exact: true })
    .click();
  await expect(editor.getByLabel("Quantity", { exact: true })).toHaveValue(
    "17",
  );
  console.log(
    "PASS current editability updates lock cells without losing the draft",
  );
  await page.getByRole("button", { name: "Reverse rows" }).click();
  await expect(editor.getByLabel("Quantity", { exact: true })).toHaveValue(
    "17",
  );
  await page.getByRole("button", { name: "Toggle failure" }).click();
  await editor.getByLabel("Quantity", { exact: true }).press("Escape");
  await expect(editor.getByRole("alert")).toHaveText("Rejected cell");
  await expect(editor.getByLabel("Quantity", { exact: true })).toHaveValue(
    "17",
  );
  await page.getByRole("button", { name: "Remove edited row" }).click();
  await expect(
    page.getByText(
      "This record is no longer in the visible page. Your cell draft is kept.",
    ),
  ).toBeVisible();
  await expect(editor.getByLabel("Quantity", { exact: true })).toHaveValue(
    "17",
  );
  await page.getByRole("button", { name: "Toggle failure" }).click();
  await editor.getByRole("button", { name: "Save cell", exact: true }).click();
  const patch = JSON.parse(
    (await page.getByLabel("Saved patch").textContent()) ?? "{}",
  );
  expect(patch.cell).toEqual({ rowId: "r9999", column: "qty" });
  expect(patch.raw).toBe("17");
  await expect(page.locator('[role="gridcell"][tabindex="0"]')).toHaveCount(1);
  console.log(
    "PASS reorder, failed Escape commit and row removal preserve the original cell identity/draft",
  );
  expect(
    errors.filter((error) => !error.startsWith("ResizeObserver loop")),
  ).toEqual([]);
  const nextCell = page.locator('[data-row="r9998"][data-column="qty"]');
  await nextCell.focus();
  await nextCell.press("Enter");
  await editor
    .getByLabel("Quantity", { exact: true })
    .fill("Retained raw draft");
  await page
    .getByRole("button", { name: "Remove quantity column", exact: true })
    .click();
  await expect(page.locator(".retained")).toContainText("Retained raw draft");
  await page
    .locator(".retained")
    .getByRole("button", { name: "Discard", exact: true })
    .click();
  await expect(page.locator(".retained")).toHaveCount(0);
  await expect(page.locator('[role="gridcell"][tabindex="0"]')).toHaveCount(1);
  console.log(
    "PASS removed property keeps raw draft available for explicit Discard",
  );
  await page.getByRole("button", { name: "Open duplicate references" }).click();
  const referenceGroup = page.getByRole("region", {
    name: "Duplicate references",
  });
  await expect(referenceGroup.locator(".chip")).toHaveCount(1);
  await expect(page.getByLabel("Raw references")).toHaveText('["r1","r1"]');
  await expect(page.getByLabel("Reference changes")).toHaveText("0");
  expect(
    errors.filter((error) => !error.startsWith("ResizeObserver loop")),
  ).toEqual([]);
  console.log(
    "PASS duplicate reference chips preserve stored raw values without edits",
  );
  await page.goto(address);
} finally {
  await page?.goto(address).catch(() => {});
  await browser?.close();
  await unlink(resolve(route, "+page.svelte"));
  await rmdir(route);
}
