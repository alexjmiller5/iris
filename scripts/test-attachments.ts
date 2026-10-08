import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { expect } from "@playwright/test";
import {
  sourceNavigationCDP,
  element,
  named,
  js,
} from "./source-navigation-cdp";
import { regressionHub } from "./workspace-regression-hub";
import { disposableOrigin } from "./test-origin";
const url =
  process.env.LIFE_UI_TEST_URL ??
  "http://life-ui-attachments.localhost:5276/workspace?review";
const source = process.argv[2];
if (!source) throw Error("Provide the life-data checkout");
const origin = disposableOrigin(url),
  objects = new Map<string, { data: Buffer; mime: string; hash: Buffer }>();
let offline = true;
const uploaded: string[] = [];
const archive = {
  async put(key: string, body: ReadableStream, options: any) {
    if (objects.has(key)) return null;
    const data = Buffer.from(await new Response(body).arrayBuffer());
    const hash = Buffer.from(await crypto.subtle.digest("SHA-256", data));
    expect(hash.equals(Buffer.from(options.sha256))).toBe(true);
    objects.set(key, { data, mime: options.httpMetadata.contentType, hash });
    uploaded.push(key);
    return {
      size: data.length,
      httpMetadata: { contentType: options.httpMetadata.contentType },
      checksums: {
        sha256: hash.buffer.slice(
          hash.byteOffset,
          hash.byteOffset + hash.byteLength,
        ),
      },
      httpEtag: '"synthetic"',
    };
  },
  async get(key: string) {
    const value = objects.get(key);
    if (!value) return null;
    return {
      body: value.data,
      size: value.data.length,
      checksums: {
        sha256: value.hash.buffer.slice(
          value.hash.byteOffset,
          value.hash.byteOffset + value.hash.byteLength,
        ),
      },
      writeHttpMetadata(headers: Headers) {
        headers.set("Content-Type", value.mime);
      },
    };
  },
};
const { server, db, auth } = await regressionHub(source, origin, 0, {
  env: { ARCHIVE: archive },
  wrap: (worker) => ({
    fetch(request: Request, env: unknown, context: unknown) {
      if (
        offline &&
        request.method === "PUT" &&
        new URL(request.url).pathname.startsWith("/v1/files/")
      )
        return new Response("offline fixture", { status: 503 });
      return worker.fetch(request, env, context);
    },
  }),
});
const original = "# Exact  heading\r\n\nOriginal **Markdown**  ";
db.db
  .query("UPDATE widgets SET body=? WHERE id=?")
  .run(original, "fixture-record");
db.db
  .query(
    "UPDATE catalog_properties SET type='file' WHERE tbl='widgets' AND col='quantity'",
  )
  .run();
