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
  "http://life-ui-markdown.localhost:5252/workspace?review";
const origin = disposableOrigin(url),
  source = process.argv[2];
if (!source) throw Error("Provide the life-data checkout");
const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAUAAAAB4CAIAAAAMrLyJAAACk0lEQVR4nO3TQQ2AQBAEwZXFH8uowAA2kICMSx+VjIGapOd63iU7j3vJeHl38s7fwLy8O3kFzMsb9gqYlzfsFTAvb9grYF7esFfAvLxhr4B5ecNeAfPyhr0C5uUNewXMyxv2CpiXN+wVMC9v2CtgXt6wV8C8vGGvgHl5w14B8/KGvQLm5Q17BczLG/YKmJc37BUwL2/YK2Be3rBXwLy8Ya+AeXnDXgHz8oa9AublDXsFzMsb9gqYlzfsFTAvb9grYF7esFfAvLxhr4B5ecNeAfPyhr0C5uUNewXMyxv2CpiXN+wVMC9v2CtgXt6wV8C8vGGvgHl5w95xNC9v1ytgXt6wV8C8vGGvgHl5w14B8/KGvQLm5Q17BczLG/YKmJc37BUwL2/YK2Be3rBXwLy8Ya+AeXnDXgHz8oa9AublDXsFzMsb9gqYlzfsFTAvb9grYF7esFfAvLxhr4B5ecNeAfPyhr0C5uUNewXMyxv2CpiXN+wVMC9v2CtgXt6wV8C8vGGvgHl5w14B8/KGvQLm5Q17BczLG/YKmJc37BUwL2/YK2Be3rBXwLy8Ya+AeXnDXgHz8oa9AublDXsFzMsb9gqYlzfsHUfz8na9AublDXsFzMsb9gqYlzfsFTAvb9grYF7esFfAvLxhr4B5ecNeAfPyhr0C5uUNewXMyxv2CpiXN+wVMC9v2CtgXt6wV8C8vGGvgHl5w14B8/KGvQLm5Q17BczLG/YKmJc37BUwL2/YK2Be3rBXwLy8Ya+AeXnDXgHz8oa9AublDXsFzMsb9gqYlzfsFTAvb9grYF7esFfAvLxhr4B5ecNeAfPyhr0C5uUNewXMyxv2CpiXN+wVMC9v2CtgXt6wV8C8vGGvgHl5w94PCbtQeLqWgEIAAAAASUVORK5CYII=",
  "base64",
);
const requests: string[] = [];
let missing = true;
let holdDocument = false;
let releaseDocument: (() => void) | undefined;
function finishDocument() {
  holdDocument = false;
  releaseDocument?.();
  releaseDocument = undefined;
}
const archive = {
  async get(key: string) {
    requests.push(key);
    if (key === "raw/missing.png" && missing) return null;
    if (key === "raw/document.txt" && holdDocument)
      await new Promise<void>((resolve) => {
        releaseDocument = resolve;
      });
    const image = key.endsWith(".png"),
      bytes = image ? png : Buffer.from("Retained document bytes");
    return {
      body: bytes,
      size: bytes.length,
      writeHttpMetadata(headers: Headers) {
        headers.set("Content-Type", image ? "image/png" : "text/plain");
      },
    };
  },
};
const { server, db, auth } = await regressionHub(source, origin, 0, {
  env: { ARCHIVE: archive },
  wrap: (worker) => ({
    fetch(request: Request, env: unknown, context: unknown) {
      server.timeout(request, 60);
      return worker.fetch(request, env, context);
    },
  }),
});
const sourceID = "11111111222233334444555555555555";
const sourceURL = `https://app.notion.com/p/Related-${sourceID}`;
const body = `# Retained content\n\n![Diagram](/v1/files/raw/diagram.png)\n\n![Retry diagram](/v1/files/raw/missing.png)\n\n![External image](https://expired.invalid/image.png)\n\n[Document](/v1/files/raw/document.txt)\n\n[Related record](${sourceURL})\n`;
db.db.query("UPDATE widgets SET body=? WHERE id=?").run(body, "fixture-record");
const ddl =
  "CREATE TABLE provenance (id TEXT PRIMARY KEY,from_kind TEXT,from_ref TEXT,to_kind TEXT,to_ref TEXT,rel TEXT,field TEXT,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT)";
db.db.exec(ddl);
db.db
  .query("INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)")
  .run(new Date().toISOString(), ddl);
db.db
  .query("INSERT INTO catalog_tables(id,kind,display) VALUES (?,?,?)")
  .run("provenance", "system", "id");
db.db
  .query(
    "INSERT INTO provenance(id,from_kind,from_ref,to_kind,to_ref,rel,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
  )
  .run(
    "fixture-source",
    "notion",
    sourceID,
    "widgets",
    "second-record",
    "imported_from",
    new Date().toISOString(),
    new Date().toISOString(),
  );
const cdp = await sourceNavigationCDP(url);
const { command, evaluate, until, click, fill, navigate } = cdp;
const externalRequests: string[] = [],
  abortedDocuments: string[] = [];
