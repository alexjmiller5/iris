import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve, basename } from "node:path";
import { chromium, type Browser, type Page } from "@playwright/test";

// Bundle the real application worker, adding SQL access only to this test artifact.
// Dropping FTS5 from the shipped WASM must fail at CREATE VIRTUAL TABLE.
const root = resolve(import.meta.dir, "..");
const url = new URL(
  process.env.LIFE_UI_TEST_URL ??
    "http://life-ui-fts.localhost:5209/fts-fixture",
);
if (
  url.protocol !== "http:" ||
  url.hostname !== "life-ui-fts.localhost" ||
  url.pathname !== "/fts-fixture" ||
  url.username ||
  url.password
)
  throw new Error("Use the dedicated life-ui-fts.localhost fixture origin.");
const { CORE_CONTRACT_HASH } = await import(`${root}/packages/core/client.js`);
const replacement = process.env.LIFE_UI_TEST_WASM_DIR;
const bundle = await Bun.build({
  entrypoints: [resolve(root, "apps/web/src/lib/database.worker.ts")],
  target: "browser",
  format: "esm",
  naming: "[name].[ext]",
  plugins: [
    {
      name: "wasm-fixture",
      setup(build) {
        build.onLoad({ filter: /database\.worker\.ts$/ }, async (args) => {
          let contents = await readFile(args.path, "utf8");
          const marker = "switch (method) {";
          assert(contents.includes(marker), "Worker fixture seam moved.");
          contents = contents.replace(
            marker,
            `${marker}
        case '__test_all': return db.all(args.sql, args.params);
        case '__test_run': return db.run(args.sql, args.params);
        case '__test_tx': return db.transaction(async () => {
          for (const sql of args.sql) await db.run(sql);
          if (args.rollback) throw new Error('fixture rollback');
        });
        case '__test_version': {
          const rows = [];
          await sqlite.exec(connection, 'SELECT sqlite_version(), sqlite_source_id()', row => rows.push(row));
          return rows;
        }
      `,
          );
          return { contents, loader: "ts" };
        });
        if (replacement)
          build.onResolve(
            { filter: /(?:wa-sqlite\/dist\/|vendor\/wa-sqlite\/).*\.mjs$/ },
            () => ({ path: resolve(replacement, "wa-sqlite.mjs") }),
          );
        build.onResolve({ filter: /wa-sqlite\.wasm\?url$/ }, (args) => ({
          path: replacement
            ? resolve(replacement, "wa-sqlite.wasm")
            : args.path.startsWith("wa-sqlite/")
              ? resolve(
                  root,
                  "apps/web/node_modules",
                  args.path.replace("?url", ""),
                )
              : resolve(args.resolveDir, args.path.replace("?url", "")),
        }));
        build.onLoad({ filter: /\.wasm$/ }, async (args) => ({
          contents: new Uint8Array(await Bun.file(args.path).arrayBuffer()),
          loader: "file",
        }));
      },
    },
  ],
});
if (!bundle.success)
  throw new AggregateError(bundle.logs, "Fixture bundle failed");
