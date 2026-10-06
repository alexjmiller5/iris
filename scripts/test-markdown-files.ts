import { expect } from "@playwright/test";
import { disposableOrigin } from "./test-origin";

const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-markdown.localhost:5198/workspace?review";
const origin = disposableOrigin(url);
let html = await Bun.file(
  process.env.LIFE_UI_TEST_EDITOR_HTML ??
    new URL(
      "../packages/LifeKit/Sources/LifeKit/Resources/editor.html",
      import.meta.url,
    ),
).text();
const resolverBuild = await Bun.build({
  entrypoints: [
    new URL("../apps/web/src/lib/retained-files.ts", import.meta.url).pathname,
  ],
  target: "browser",
  format: "esm",
});
if (!resolverBuild.success) throw Error(resolverBuild.logs.join("\n"));
const resolverModule = await resolverBuild.outputs[0].text();
const targets = (await (
  await fetch(
    `${process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222"}/json/list`,
  )
).json()) as { url: string; webSocketDebuggerUrl: string }[];
const owned = targets.filter((target) => target.url === url);
if (owned.length !== 1)
  throw Error("Open exactly one reserved Markdown files review page");
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(new URL(url).port),
  fetch: (request) =>
    new URL(request.url).pathname === "/workspace"
      ? new Response(html, { headers: { "Content-Type": "text/html" } })
      : new Response(null, { status: 204 }),
});
const socket = new WebSocket(owned[0].webSocketDebuggerUrl);
const pending = new Map<
  number,
  { resolve(value: any): void; reject(reason: unknown): void }