const network = new Map<string, string>();
cdp.on("Network.requestWillBeSent", ({ requestId, request }) => {
  network.set(requestId, new URL(request.url).pathname);
  if (request.url.includes("expired.invalid"))
    externalRequests.push(request.url);
});
cdp.on("Network.loadingFailed", ({ requestId, errorText, canceled }) => {
  if (network.get(requestId) === "/v1/files/raw/document.txt" && canceled)
    abortedDocuments.push(errorText);
});
const button = (name: string, root = "document") => named("button", name, root);
const link = (name: string, root = "document") => named("a", name, root);
const grid = element('[role="grid"][aria-label="Records"]');
const editor = element('[aria-label="Record editor"]');
let initScript: string | undefined;
try {
  await command("Emulation.setDeviceMetricsOverride", {
    width: 1440,
    height: 1000,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await navigate(new URL("/", url).href);
  await command("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  // Observe the application's actual download anchor and resolved Blob, avoiding
  // OS download settings or files outside this disposable fixture.
  initScript = (
    await command("Page.addScriptToEvaluateOnNewDocument", {
      source: `
    window.fileDownloads=[];
    const objects=new Map();
    const create=URL.createObjectURL.bind(URL);
    URL.createObjectURL=blob=>{const url=create(blob);objects.set(url,blob);return url;};
    document.addEventListener('click',async event=>{
      const anchor=event.target.closest?.('a[download]');
      if(!anchor)return;
      event.preventDefault();
      const blob=objects.get(anchor.href);
      window.fileDownloads.push({name:anchor.download,text:blob ? await blob.text() : null});
    },true);
  `,
    })
  ).identifier;
  await navigate(url);
  await click(button("Open my workspace"));
  await click(named("summary", "Connect to a hub"));
  await click(named("summary", "Use a device token"));
  await fill(element("#endpoint"), server.url.href.replace(/\/$/, ""));
  await fill(element("#token"), "fixture");
  await click(button("Sync now"));
  await until(`!(${button("Sync now")}).disabled`);
  await click(button("widgets", element('nav[aria-label="Tables"]')));
  await click(button("Fixture record", grid));
  await until(
    `!!${element('[data-type="retained-image"] img[alt="Diagram"]')}`,
  );
  expect(await evaluate(`${element('img[alt="Diagram"]')}.naturalWidth`)).toBe(
    320,
  );
  await until(
    `document.body.textContent.includes('Retry diagram: File HTTP 404')`,
  );
  missing = false;
  await click(button("Retry image"));
  await until(
    `!!${element('[data-type="retained-image"] img[alt="Retry diagram"]')}`,
  );
  expect(externalRequests).toEqual([]);
  await click(button("Body options"));
  await click(button("Body source"));
  expect(
    await evaluate(`${element('textarea[aria-label="Body"]')}.value`),
  ).toBe(body);
  await click(button("Body options"));
  await click(button("Body write"));
  async function download() {
    const before = await evaluate("window.fileDownloads.length");
    await click(link("Document"));
    await click(button("Download file"));
    await until(`window.fileDownloads.length===${before + 1}`);
    expect(await evaluate("window.fileDownloads.at(-1)")).toEqual({
      name: "document.txt",
      text: "Retained document bytes",
    });
  }
  await download();
  for (const exit of ["close", "switch"]) {
    holdDocument = true;
    releaseDocument = undefined;
    const before = abortedDocuments.length;
    await click(link("Document"));
    await click(button("Download file"));
    await expect.poll(() => !!releaseDocument).toBe(true);
    if (exit === "close") await click(button("Close record", editor));
    else await click(button("Second record", grid));
    await expect
      .poll(() => abortedDocuments.length, {
        timeout: 10000,
        message: `${exit} must abort held attachment fetch before server replies`,
      })
      .toBe(before + 1);
    expect(abortedDocuments.at(-1)).toMatch(/aborted/i);
    finishDocument();
    if (exit === "switch") await click(button("Close record", editor));
    await click(button("Fixture record", grid));
    await until(`!!(${link("Document", editor)})`);
  }
  console.log(
    "PASS: closing/switching records aborts held original download before server reply",
  );
  await click(link("Related record"));
  expect(
    await evaluate(`(${link("Open original link")}).getAttribute('href')`),
  ).toBe(sourceURL);
  await click(button("Open in workspace"));
  await until(`!!(${named("h2,h3", "Second record", editor)})`);
  await click(button("Close record", editor));
  await click(
    `[...document.querySelectorAll('summary')].find(e=>e.textContent.trim()==='Columns')`,
  );
  if (!(await evaluate(`${element('input[aria-label="Show Body"]')}.checked`)))
    await click(element('input[aria-label="Show Body"]'));
  await click(
    `[...document.querySelectorAll('summary')].find(e=>e.textContent.trim()==='Columns')`,
  );
  const cell = element('[data-row="fixture-record"][data-column="body"]');
  await click(cell, 2);
  await until(`!!${cell}.querySelector('img[alt="Diagram"]')`);
  await download();
  await click(button("Save cell", cell));
  await click(button("Fixture record", grid));
  await until(`!!${element('img[alt="Diagram"]')}`);
  await click(button("Sync now"));
  await until(`!(${button("Sync now")}).disabled`);
  expect(
    (
      db.db
        .query("SELECT body FROM widgets WHERE id=?")
        .get("fixture-record") as any
    ).body,
  ).toBe(body);
  expect(requests).toContain("raw/document.txt");
  expect(externalRequests).toEqual([]);
  if (process.env.LIFE_UI_TEST_SCREENSHOT) {
    const shot = await command("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: true,
    });
    await Bun.write(
      process.env.LIFE_UI_TEST_SCREENSHOT,
      Buffer.from(shot.data, "base64"),
    );
  }
  console.log(
    "PASS: authenticated inline/full images, retry, exact source, downloads and source navigation",
  );
} catch (error) {
  console.error(await evaluate("document.body.innerText"));
  throw error;
} finally {
  finishDocument();
  if (initScript)
    await command("Page.removeScriptToEvaluateOnNewDocument", {
      identifier: initScript,
    });
  await navigate(new URL("/", url).href).catch(() => {});
  await command("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  cdp.close();
  server.stop(true);
  db.db.close();
  auth.db.close();
}
