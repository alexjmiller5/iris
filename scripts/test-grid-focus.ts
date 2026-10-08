import { expect } from "@playwright/test";
import { mkdir, unlink, rmdir } from "node:fs/promises";
import { resolve } from "node:path";
import { disposableOrigin } from "./test-origin";

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
let workflow=$state(false), markdown=$state(false), linkOpens=$state(false);
const body='[Related record](https://example.test/source-record)\\n\\n![Retained fixture](/v1/files/fixture/image.png)';
let fileReceipt=$state(''), linkReceipt=$state(''), disposedFiles=$state(0);
let rows=$state([{id:'a',title:'Alpha',qty:1,body,updated_at:'2026-01-01T00:00:00.000Z'},{id:'b',title:'Beta',qty:2,body,updated_at:'2026-01-01T00:00:00.000Z'}]);
let receipt=$state(''), pending=$state(false), actionReceipt=$state(''), actionCalls=$state(0);
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
<label><input type="checkbox" bind:checked={workflow}/>Workflow layout</label>
<label><input type="checkbox" bind:checked={markdown}/>Markdown column</label>
<label><input type="checkbox" bind:checked={linkOpens}/>Accept link</label>
<button onclick={()=>release?.()}>Release save</button>
<output aria-label="Receipt">{receipt}</output><output aria-label="Pending">{pending}</output>
<output aria-label="Action receipt">{actionReceipt}</output><output aria-label="Action calls">{actionCalls}</output>
<output aria-label="File receipt">{fileReceipt}</output><output aria-label="Link receipt">{linkReceipt}</output>
<output aria-label="Disposed files">{disposedFiles}</output>
<button>Before grid</button>
<button disabled>Disabled before</button><button hidden>Hidden before</button>
<button style="visibility:hidden">Invisible before</button>
<div inert><button>Inert before</button></div>
{#if ready}<RecordGrid {rows} properties={markdown?[{col:'body',label:'Body',type:'markdown'}]:[{col:'title',label:'Title'},{col:'qty',label:'Quantity',type:'int'}]}
 widths={{}} busy={false} {canCreate} {canTrash} format={(_,v)=>String(v??'')} canEdit={()=>true}
 actions={workflow?[{id:'reset',label:'Reset quantity',values:{qty:0}}]:[]}
 actionLayout={workflow?[{kind:'action',id:'reset'},{kind:'column',id:'qty'},{kind:'column',id:'title'}]:undefined}
 resolveFile={async(key,signal)=>{
   fileReceipt=JSON.stringify({key,abortable:signal instanceof AbortSignal});
   const canvas=document.createElement('canvas');canvas.width=1;canvas.height=1;
   const blob=await new Promise<Blob>(done=>canvas.toBlob(value=>done(value!),'image/png'));
   const url=URL.createObjectURL(blob);
   return {url,contentType:'image/png',dispose(){URL.revokeObjectURL(url);disposedFiles++;}};
 }}
 onopenlink={async href=>{linkReceipt=JSON.stringify({href,committed:!!receipt});return linkOpens;}}
 canRunAction={true} onaction={async(actionId,row)=>{actionCalls++;actionReceipt=JSON.stringify({actionId,id:row.id,revision:row.updated_at})}}
 onbegin={async cell=>rows.find(row=>row.id===cell.rowId)??false}
 oncommit={async draft=>{
   pending=true;
   if(held) await new Promise<void>(done=>release=done);
   pending=false;
   if(reject) throw Error('Rejected fixture edit');
   const saved={...draft.baseline,[draft.cell.column]:draft.raw,updated_at:'2026-01-02T00:00:00.000Z'};
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

// Connect only to the explicitly allocated page. A browser-wide Playwright
// attachment waits on unrelated targets in the shared agent Chrome.
const endpoint = process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222";
const targetID = process.env.LIFE_UI_TEST_TARGET;
if (!targetID)
  throw Error("Set LIFE_UI_TEST_TARGET to the owned synthetic page ID");
const targets = await (await fetch(endpoint + "/json/list")).json();
const target = targets.find(
  (entry: { id: string; type: string; url: string }) =>
    entry.id === targetID &&
    entry.type === "page" &&
    new URL(entry.url).origin === origin,
);
if (!target) throw Error("Owned synthetic target missing");
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise<void>((resolve, reject) => {
  socket.onopen = () => resolve();
  socket.onerror = reject;
});
let nextID = 0;
const pending = new Map<
  number,
  {
    resolve(value: any): void;
    reject(reason: unknown): void;
    timer: ReturnType<typeof setTimeout>;
  }
>();
const errors: string[] = [];
socket.onmessage = (message) => {
  const data = JSON.parse(String(message.data));
  const request = pending.get(data.id);
  if (request) {
    pending.delete(data.id);
    clearTimeout(request.timer);
    data.error
      ? request.reject(Error(JSON.stringify(data.error)))
      : request.resolve(data.result);
  } else if (data.method === "Runtime.exceptionThrown")
    errors.push(data.params.exceptionDetails.text);
};
function call(
  method: string,
  params: Record<string, unknown> = {},
): Promise<any> {
  return new Promise((resolve, reject) => {
    const id = ++nextID;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(Error("CDP timeout: " + method));
    }, 10000);
    pending.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, method, params }));
  });
}
async function evaluate(expression: string) {
  const result = await call("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
    userGesture: true,
  });
  if (result.exceptionDetails)
    throw Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