>();
const requests: string[] = [];
const failures: string[] = [];
let sequence = 0;
socket.onmessage = (event) => {
  const message = JSON.parse(String(event.data));
  if (message.id) {
    const request = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) request?.reject(Error(JSON.stringify(message.error)));
    else request?.resolve(message.result);
  } else if (message.method === "Runtime.exceptionThrown") {
    failures.push(
      message.params.exceptionDetails.exception?.description ??
        message.params.exceptionDetails.text,
    );
  } else if (message.method === "Network.requestWillBeSent") {
    const address = message.params.request.url;
    if (
      /^https?:/.test(address) &&
      address !== url &&
      address !== new URL("/favicon.ico", origin).href
    )
      requests.push(address);
  }
};
await new Promise<void>((resolve, reject) => {
  socket.onopen = () => resolve();
  socket.onerror = reject;
});
async function command(method: string, params: object = {}) {
  const id = ++sequence;
  const reply = new Promise<any>((resolve, reject) =>
    pending.set(id, { resolve, reject }),
  );
  socket.send(JSON.stringify({ id, method, params }));
  return await Promise.race([
    reply,
    new Promise<never>((_, reject) =>
      setTimeout(() => reject(Error(`CDP timeout: ${method}`)), 10000).unref(),
    ),
  ]);
}
async function evaluate<T>(
  fn: (...args: any[]) => T,
  ...args: any[]
): Promise<Awaited<T>> {
  const result = await command("Runtime.evaluate", {
    expression: `(${fn.toString()})(...${JSON.stringify(args)})`,
    returnByValue: true,
    awaitPromise: true,
  });
  if (result.exceptionDetails)
    throw Error(
      result.exceptionDetails.exception?.description ??
        result.exceptionDetails.text,
    );
  return result.result.value;
}
async function until(fn: () => Promise<unknown>, label: string) {
  const end = Date.now() + 10000;
  while (Date.now() < end) {
    if (await fn()) return;
    await Bun.sleep(40);
  }
  throw Error(`Timed out: ${label}`);
}
async function click(selector: string, text?: string) {
  await until(
    () =>
      evaluate(
        (selector, text) =>
          [...document.querySelectorAll(selector)].some(
            (node) => !text || node.textContent?.trim() === text,
          ),
        selector,
        text,
      ),
    `mounted ${selector} ${text ?? ""}`,
  );
  const { x, y } = await evaluate(
    (selector, text) => {
      const node = [...document.querySelectorAll(selector)].find(
        (node) => !text || node.textContent?.trim() === text,
      ) as HTMLElement;
      node.scrollIntoView({ block: "nearest" });
      const rect = node.getBoundingClientRect();
      return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
    },
    selector,
    text,
  );
  await command("Input.dispatchMouseEvent", {
    type: "mousePressed",
    button: "left",
    clickCount: 1,
    x,
    y,
  });
  await command("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    button: "left",
    clickCount: 1,
    x,
    y,
  });
}
const popup = '[aria-label="Open document link"]';
try {
  await command("Page.enable");
  await command("Network.enable");
  await command("Runtime.enable");
  await command("Page.addScriptToEvaluateOnNewDocument", {
    source: `window.events=[];window.webkit={messageHandlers:{editor:{postMessage(message){window.events.push(message);if(message.type==='openFile'||message.type==='openLink')queueMicrotask(()=>window.lifeEditor.receiveFile({id:message.id,request:message.request,opened:true}));}}}};`,
  });
  await command("Emulation.setDeviceMetricsOverride", {
    width: 320,
    height: 240,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await command("Page.navigate", { url });
  await command("Page.bringToFront");
  await until(
    () => evaluate(() => (window as any).events?.[0]?.type === "ready"),
    "editor ready",
  );
  const source =
    "[Related record](https://source.invalid/record)\n\n[Document](/v1/files/raw/document.txt)\n\n" +
    "A long paragraph retained exactly.\n\n".repeat(80);
  await evaluate(
    (value) =>
      (window as any).lifeEditor.setDocument({
        id: "links",
        value,
        label: "Body",
        readOnly: true,
      }),
    source,
  );
  await click(".rich-document a", "Related record");
  await until(
    () => evaluate((selector) => !!document.querySelector(selector), popup),
    "link actions",
  );
  const bounds = await evaluate(
    (selector) =>
      document.querySelector(selector).getBoundingClientRect().toJSON(),
    popup,
  );
  expect(
    bounds.y,
    "Link actions must remain on screen beside a link in a long document",
  ).toBeGreaterThanOrEqual(0);
  expect(
    bounds.bottom,
    "Link actions must not appear below the document",
  ).toBeLessThanOrEqual(240);
  expect(bounds.x).toBeGreaterThanOrEqual(0);
  expect(bounds.right).toBeLessThanOrEqual(320);
  await evaluate(
    () =>
      new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      ),
  );
  expect(
    failures,
    "Opening the constrained popup must not cause a layout feedback loop",
  ).toEqual([]);
  if (process.env.LIFE_UI_TEST_SCREENSHOT) {
    const shot = await command("Page.captureScreenshot", { format: "png" });
    await Bun.write(
      process.env.LIFE_UI_TEST_SCREENSHOT,
      Buffer.from(shot.data, "base64"),
    );
  }
  await command("Input.dispatchKeyEvent", {
    type: "keyDown",
    key: "Escape",
    code: "Escape",
    windowsVirtualKeyCode: 27,
  });
  await command("Input.dispatchKeyEvent", {
    type: "keyUp",
    key: "Escape",
    code: "Escape",
    windowsVirtualKeyCode: 27,
  });
  await until(
    () => evaluate((selector) => !document.querySelector(selector), popup),
    "Escape closes actions",
  );
  await click(".rich-document a", "Related record");
  await click(`${popup} button`, "Open in workspace");
  await until(
    () =>
      evaluate(
        () =>
          (window as any).events.find(
            (message: any) => message.type === "openLink",
          )?.value === "https://source.invalid/record",
      ),
    "source link bridge",
  );
  await until(
    () => evaluate((selector) => !document.querySelector(selector), popup),
    "successful action closes popup",
  );
  await click(".rich-document a", "Document");
  await click(`${popup} button`, "Download file");
  await until(
    () =>
      evaluate(
        () =>
          (window as any).events.find(
            (message: any) => message.type === "openFile",
          )?.value === "raw/document.txt",
      ),
    "file bridge",
  );
  expect(
    await evaluate(() => (window as any).lifeEditor.getDocument().value),
  ).toBe(source);
  expect(
    await evaluate(() =>
      (window as any).events.filter((event: any) => event.type === "change"),
    ),
  ).toEqual([]);
  expect(
    requests,
    "Island actions must use the host, without network requests",
  ).toEqual([]);

  html = "<!doctype html><title>Retained preview fixture</title>";
  await command("Page.navigate", { url });
  await until(
    () => evaluate(() => document.title === "Retained preview fixture"),
    "preview fixture",
  );
  const preview = await evaluate(async (moduleSource) => {
    const moduleURL = URL.createObjectURL(
      new Blob([moduleSource], { type: "text/javascript" }),
    );
    try {
      const { createRetainedFileResolver } = await import(
        /* @vite-ignore */ moduleURL
      );
      const canvas = document.createElement("canvas");
      canvas.width = 2048;
      canvas.height = 1024;
      canvas.getContext("2d")!.fillRect(0, 0, 2048, 1024);
      const encoded = await new Promise<Blob>((resolve) =>
        canvas.toBlob((blob) => resolve(blob!), "image/png"),
      );
      canvas.width = canvas.height = 0;
      const resolve = createRetainedFileResolver(
        { endpoint: "https://hub.invalid", token: "synthetic" },
        async () =>
          new Response(encoded, { headers: { "Content-Type": "image/png" } }),
      );
      const file = await resolve("raw/image.png", undefined, true);
      const image = new Image();
      image.src = file.url;
      await image.decode();
      const result = {
        width: image.naturalWidth,
        height: image.naturalHeight,
        type: file.contentType,
      };
      image.src = "";
      file.dispose();
      const original = await resolve("raw/image.png");
      const originalImage = new Image();
      originalImage.src = original.url;
      await originalImage.decode();
      const originalWidth = originalImage.naturalWidth;
      originalImage.src = "";
      original.dispose();
      return { ...result, originalWidth };
    } finally {
      URL.revokeObjectURL(moduleURL);
    }
  }, resolverModule);
  expect(preview).toEqual({
    width: 1024,
    height: 512,
    type: "image/png",
    originalWidth: 2048,
  });
  console.log(
    "PASS: anchored read-only file/source actions, exact Markdown, network isolation and bounded static browser preview",
  );
} finally {
  await command("Emulation.clearDeviceMetricsOverride").catch(() => {});
  await command("Page.navigate", { url: origin + "/workspace?review" }).catch(
    () => {},
  );
  socket.close();
  server.stop(true);
}