const outputs = new Map(
  bundle.outputs.map((output) => [`/${basename(output.path)}`, output]),
);
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(url.port),
  fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === url.pathname)
      return new Response(
        "<!doctype html><title>Disposable WASM fixture</title>",
        { headers: { "Content-Type": "text/html" } },
      );
    const file = outputs.get(path);
    return file
      ? new Response(file, {
          headers: {
            "Content-Type": path.endsWith(".wasm")
              ? "application/wasm"
              : "text/javascript",
          },
        })
      : new Response("Not found", { status: 404 });
  },
});
let browser: Browser | undefined;
let page: Page | undefined;
try {
  browser = await chromium.connectOverCDP(
    process.env.LIFE_UI_TEST_CDP ?? "http://127.0.0.1:9222",
  );
  page = browser
    .contexts()
    .flatMap((context) => context.pages())
    .find((page) => page.url() === url.href);
  if (!page && process.env.LIFE_UI_TEST_TARGET) {
    for (const candidate of browser
      .contexts()
      .flatMap((context) => context.pages())) {
      const target = await candidate.context().newCDPSession(candidate);
      const { targetInfo } = await target.send("Target.getTargetInfo");
      await target.detach();
      if (targetInfo.targetId === process.env.LIFE_UI_TEST_TARGET)
        page = candidate;
    }
  }
  if (!page)
    throw new Error(
      `Open this dedicated test page: ${url}, or pass LIFE_UI_TEST_TARGET for its CDP target.`,
    );
  await page.goto(url.href);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Storage.clearDataForOrigin", {
    origin: url.origin,
    storageTypes: "all",
  });
  await cdp.detach();
  await page.evaluate(
    ({ hash }) => {
      const worker = new Worker("/database.worker.js", { type: "module" });
      (window as any).fixtureWorker = worker;
      let id = 0;
      (window as any).probe = (method: string, args = {}) =>
        new Promise((resolve, reject) => {
          const requestId = ++id;
          const timer = setTimeout(
            () => reject(new Error("Worker timeout")),
            15000,
          );
          function receive(event: MessageEvent) {
            if (event.data.id !== requestId) return;
            clearTimeout(timer);
            worker.removeEventListener("message", receive);
            resolve(event.data);
          }
          worker.addEventListener("message", receive);
          worker.postMessage({
            id: requestId,
            method,
            args,
            contractHash: hash,
          });
        });
    },
    { hash: CORE_CONTRACT_HASH },
  );
  async function probe(method: string, args: Record<string, unknown> = {}) {
    return page!.evaluate(
      ({ method, args }) => (window as any).probe(method, args),
      { method, args },
    );
  }
  async function call(method: string, args: Record<string, unknown> = {}) {
    const result = await probe(method, args);
    if (result.error) throw new Error(`${method}: ${result.error.message}`);
    return result.result;
  }
  const run = (sql: string) => call("__test_run", { sql });
  const all = (sql: string, params: unknown[] = []) =>
    call("__test_all", { sql, params });
  await call("open", { demo: true });
  console.log("SQLite:", await call("__test_version"));
  await run(
    `CREATE VIRTUAL TABLE fixture_fts USING fts5(title, body, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4');`,
  );
  console.log("PASS: actual bundled WASM creates FTS5 via OPFSCoopSyncVFS");
  await run(`CREATE TABLE fixture_notes(id INTEGER PRIMARY KEY, title TEXT, body TEXT);
    CREATE TABLE fixture_queue(id INTEGER PRIMARY KEY);
    CREATE TRIGGER fixture_insert AFTER INSERT ON fixture_notes BEGIN
      INSERT INTO fixture_fts(rowid,title,body) VALUES (new.id,new.title,new.body);
      INSERT OR IGNORE INTO fixture_queue VALUES(new.id);
    END;
    CREATE TRIGGER fixture_update AFTER UPDATE ON fixture_notes BEGIN
      DELETE FROM fixture_fts WHERE rowid=old.id;
      INSERT INTO fixture_fts(rowid,title,body) VALUES(new.id,new.title,new.body);
      INSERT OR IGNORE INTO fixture_queue VALUES(new.id);
    END;
    CREATE TRIGGER fixture_delete AFTER DELETE ON fixture_notes BEGIN
      DELETE FROM fixture_fts WHERE rowid=old.id;
      INSERT OR IGNORE INTO fixture_queue VALUES(old.id);
    END;`);
  await run(
    `INSERT INTO fixture_notes VALUES(1, 'Café résumé', '# Field notes\n\nA **naïve** telescope observes galaxies.');`,
  );
  const match = (query: string) =>
    all(
      "SELECT rowid AS id FROM fixture_fts WHERE fixture_fts MATCH ? ORDER BY rowid",
      [query],
    );
  assert.deepEqual(await match("cafe AND resume"), [{ id: 1 }]);
  assert.deepEqual(await match("tel*"), [{ id: 1 }]);
  assert.deepEqual(await match("naive"), [{ id: 1 }]);
  const snippet = await all(
    "SELECT snippet(fixture_fts,1,'[',']','...',12) AS excerpt FROM fixture_fts WHERE fixture_fts MATCH ?",
    ["naive"],
  );
  assert.match(snippet[0].excerpt, /\*\*\[naïve\]\*\*/);
  console.log(
    "PASS: accents, prefix MATCH and Markdown snippet through the read-only adapter",
  );
  assert.deepEqual(await all("SELECT id FROM fixture_queue"), [{ id: 1 }]);
  await run("DELETE FROM fixture_queue");
  const rejected = await probe("__test_tx", {
    sql: [
      "UPDATE fixture_notes SET title='Rollbackonly' WHERE id=1",
      "INSERT INTO fixture_notes VALUES(2,'Rollbackonly','Discarded')",
    ],
    rollback: true,
  });
  assert.match(rejected.error.message, /fixture rollback/);
  assert.deepEqual(await match("rollbackonly"), []);
  assert.deepEqual(await match("cafe"), [{ id: 1 }]);
  assert.deepEqual(await all("SELECT id FROM fixture_queue"), []);
  await call("__test_tx", {
    sql: [
      "UPDATE fixture_notes SET title='Committed' WHERE id=1",
      "UPDATE fixture_notes SET title='Committed twice' WHERE id=1",
    ],
  });
  assert.deepEqual(await match("cafe"), []);
  assert.deepEqual(await match("commit*"), [{ id: 1 }]);
  assert.deepEqual(await all("SELECT id FROM fixture_queue"), [{ id: 1 }]);
  await run("DELETE FROM fixture_queue");
  await run("DELETE FROM fixture_notes WHERE id=1");
  assert.deepEqual(await match("commit*"), []);
  assert.deepEqual(await all("SELECT id FROM fixture_queue"), [{ id: 1 }]);
  console.log(
    "PASS: triggers, queue deduplication, commit, rollback and delete remain transactional",
  );
  for (const sql of [
    "DELETE FROM fixture_notes",
    "PRAGMA user_version=7",
    "PRAGMA query_only=ON",
    "ATTACH ':memory:' AS escape",
    "SELECT 1; DELETE FROM fixture_notes",
    "SELECT load_extension('missing')",
  ]) {
    const result = await probe("__test_all", { sql });
    assert(result.error, `Read authorizer accepted ${sql}`);
  }
  assert.deepEqual(await all("SELECT id FROM fixture_queue"), [{ id: 1 }]);
  await run(
    "INSERT INTO fixture_notes VALUES(3,'Persisted café','**Markdown** survives reopen')",
  );
  await call("close");
  await call("open", { demo: true });
  assert.deepEqual(await match("cafe"), [{ id: 3 }]);
  console.log(
    "PASS: authorizer retained; FTS5 persists across OPFS close/reopen",
  );
  await call("close");
} finally {
  if (page) {
    await page
      .evaluate(() => (window as any).fixtureWorker?.terminate())
      .catch(() => {});
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Storage.clearDataForOrigin", {
      origin: url.origin,
      storageTypes: "all",
    });
    await cdp.detach();
  }
  await browser?.close();
  await server.stop(true);
}