const q = JSON.stringify;
const selector = (css: string) => `document.querySelector(${q(css)})`;
const button = (name: string) =>
  `[...document.querySelectorAll('button')].find(e => (e.getAttribute('aria-label') || e.textContent.trim()) === ${q(name)})`;
const output = (label: string) => selector(`output[aria-label="${label}"]`);
const cell = (row: string, col: string) =>
  selector(`[data-row="${row}"][data-column="${col}"]`);
const field = (col: string) =>
  selector(
    `[data-cell-editor] [aria-label="${col === "title" ? "Title" : "Quantity"}"]`,
  );
async function until(expression: string) {
  await expect
    .poll(() => evaluate(expression), { timeout: 10000, message: expression })
    .toBe(true);
}
async function text(expression: string, expected: string) {
  await expect
    .poll(() => evaluate(`(${expression})?.textContent`), { timeout: 10000 })
    .toBe(expected);
}
async function focused(expression: string) {
  await until(`document.activeElement === (${expression})`);
}
async function focus(expression: string) {
  await until(`!!(${expression})`);
  await evaluate(`(${expression}).focus()`);
  await focused(expression);
}
async function key(name: string) {
  const parts = name.split("+");
  const key = parts.at(-1)!;
  const codes: Record<string, number> = {
    Tab: 9,
    Enter: 13,
    Escape: 27,
    ArrowLeft: 37,
    ArrowUp: 38,
    ArrowRight: 39,
    ArrowDown: 40,
  };
  const modifiers = parts.includes("Shift") ? 8 : 0;
  await call("Input.dispatchKeyEvent", {
    type: "keyDown",
    key,
    code: key,
    windowsVirtualKeyCode: codes[key],
    modifiers,
    ...(key === "Enter" ? { text: "\r" } : {}),
  });
  await call("Input.dispatchKeyEvent", {
    type: "keyUp",
    key,
    code: key,
    windowsVirtualKeyCode: codes[key],
    modifiers,
  });
}
async function press(expression: string, name: string) {
  await focus(expression);
  await key(name);
}
async function click(expression: string) {
  await until(`!!(${expression}) && !(${expression}).disabled`);
  await evaluate(
    `(${expression}).scrollIntoView({block:'center',inline:'center',behavior:'instant'})`,
  );
  let point: { x: number; y: number; hit: boolean } | undefined;
  let previous: typeof point;
  let stable = 0;
  for (let attempt = 0; attempt < 30; attempt++) {
    await Bun.sleep(50);
    point = await evaluate(
      `(()=>{const e=${expression};const r=[...e.getClientRects()].find(r=>r.width>0&&r.height>0);const x=r.x+r.width/2,y=r.y+r.height/2;const hit=document.elementFromPoint(x,y);return {x,y,hit:hit===e||e.contains(hit)};})()`,
    );
    if (
      point?.hit &&
      previous &&
      Math.abs(point.x - previous.x) < 0.5 &&
      Math.abs(point.y - previous.y) < 0.5
    )
      stable++;
    else stable = 0;
    if (stable >= 2) break;
    previous = point;
  }
  if (!point?.hit || stable < 2)
    throw Error("Owned fixture control is obscured or moving: " + expression);
  const { x, y } = point;
  await call("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
  await call("Input.dispatchMouseEvent", {
    type: "mousePressed",
    button: "left",
    clickCount: 1,
    x,
    y,
  });
  await call("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    button: "left",
    clickCount: 1,
    x,
    y,
  });
}
async function toggle(label: string) {
  await click(
    `[...document.querySelectorAll('label')].find(e=>e.textContent.trim()===${q(label)}).querySelector('input')`,
  );
}
async function fill(expression: string, value: string) {
  await focus(expression);
  await evaluate(`(${expression}).select()`);
  await call("Input.insertText", { text: value });
  await until(`(${expression})?.value === ${q(value)}`);
}
async function begin(row: string, col: string, value: string) {
  await press(cell(row, col), "Enter");
  await fill(field(col), value);
}
async function receipt(row: string, col: string, value: string) {
  await text(
    output("Receipt"),
    JSON.stringify({ id: row, column: col, value }),
  );
  await until(`!document.querySelector('[data-cell-editor]')`);
}
async function reset() {
  await call("Page.navigate", { url: origin + "/" + routeName });
  await until(
    `location.pathname === ${q("/" + routeName)} && document.readyState==='complete' && !!document.querySelector('#svelte-announcer') && !!document.querySelector('main[data-ready="true"]')`,
  );
  await call("Page.bringToFront");
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
      await evaluate("document.activeElement?.outerHTML"),
    );
    throw error;
  }
  console.log("PASS", name);
}
await mkdir(route);
try {
  await Bun.write(resolve(route, "+page.svelte"), source);
  await expect
    .poll(async () => (await fetch(origin + "/" + routeName)).status, {
      timeout: 15000,
    })
    .toBe(200);
  await call("Page.enable");
  await call("Runtime.enable");
  await check(
    "backward first edited cell saves and exits before the grid",
    async () => {
      await begin("a", "title", "Saved backwards");
      await key("Shift+Tab");
      await receipt("a", "title", "Saved backwards");
      await focused(button("Before grid"));
      await key("Tab");
      await focused(cell("a", "title"));
    },
  );
  await check(
    "forward last edited cell saves and reaches creation",
    async () => {
      await begin("b", "qty", "42");
      await key("Tab");
      await receipt("b", "qty", "42");
      await focused(button("New record at bottom"));
      await key("Shift+Tab");
      await focused(cell("b", "qty"));
    },
  );
  await check(
    "forward exit skips disabled creation and hidden/inert controls",
    async () => {
      await toggle("Allow creation");
      await begin("b", "qty", "43");
      await key("Tab");
      await receipt("b", "qty", "43");
      await focused(button("After grid"));
    },
  );
  await check(
    "forward exit reaches an enabled trash action when creation is unavailable",
    async () => {
      await toggle("Allow creation");
      await toggle("Allow trash");
      await begin("b", "qty", "46");
      await key("Tab");
      await receipt("b", "qty", "46");
      await focused(button("Move to trash"));
    },
  );
  for (const refresh of ["Saved row leaves view", "Save empties view"])
    for (const [row, col, direction, value, destination] of [
      ["a", "title", "Shift+Tab", "Hidden after save", "Before grid"],
      ["b", "qty", "Tab", "47", "New record at bottom"],
    ])
      await check(
        `${refresh}: ${direction} still exits after refresh`,
        async () => {
          await toggle(refresh);
          await begin(row, col, value);
          await key(direction);
          await receipt(row, col, value);
          await until(`!(${cell(row, col)})`);
          await focused(button(destination));
        },
      );
  await check("unedited edges keep native traversal", async () => {
    await press(cell("a", "title"), "Shift+Tab");
    await focused(button("Before grid"));
    await press(cell("b", "qty"), "Tab");
    await focused(button("New record at bottom"));
    await text(output("Receipt"), "");
  });
  await check("interior tabs save and move in both directions", async () => {
    await begin("a", "qty", "44");
    await key("Tab");
    await receipt("a", "qty", "44");
    await focused(cell("b", "title"));
    await begin("b", "title", "Back one cell");
    await key("Shift+Tab");
    await receipt("b", "title", "Back one cell");
    await focused(cell("a", "qty"));
  });
  for (const [row, col, direction, value] of [
    ["a", "title", "Shift+Tab", "Unsaved title"],
    ["b", "qty", "Tab", "45"],
  ])
    await check(
      `rejected ${direction} retains the draft and recovery actions`,
      async () => {
        await toggle("Reject save");
        await begin(row, col, value);
        await key(direction);
        await text(selector('[role="alert"]'), "Rejected fixture edit");
        await focused(field(col));
        await until(`(${field(col)}).value === ${q(value)}`);
        await text(output("Receipt"), "");
        await key("Tab");
        await focused(
          button(`Clear ${col === "title" ? "Title" : "Quantity"}`),
        );
        await key("Tab");
        await focused(button("Save cell"));
        await key("Tab");
        await focused(button("Discard"));
        await until(`(${field(col)}).value === ${q(value)}`);
      },
    );
  await check("backward navigation waits for the save receipt", async () => {
    await toggle("Hold save");
    await begin("a", "title", "Awaited title");
    await key("Shift+Tab");
    await text(output("Pending"), "true");
    await until(`(${field("title")}).disabled`);
    await text(output("Receipt"), "");
    await click(button("Release save"));
    await receipt("a", "title", "Awaited title");
    await focused(button("Before grid"));
  });
  const action = (row: string) =>
    `(${cell(row, "title")})?.closest('[role="row"]').querySelector('button[aria-label="Reset quantity"]')`;
  const actionReceipt = (id: string, saved: boolean) =>
    text(
      output("Action receipt"),
      JSON.stringify({
        actionId: "reset",
        id,
        revision: saved
          ? "2026-01-02T00:00:00.000Z"
          : "2026-01-01T00:00:00.000Z",
      }),
    );
  await check(
    "workflow keyboard follows rendered data order and starts after a leading action",
    async () => {
      await toggle("Workflow layout");
      await press(button("Before grid"), "Tab");
      await focused(action("a"));
      await key("Tab");
      await focused(cell("a", "qty"));
      await key("ArrowRight");
      await focused(cell("a", "title"));
      await key("ArrowLeft");
      await focused(cell("a", "qty"));
      await press(cell("a", "title"), "Tab");
      await focused(cell("b", "qty"));
      await key("Shift+Tab");
      await focused(cell("a", "title"));
    },
  );
  await check(
    "workflow edited tabs preserve drafts and follow rendered data order",
    async () => {
      await toggle("Workflow layout");
      await begin("a", "qty", "51");
      await key("Tab");
      await receipt("a", "qty", "51");
      await focused(cell("a", "title"));
      await begin("a", "title", "Saved visual order");
      await key("Shift+Tab");
      await receipt("a", "title", "Saved visual order");
      await focused(cell("a", "qty"));
    },
  );
  for (const refresh of [null, "Saved row leaves view", "Save empties view"])
    await check(
      `workflow action uses saved revision after ${refresh ?? "normal refresh"}`,
      async () => {
        await toggle("Workflow layout");
        if (refresh) await toggle(refresh);
        await begin("a", "qty", "52");
        await click(action("a"));
        await receipt("a", "qty", "52");
        await actionReceipt("a", true);
        await text(output("Action calls"), "1");
      },
    );
  await check(
    "workflow action retains the clicked row when another row was saved",
    async () => {
      await toggle("Workflow layout");
      await begin("a", "qty", "53");
      await click(action("b"));
      await receipt("a", "qty", "53");
      await actionReceipt("b", false);
    },
  );
  await check(
    "workflow action does not run after a rejected save",
    async () => {
      await toggle("Workflow layout");
      await toggle("Reject save");
      await begin("a", "qty", "54");
      await click(action("a"));
      await text(selector('[role="alert"]'), "Rejected fixture edit");
      await until(`(${field("qty")}).value==='54'`);
      await text(output("Action calls"), "0");
    },
  );
  await check(
    "workflow action waits for the authoritative saved receipt",
    async () => {
      await toggle("Workflow layout");
      await toggle("Hold save");
      await begin("a", "qty", "55");
      await click(action("a"));
      await text(output("Pending"), "true");
      await text(output("Action calls"), "0");
      await until(
        `(${action("a")}).disabled && (${field("qty")}).value==='55'`,
      );
      await click(button("Release save"));
      await receipt("a", "qty", "55");
      await actionReceipt("a", true);
      await text(output("Action calls"), "1");
    },
  );
  const rich = selector('[data-cell-editor] [contenteditable="true"]');
  async function beginMarkdown() {
    await toggle("Markdown column");
    await press(cell("a", "body"), "Enter");
    await until(`!!(${rich})`);
  }
  await check(
    "inline Markdown resolves retained images and releases them on discard",
    async () => {
      await beginMarkdown();
      await text(
        output("File receipt"),
        JSON.stringify({ key: "fixture/image.png", abortable: true }),
      );
      await until(
        `(()=>{const image=document.querySelector('[data-type="retained-image"] img');return !!image && image.src.startsWith('blob:') && image.naturalWidth===1;})()`,
      );
      await click(button("Discard"));
      await text(output("Disposed files"), "1");
      await text(output("Receipt"), "");
    },
  );
  for (const accept of [false, true])
    await check(
      `inline Markdown ${accept ? "accepted" : "canceled"} source link preserves the live draft without saving`,
      async () => {
        if (accept) await toggle("Accept link");
        await beginMarkdown();
        await focus(rich);
        await evaluate(
          `(()=>{const range=document.createRange();range.selectNodeContents((${rich}).querySelector('p'));range.collapse(false);const selection=getSelection();selection.removeAllRanges();selection.addRange(range);})()`,
        );
        await call("Input.insertText", { text: " Unsaved fixture draft" });
        await click(`(${rich}).querySelector('a')`);
        const destination = selector('[aria-label="Open document link"]');
        await click(button("Open in workspace"));
        await text(
          output("Link receipt"),
          JSON.stringify({
            href: "https://example.test/source-record",
            committed: false,
          }),
        );
        if (accept) await until(`!(${destination})`);
        else
          await until(
            `!!(${destination}) && (${destination}).querySelector('a')?.href==='https://example.test/source-record'`,
          );
        await until(`(${rich}).textContent.includes('Unsaved fixture draft')`);
        await text(output("Receipt"), "");
        await click(button("Body source"));
        await until(
          `document.querySelector('textarea[aria-label="Body"]').value.includes('Unsaved fixture draft')`,
        );
      },
    );
  expect(
    errors.filter((error) => !error.startsWith("ResizeObserver loop")),
  ).toEqual([]);
} finally {
  await call("Page.navigate", { url: address }).catch(() => {});
  socket.close();
  for (const request of pending.values()) clearTimeout(request.timer);
  await unlink(resolve(route, "+page.svelte"));
  await rmdir(route);
}