const cdp = await sourceNavigationCDP(url);
const { command, evaluate, until, click, fill, navigate } = cdp;
const editorErrors: string[] = [];
cdp.on("Runtime.exceptionThrown", ({ exceptionDetails }) => {
  const detail = JSON.stringify(exceptionDetails);
  if (detail.includes("AttachmentControl.svelte")) editorErrors.push(detail);
});
const button = (name: string, root = "document") => named("button", name, root);
const editor = element('[aria-label="Record editor"]');
async function connect() {
  await click(named("summary", "Connect to a hub"));
  await click(named("summary", "Use a device token"));
  await fill(element("#endpoint"), server.url.href.replace(/\/$/, ""));
  await fill(element("#token"), "fixture");
  await click(button("Connect"));
  await until(`!!document.querySelector('[data-last-sync]')?.getAttribute('data-last-sync')`);
}
async function open() {
  await click(button("widgets", element('nav[aria-label="Tables"]')));
  await click(
    button("Fixture record", element('[role="grid"][aria-label="Records"]')),
  );
}
async function sourceText() {
  await click(button("Body options", editor));
  await click(button("Body source", editor));
  return evaluate<string>(
    `${`(${editor}).querySelector('textarea[aria-label="Body"]')`}.value`,
  );
}
const downloads = await mkdtemp(join(tmpdir(), "life-ui-attachment-download-"));
try {
  await command("Page.setDownloadBehavior", {
    behavior: "allow",
    downloadPath: downloads,
  });
  await navigate(new URL("/", url).href);
  await command("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await navigate(url);
  await click(button("Open my workspace"));
  await connect();
  await open();
  await until(`!!${button("Attach file", editor)}`);
  await evaluate(
    `(()=>{const input=${editor}.querySelector('input[type="file"]');const transfer=new DataTransfer();transfer.items.add(new File(['exact synthetic bytes ☃'],'fixture.txt',{type:'text/plain'}));input.files=transfer.files;input.dispatchEvent(new Event('change',{bubbles:true}));})()`,
  );
  await until(
    `document.body.textContent.includes('Some files could not upload')`,
  );
  const before = await sourceText();
  expect(before.startsWith(original.replaceAll("\r\n", "\n") + "\n\n")).toBe(
    true,
  );
  expect(before).toMatch(
    /\[fixture.txt\]\(<\/v1\/files\/attachments\/[a-f0-9-]+>\)$/,
  );
  const key = /\/v1\/files\/([^>]+)/.exec(before)![1];
  expect(uploaded).toEqual([]);
  await evaluate(
    `(()=>{const field=${`(${editor}).querySelector('#field-quantity')`}.closest('.field');const input=field.querySelector('input[type=file]');const transfer=new DataTransfer();transfer.items.add(new File(['property synthetic bytes'],'property.txt',{type:'text/plain'}));input.files=transfer.files;input.dispatchEvent(new Event('change',{bubbles:true}));})()`,
  );
  await until(
    `${`(${editor}).querySelector('#field-quantity')`}.value.startsWith('/v1/files/attachments/')`,
  );
  const propertyReference = await evaluate<string>(
    `${`(${editor}).querySelector('#field-quantity')`}.value`,
  );

  await click(button("Save record", editor));
  await until(`!(${button("Save record", editor)}).disabled`);
  const resyncSince = await evaluate("new Date().toISOString()");
  await until(
    `(document.querySelector('[data-last-sync]')?.getAttribute('data-last-sync') ?? '') > ${js(resyncSince)}`,
  );
  const stored = db.db
    .query("SELECT body FROM widgets WHERE id=?")
    .get("fixture-record") as { body: string };
  expect(stored.body).toBe(
    original + "\n\n[fixture.txt](</v1/files/" + key + ">)",
  );
  await navigate(url);
  await click(button("Open my workspace"));
  await open();
  const after = await sourceText();
  expect(
    await evaluate<string>(
      `(${editor}).querySelector("#field-quantity").value`,
    ),
  ).toBe(propertyReference);
  await click(button("Download file", editor));

  await expect
    .poll(
      async () => {
        try {
          const files = await readdir(downloads);
          const filename = files.find(
            (name) =>
              name.startsWith(propertyReference.split("/").at(-1)!) &&
              !name.endsWith(".crdownload"),
          );
          return filename
            ? await readFile(join(downloads, filename), "utf8")
            : null;
        } catch {
          return null;
        }
      },
      { timeout: 10000 },
    )
    .toBe("property synthetic bytes");
  expect(after).toBe(before);
  const kept = await evaluate(
    `(async()=>{const root=await(await navigator.storage.getDirectory()).getDirectoryHandle('life-ui-attachments');for await(const [,scope]of root){if(scope.kind!=='directory')continue;for await(const [name,handle]of scope){if(handle.kind!=='file'||!name.endsWith('.json'))continue;const entry=JSON.parse(await(await handle.getFile()).text());if(entry.key===${js(key)}){const directory=await scope.getDirectoryHandle(entry.id);return {entry,text:await(await(await directory.getFileHandle('bytes')).getFile()).text()};}}}})()`,
  );
  expect(kept.text).toBe("exact synthetic bytes ☃");
  expect(kept.entry.state).toBe("failed");
  offline = false;
  await click(button("Close record", editor));
  await connect();
  await open();
  await until(`!document.body.textContent.includes('file(s) pending')`);
  expect(uploaded.sort()).toEqual([key, propertyReference.slice(10)].sort());
  expect(objects.get(propertyReference.slice(10))?.data.toString()).toBe(
    "property synthetic bytes",
  );
  expect(objects.get(key)?.data.toString()).toBe("exact synthetic bytes ☃");
  // A completed copy belongs to its original editor, even after that editor closes.
  const reopenedSource = await sourceText();
  await until(
    `!${editor}.textContent.includes('Body changes pending') && !${editor}.textContent.includes('Saving body')`,
  );
  cdp.on("Page.javascriptDialogOpening", ({ message }: { message: string }) => {
    if (message === "Discard unsaved changes to this record?")
      void command("Page.handleJavaScriptDialog", { accept: true });
  });
  await evaluate(
    `(()=>{window.__attachmentFailures=[];window.addEventListener('unhandledrejection',event=>window.__attachmentFailures.push(String(event.reason)));const original=FileSystemDirectoryHandle.prototype.getFileHandle;window.__releaseAttachment=null;window.__attachmentHeld=false;FileSystemDirectoryHandle.prototype.getFileHandle=async function(name,options){if(options?.create&&name.startsWith('.stage-')){window.__attachmentHeld=true;await new Promise(resolve=>window.__releaseAttachment=resolve);}return original.call(this,name,options);};const input=${editor}.querySelector('input[type=file]');const transfer=new DataTransfer();transfer.items.add(new File(['held synthetic bytes'],'late-selection.txt',{type:'text/plain'}));input.files=transfer.files;input.dispatchEvent(new Event('change',{bubbles:true}));window.__restoreAttachment=()=>FileSystemDirectoryHandle.prototype.getFileHandle=original;})()`,
  );
  await until("window.__attachmentHeld===true");
  await click(button("Close record", editor));
  await until(`!${editor}`, "original attachment editor actually closed");
  await open();
  await evaluate("window.__releaseAttachment();window.__restoreAttachment()");
  await expect.poll(() => uploaded.length, { timeout: 10000 }).toBe(3);
  expect(await sourceText()).toBe(reopenedSource);
  expect(await evaluate("window.__attachmentFailures")).toEqual([]);
  expect(editorErrors).toEqual([]);
  console.log(
    "PASS mounted attachment selection, offline failure, exact source/bytes after restart, same-key reconnect upload, closed-editor late selection",
  );
} catch (error) {
  console.error(await evaluate("document.body.innerText"));
  throw error;
} finally {
  await navigate(new URL("/", url).href).catch(() => {});
  await command("Storage.clearDataForOrigin", {
    origin,
    storageTypes: "all",
  }).catch(() => {});
  await command("Page.setDownloadBehavior", { behavior: "default" }).catch(
    () => {},
  );
  await rm(downloads, { recursive: true, force: true });
  cdp.close();
  server.stop(true);
  db.db.close();
  auth.db.close();
}
