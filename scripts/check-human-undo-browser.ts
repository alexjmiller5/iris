/** Run against one explicitly owned disposable sample-workspace target. */
import { strict as assert } from "node:assert";
import { parseArgs } from "node:util";
const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    target: { type: "string" },
    port: { type: "string", default: "9222" },
  },
});
if (!values.target) throw Error("--target is required");
const targets = (await (
  await fetch(`http://127.0.0.1:${values.port}/json/list`)
).json()) as { id: string; url: string; webSocketDebuggerUrl: string }[];
const target = targets.find((t) => t.id === values.target);
if (
  !target ||
  !/^http:\/\/iris-human-undo\.localhost:\d+\//.test(target.url)
)
  throw Error("Use an owned disposable human-undo localhost origin");
// Direct target connection avoids attaching to every other browser tab. The
// installed one-shot helper lacks modifier-key input, which this regression needs.
const ws = new WebSocket(target.webSocketDebuggerUrl);
const pending = new Map<
  number,
  { resolve: (v: any) => void; reject: (e: Error) => void }
>();
let id = 0;
ws.onmessage = (e) => {
  const m = JSON.parse(String(e.data));
  if (m.method === "Page.javascriptDialogOpening") {
    void send("Page.handleJavaScriptDialog", { accept: true });
    return;
  }
  const p = pending.get(m.id);
  if (p) {
    pending.delete(m.id);
    m.error ? p.reject(Error(JSON.stringify(m.error))) : p.resolve(m.result);
  }
};
await new Promise<void>((r, j) => {
  ws.onopen = () => r();
  ws.onerror = () => j(Error("Browser connection failed"));
});
function send(method: string, params: object = {}) {
  return new Promise<any>((resolve, reject) => {
    const n = ++id;
    const timer = setTimeout(() => {
      pending.delete(n);
      reject(Error("CDP timeout: " + method));
    }, 10000);
    pending.set(n, {
      resolve: (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      reject: (e) => {
        clearTimeout(timer);
        reject(e);
      },
    });
    ws.send(JSON.stringify({ id: n, method, params }));
  });
}
async function evaluate(expression: string) {
  const r = await send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (r.exceptionDetails)
    throw Error(
      r.exceptionDetails.exception?.description ?? r.exceptionDetails.text,
    );
  return r.result.value;
}
const button = (name: string) =>
  `[...document.querySelectorAll('button')].find(b=>b.textContent.trim()===${JSON.stringify(name)})`;
async function wait(expression: string) {
  for (let i = 0; i < 100; i++) {
    if (await evaluate(expression)) return;
    await Bun.sleep(50);
  }
  throw Error("Timed out: " + expression);
}
async function click(name: string) {
  await wait(`!!${button(name)} && !${button(name)}.disabled`);
  await evaluate(`${button(name)}.click()`);
}
async function stored() {
  return evaluate(
    `(async()=>{const {WorkspaceDatabase}=await import('/src/lib/database.ts');const db=new WorkspaceDatabase();try{await db.request('open',{demo:true});return await db.request('rows',{view:{table:'notes'}});}finally{db.close();}})()`,
  );
}
async function savedTitle(expected: string) {
  for (let i = 0; i < 100; i++) {
    if ((await stored()).some((r: any) => r.title === expected)) return;
    await Bun.sleep(50);
  }
  throw Error("Missing persisted title " + expected);
}
async function change(title: string) {
  await evaluate(
    `(()=>{const input=document.querySelector('[aria-label="Title"]');input.value=${JSON.stringify(title)};input.dispatchEvent(new Event('input',{bubbles:true}));})()`,
  );
  await click("Save record");
  await savedTitle(title);
}
async function commandZ() {
  await send("Input.dispatchKeyEvent", {
    type: "keyDown",
    key: "z",
    code: "KeyZ",
    windowsVirtualKeyCode: 90,
    modifiers: 4,
    commands: ["undo"],
  });
  await send("Input.dispatchKeyEvent", {
    type: "keyUp",
    key: "z",
    code: "KeyZ",
    windowsVirtualKeyCode: 90,
    modifiers: 4,
  });
}
let checks = 0;
function pass(label: string) {
  checks++;
  console.log("PASS " + label);
}
const timeout = setTimeout(() => {
  ws.close();
  throw Error("Human undo browser watchdog");
}, 90000);
try {
  await send("Page.enable");
  await send("Storage.clearDataForOrigin", {
    origin: new URL(target.url).origin,
    storageTypes: "all",
  });
  await send("Page.bringToFront");
  await send("Emulation.setFocusEmulationEnabled", { enabled: true });
  if (await evaluate(`!!${button("Try sample workspace")}`))
    await click("Try sample workspace");
  await wait(`!!${button("A place to start")}`);
  if (!(await evaluate(`!!document.querySelector('[aria-label="Title"]')`)))
    await click("A place to start");
  await wait(`!!document.querySelector('[aria-label="Title"]')`);
  await change("Human undo first");
  await change("Human undo second");
  await evaluate(`document.querySelector('[aria-label="Title"]').blur()`);
  await commandZ();
  await savedTitle("Human undo first");
  pass("Cmd-Z reverses the latest saved human edit");
  await click("Undo last saved change");
  await savedTitle("A place to start");
  pass("Undo button reverses the preceding edit");
  // Trusted typing must stay in native input undo and never consume a saved receipt.
  console.log("STEP save after repeated undo");
  await change("Saved text baseline");
  console.log("STEP focus text input");
  await evaluate(
    `(()=>{const e=document.querySelector('[aria-label="Title"]');e.focus();e.setSelectionRange(e.value.length,e.value.length);})()`,
  );
  await send("Input.insertText", { text: " typed" });
  console.log("STEP trusted text inserted");
  await wait(
    `document.querySelector('[aria-label="Title"]').value==='Saved text baseline typed'`,
  );
  console.log("STEP text command Z");
  await commandZ();
  console.log("STEP text command returned");
  await wait(
    `document.querySelector('[aria-label="Title"]').value==='Saved text baseline'`,
  );
  await savedTitle("Saved text baseline");
  pass("focused typing undo leaves the persisted human change intact");
  await evaluate(`document.querySelector('[aria-label="Title"]').blur()`);
  await commandZ();
  await savedTitle("A place to start");
  pass("leaving text focus restores saved-change Cmd-Z");
  // Close via accessible control before saved-view operations.
  await evaluate(
    `document.querySelector('[aria-label="Close record"]').click()`,
  );
  await wait(`!document.querySelector('[aria-label="Title"]')`);
  await evaluate(
    `(()=>{const e=document.querySelector('[aria-label="View name"]');e.value='Human undo view';e.dispatchEvent(new Event('input',{bubbles:true}));})()`,
  );
  await click("Save as");
  await wait(
    `!!${button("Undo last saved change")} && !${button("Undo last saved change")}.disabled`,
  );
  await click("Undo last saved change");
  await wait(`document.querySelector('[aria-label="View"]').value===''`);
  pass("saved-view creation can be undone through the same visible button");
  assert.equal(checks, 5);
  console.log(`${checks} browser checks passed`);
} finally {
  clearTimeout(timeout);
  // Only this disposable origin is cleared, after its UI database has closed.
  try {
    await send("Page.navigate", { url: "about:blank" });
    await send("Storage.clearDataForOrigin", {
      origin: new URL(target.url).origin,
      storageTypes: "all",
    });
  } finally {
    ws.close();
  }
}
