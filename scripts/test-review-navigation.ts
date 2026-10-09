import { disposableOrigin } from "./test-origin";

const address =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-navigation.localhost:5237/workspace?review&proposal=synthetic-review";
const origin = disposableOrigin(address);
const proposal = new URL(address).searchParams.get("proposal");
const targetId = process.env.LIFE_UI_TEST_TARGET;
if (!proposal || !targetId)
  throw new Error("Set an owned page target and synthetic proposal");
const pages = await (
  await fetch(
    `${process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222"}/json/list`,
  )
).json();
const page = pages.find(
  (page: { id: string; type: string; url: string }) =>
    page.id === targetId &&
    page.type === "page" &&
    new URL(page.url).origin === origin,
);
if (!page) throw new Error("Open the owned reserved fixture page first");
const ws = new WebSocket(page.webSocketDebuggerUrl);
let next = 0;
const pending = new Map<
  number,
  { resolve: (value: any) => void; reject: (error: Error) => void }
>();
const opened = new Promise<void>((resolve, reject) => {
  ws.onopen = () => resolve();
  ws.onerror = () => reject(new Error("CDP connection failed"));
});
ws.onmessage = (event) => {
  const message = JSON.parse(String(event.data));
  const call = pending.get(message.id);
  if (call) {
    pending.delete(message.id);
    message.error
      ? call.reject(new Error(JSON.stringify(message.error)))
      : call.resolve(message.result);
  }
};
async function send(method: string, params: Record<string, unknown>) {
  await opened;
  return Promise.race([
    new Promise<any>((resolve, reject) => {
      const id = ++next;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    }),
    new Promise<never>((_, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`${method} timed out`)),
        15000,
      );
      timer.unref();
    }),
  ]);
}
async function evaluate(expression: string) {
  const value = await send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (value.exceptionDetails) throw new Error(value.exceptionDetails.text);
  return value.result.value;
}
async function wait(expression: string) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (await evaluate(expression)) return;
    await Bun.sleep(100);
  }
  throw new Error(`Condition failed: ${expression}`);
}
try {
  await send("Page.navigate", { url: "about:blank" });
  await send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await send("Page.navigate", { url: address });
  await wait(
    `[...document.querySelectorAll('button')].some(button => button.textContent.trim() === 'Open my workspace' && !button.disabled)`,
  );
  await evaluate(
    `[...document.querySelectorAll('button')].find(button => button.textContent.trim() === 'Open my workspace' && !button.disabled).click()`,
  );
  await wait(`document.body.innerText.includes('Review changes')`);
  if (
    (await evaluate(`new URL(location.href).searchParams.get('proposal')`)) !==
    proposal
  )
    throw new Error("First workspace open lost proposal");
  await send("Page.reload", {});
  await wait(
    `[...document.querySelectorAll('button')].some(button => button.textContent.trim() === 'Open my workspace' && !button.disabled)`,
  );
  if (
    (await evaluate(`new URL(location.href).searchParams.get('proposal')`)) !==
    proposal
  )
    throw new Error("Reload lost proposal");
  await evaluate(
    `[...document.querySelectorAll('button')].find(button => button.textContent.trim() === 'Open my workspace' && !button.disabled).click()`,
  );
  await wait(`document.body.innerText.includes('Review changes')`);
  if (
    (await evaluate(`new URL(location.href).searchParams.get('proposal')`)) !==
    proposal
  )
    throw new Error("Reopen lost proposal");
  if (
    !(await evaluate(
      `[...document.querySelectorAll('button')].find(button => button.textContent.trim() === 'Review changes').disabled`,
    ))
  )
    throw new Error("Unenrolled workspace exposed review authority");
  console.log(
    JSON.stringify({
      first_open: "passed",
      reload: "passed",
      reopen: "passed",
      unenrolled_review: "disabled",
      financial_writes: false,
    }),
  );
} finally {
  await send("Page.navigate", { url: "about:blank" });
  await send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  ws.close();
}
