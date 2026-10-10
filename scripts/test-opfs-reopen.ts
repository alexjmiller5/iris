import { expect } from "@playwright/test";
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import {
  sourceNavigationCDP,
  element,
  named,
  js,
} from "./source-navigation-cdp";
import { disposableOrigin } from "./test-origin";
import { regressionHub } from "./workspace-regression-hub";

// Requires an explicit browser lease and an owned synthetic target. No readback
// Worker is created between the UI's successful sync and full-document reload.
// Mutants: throw on busy temporary cleanup; remove the Web Lock guard; swallow
// unrelated cleanup failures or NoModificationAllowedError at another call site.
const root = resolve(import.meta.dir, "..");
// CI packaging gate, run after bun install --frozen-lockfile. The expected Git
// blob identity comes from Bun's tracked patch, not another copy of the VFS.
if (process.argv[2] === "--verify-patch") {
  const manifest = JSON.parse(
    readFileSync(resolve(root, "package.json"), "utf8"),
  );
  const entries = Object.entries(manifest.patchedDependencies ?? {}).filter(
    ([name]) => name.startsWith("wa-sqlite@"),
  );
  if (entries.length !== 1) throw Error("Expected one pinned wa-sqlite patch");
  const patch = readFileSync(resolve(root, entries[0][1] as string), "utf8");
  const expected = patch.match(
    /^index [a-f0-9]{40}\.\.([a-f0-9]{40}) 100644$/m,
  )?.[1];
  if (
    !expected ||
    patch.split("diff --git ").length !== 2 ||
    !patch.includes("b/src/examples/OPFSCoopSyncVFS.js\n")
  )
    throw Error("Expected the single OPFS cleanup patch");
  const installed = readFileSync(
    resolve(
      root,
      "apps/web/node_modules/wa-sqlite/src/examples/OPFSCoopSyncVFS.js",
    ),
  );
  const actual = createHash("sha1")
    .update(`blob ${installed.length}\0`)
    .update(installed)
    .digest("hex");
  if (actual !== expected)
    throw Error(
      `Installed VFS does not match tracked patch: ${actual} != ${expected}`,
    );
  console.log(`Installed wa-sqlite patch verified: ${actual}`);
  process.exit(0);
}
const address = process.env.IRIS_TEST_URL;
const source = process.argv[2];
if (!address || !source || !process.env.IRIS_TEST_TARGET)
  throw Error(
    "Set IRIS_TEST_URL / IRIS_TEST_TARGET and pass a soma checkout",
  );
const origin = disposableOrigin(address);
// Refuse an older service fixture before starting its hub or attaching a browser.
// This is the same source identity used by bundle-core.ts, not a rebuild.
for (const [local, remote] of [
  ["packages/core/contract/core.json", "core/contract/core.json"],
  ["packages/core/contract.generated.ts", "core/src/contract.generated.ts"],
  ["packages/core/schema/saved-views.json", "core/schema/saved-views.json"],
]) {
  if (
    !readFileSync(resolve(root, local)).equals(
      readFileSync(resolve(source, remote)),
    )
  )
    throw Error(`Fixture source does not match bundled ${local}`);
}
const coreHash = createHash("sha256");
for (const name of readdirSync(resolve(source, "core/src"))
  .filter((name) => name.endsWith(".ts"))
  .sort())
  coreHash
    .update(`${name}\0`)
    .update(readFileSync(resolve(source, "core/src", name)));
for (const name of readdirSync(resolve(source, "core/schema")).filter(name => name.endsWith(".json")).sort())
  coreHash.update(`schema/${name}\0`).update(readFileSync(resolve(source, "core/schema", name)));
const expectedBanner = `// Generated from soma-core. SHA-256: ${coreHash.digest("hex")}`;
if (
  readFileSync(resolve(root, "packages/core/client.js"), "utf8").split(
    "\n",
    1,
  )[0] !== expectedBanner
)
  throw Error(
    "Fixture core source differs from the bundled client; use the frozen matching Worker checkout",
  );
const dependency = realpathSync(
  resolve(root, "apps/web/node_modules/wa-sqlite"),
);
const moduleURL = (path: string) => new URL(`/@fs${path}`, origin).href;
const modules = {
  factory: moduleURL(resolve(root, "vendor/wa-sqlite/wa-sqlite.mjs")),
  wasm: moduleURL(resolve(root, "vendor/wa-sqlite/wa-sqlite.wasm")),
  api: moduleURL(resolve(dependency, "src/sqlite-api.js")),
  vfs: moduleURL(resolve(dependency, "src/examples/OPFSCoopSyncVFS.js")),
};
// A focused mutation run must load the changed source, not Vite's previous module.
modules.vfs += `?fixture=${createHash("sha256")
  .update(readFileSync(resolve(dependency, "src/examples/OPFSCoopSyncVFS.js")))
  .digest("hex")}`;

/** Serialized into a disposable module Worker, using real OPFS and pinned WASM. */
function fixtureWorker() {
  const scope = globalThis as any;
  let directory: any, held: any, release: (() => void) | undefined;
  let lockFinished: Promise<unknown> | undefined;
  let sqlite: any,
    module: any,
    VFS: any,
    sequence = 0;
  let fixtureName = "",
    injected = "",
    removalCalls = 0;
  const getRoot = navigator.storage.getDirectory.bind(navigator.storage);
  const remove = FileSystemDirectoryHandle.prototype.removeEntry;
  const filePrototype = FileSystemFileHandle.prototype as any;
  const createHandle = filePrototype.createSyncAccessHandle;
  // Fault injection is restricted to the synthetic entry and worker. The busy
  // and held-Web-Lock cases delegate to the browser without manufactured errors.
  FileSystemDirectoryHandle.prototype.removeEntry = async function (
    name,
    options,
  ) {
    if (name === fixtureName) {
      removalCalls++;
      if (injected === "NotFoundError") await remove.call(this, name, options);
      else if (injected && injected !== "outside-cleanup")
        throw new DOMException("Synthetic cleanup failure", injected);
    }
    return remove.call(this, name, options);
  };
  filePrototype.createSyncAccessHandle = async function () {
    if (injected === "outside-cleanup")
      throw new DOMException(
        "Synthetic allocation failure",
        "NoModificationAllowedError",
      );
    return createHandle.call(this);
  };
  scope.onmessage = async ({ data }: any) => {
    try {
      let result: any;
      switch (data.method) {
        case "init": {
          const physicalRoot = await getRoot();
          directory = await physicalRoot.getDirectoryHandle(data.directory, {
            create: true,
          });
          // Each control has its own real OPFS subtree; no cross-case teardown race.
          navigator.storage.getDirectory = async () => directory;
          fixtureName = `.ahp-${data.directory}`;
          if (data.modules) {
            const { default: factory } = await import(data.modules.factory);
            module = await factory({ locateFile: () => data.modules.wasm });
            sqlite = (await import(data.modules.api)).Factory(module);
            VFS = (await import(data.modules.vfs)).OPFSCoopSyncVFS;
          }
          result = true;
          break;
        }
        case "hold": {
          await new Promise<void>((resolve) => {
            lockFinished = navigator.locks.request(fixtureName, () => {
              const pending = new Promise<void>((done) => {
                release = done;
              });
              resolve();
              return pending;
            });
          });
          const child = await directory.getDirectoryHandle(fixtureName, {
            create: true,
          });
          const file = await child.getFileHandle("held.tmp", { create: true });
          held = await file.createSyncAccessHandle();
          held.write(new TextEncoder().encode("held-marker"));
          held.flush();
          result = true;
          break;
        }
        case "release-lock":
          release?.();
          await lockFinished;
          result = true;
          break;
        case "read-held": {
          const child = await directory.getDirectoryHandle(fixtureName);
          await child.getFileHandle("held.tmp");
          const bytes = new Uint8Array(held.getSize());
          held.read(bytes, { at: 0 });
          result = new TextDecoder().decode(bytes);
          break;
        }
        case "close-held":
          held?.close();
          held = undefined;
          release?.();
          await lockFinished;
          result = true;
          break;
        case "probe": {
          injected = data.inject ?? "";
          removalCalls = 0;
          let connection: number | undefined;
          try {
            const vfs = await VFS.create(`fixture-${++sequence}`, module);
            sqlite.vfs_register(vfs, true);
            connection = await sqlite.open_v2(
              "marker.sqlite",
              undefined,
              vfs.name,
            );
            if (data.seed)
              await sqlite.exec(
                connection,
                "CREATE TABLE marker(value TEXT); INSERT INTO marker VALUES ('persistent-marker')",
              );
            const rows: unknown[] = [];
            await sqlite.exec(
              connection,
              "SELECT value FROM marker",
              (row: unknown[]) => rows.push([...row]),
            );
            result = { ok: true, rows, removalCalls };
          } catch (error: any) {
            result = {
              ok: false,
              error: error.name,
              message: error.message,
              removalCalls,
            };
          } finally {
            injected = "";
            if (connection !== undefined) await sqlite.close(connection);
          }
          break;
        }
        case "remnant": {
          try {
            await directory.getDirectoryHandle(fixtureName);
            result = true;
          } catch (error: any) {
            if (error.name !== "NotFoundError") throw error;
            result = false;
          }
          break;
        }
        default:
          throw Error("Unknown fixture command");
      }
      scope.postMessage({ id: data.id, result });
    } catch (error: any) {
      scope.postMessage({
        id: data.id,
        error: `${error.name}: ${error.message}`,
      });
    }
  };
}

function installWorkers(source: string) {
  const workers = new Map<string, Worker>();
  const url = URL.createObjectURL(
    new Blob([`(${source})()`], { type: "text/javascript" }),
  );
  let id = 0;
  const pending = new Map<
    number,
    { resolve(value: any): void; reject(error: Error): void; timer: any }
  >();
  (globalThis as any).opfsFixture = {
    async call(name: string, message: object) {
      let worker = workers.get(name);
      if (!worker) {
        worker = new Worker(url, { type: "module" });
        workers.set(name, worker);
        worker.onmessage = ({ data }) => {
          const request = pending.get(data.id);
          if (!request) return;
          pending.delete(data.id);
          clearTimeout(request.timer);
          data.error
            ? request.reject(Error(data.error))
            : request.resolve(data.result);
        };
      }
      const target = worker;
      return new Promise((resolve, reject) => {
        const requestID = ++id;
        pending.set(requestID, {
          resolve,
          reject,
          timer: setTimeout(() => {
            pending.delete(requestID);
            reject(Error(`Worker fixture timeout: ${name}`));
          }, 8000),
        });
        target.postMessage({ ...message, id: requestID });
      });
    },
    stop() {
      for (const worker of workers.values()) worker.terminate();
      workers.clear();
      for (const request of pending.values()) {
        clearTimeout(request.timer);
        request.reject(Error("Fixture stopped"));
      }
      pending.clear();
      URL.revokeObjectURL(url);
    },
  };
}

const hub = await regressionHub(source, origin);
let page: Awaited<ReturnType<typeof sourceNavigationCDP>> | undefined;
const results: { name: string; ok: boolean; detail?: string }[] = [];
try {
  page = await sourceNavigationCDP(address);
  const cdp = page;
  await cdp.command("Page.bringToFront");
  async function check(name: string, body: () => Promise<void>) {
    if (
      process.env.IRIS_OPFS_CASE &&
      !name.includes(process.env.IRIS_OPFS_CASE)
    )
      return;
    try {
      await body();
      results.push({ name, ok: true });
    } catch (error) {
      results.push({ name, ok: false, detail: String(error) });
      const artifacts = process.env.IRIS_TEST_ARTIFACT_DIR;
      if (artifacts) {
        mkdirSync(artifacts, { recursive: true });
        const stem = name.replace(/[^a-z0-9]+/gi, "-").toLowerCase();
        await Bun.write(
          resolve(artifacts, `${stem}.txt`),
          await cdp.evaluate("document.body.innerText"),
        );
        const shot = await cdp.command("Page.captureScreenshot", {
          format: "png",
        });
        await Bun.write(
          resolve(artifacts, `${stem}.png`),
          Buffer.from(shot.data, "base64"),
        );
      }
    }
    console.log(JSON.stringify(results.at(-1)));
  }
  await cdp.navigate(new URL("/", address).href);
  await cdp.command("Storage.clearDataForOrigin", {
    origin,
    storageTypes: "all",
  });
  await check(
    "clean sync then full reload retains committed record",
    async () => {
      await cdp.navigate(address);
      await cdp.until("!!document.querySelector('#svelte-announcer')");
      await cdp.click(named("button", "Open my workspace"));
      await cdp.click(named("button,summary", "Connect to a hub"));
      await cdp.click(named("button,summary", "Use a device token"));
      const input = (label: string) => `(${named("label", label)})?.control`;
      await cdp.fill(
        input("Hub address"),
        hub.server.url.href.replace(/\/$/, ""),
      );
      await cdp.fill(input("Device token"), "fixture");
      await cdp.click(named("button", "Connect"));
      await cdp.until(
        `!!(${named("button", "Fixture record")})`,
        "Initial clean sync has rendered its record",
      );
      // This is the original failing sequence, before any diagnostic Worker exists.
      await cdp.navigate(address);
      await cdp.click(named("button", "Open my workspace"));
      await cdp.until(
        `!!(${named("button", "Fixture record")})`,
        "Reopen retains the synced record",
      );
      await cdp.click(named("button", "Fixture record"));
      // The opened record is inert until its fresh row arrives; then edits save themselves.
      await cdp.until(
        `document.querySelector('.record-panel form')?.inert===false`,
      );
      await cdp.fill(element("#field-title"), "Persisted reopen marker");
      await cdp.evaluate("document.activeElement?.blur()");
      await cdp.until(
        `document.querySelector('[aria-label="Record save status"]')?.dataset.state==='saved' && (${element("#field-title")})?.value==='Persisted reopen marker' && !!(${named("button", "Persisted reopen marker")})`,
      );
      await cdp.click(named("button", "Close record"));
      await cdp.navigate(address);
      await cdp.click(named("button", "Open my workspace"));
      await cdp.until(
        `!!(${named("button", "Persisted reopen marker")})`,
        "Reopen retains the local committed edit",
      );
      const firstTarget = process.env.IRIS_TEST_TARGET;
      if (!process.env.IRIS_TEST_SECOND_TARGET)
        throw Error(
          "Set IRIS_TEST_SECOND_TARGET to a second owned same-origin tab",
        );
      let second: typeof page;
      try {
        process.env.IRIS_TEST_TARGET =
          process.env.IRIS_TEST_SECOND_TARGET;
        second = await sourceNavigationCDP(address);
      } finally {
        process.env.IRIS_TEST_TARGET = firstTarget;
      }
      try {
        await second.command("Page.bringToFront");
        await second.navigate(address + "&observer=second");
        await second.click(named("button", "Open my workspace"));
        await second.until(`!!(${named("button", "Persisted reopen marker")})`);
        await cdp.command("Page.bringToFront");
        await cdp.navigate(address);
        await cdp.click(named("button", "Open my workspace"));
        await cdp.until(`!!(${named("button", "Persisted reopen marker")})`);
        await second.until(`!!(${named("button", "Persisted reopen marker")})`);
        console.log(
          "PASS: two open tabs retain the committed marker across reload",
        );
        await second.command("Page.bringToFront");
        await second.click(named("button", "Switch workspace"));
        await second.until(`!!(${named("button", "Open my workspace")})`);
      } finally {
        await second.navigate(new URL("/", address).href);
        second.close();
      }
      await cdp.command("Page.bringToFront");
      // Test-only fault injection: terminate the actual page's database Worker.
      // No app debug flag, private VFS API, or replacement database implementation.
      const tracking = await cdp.command(
        "Page.addScriptToEvaluateOnNewDocument",
        {
          source: `globalThis.opfsCrashWorkers=[];const Original=Worker;globalThis.Worker=class extends Original{constructor(url,options){super(url,options);if(String(url).includes('database.worker'))globalThis.opfsCrashWorkers.push(this);}};`,
        },
      );
      try {
        await cdp.navigate(address);
        await cdp.click(named("button", "Open my workspace"));
        await cdp.until(`!!(${named("button", "Persisted reopen marker")})`);
        expect(await cdp.evaluate("opfsCrashWorkers.length")).toBe(1);
        await cdp.evaluate("opfsCrashWorkers[0].terminate()");
        await cdp.navigate(address);
        await cdp.click(named("button", "Open my workspace"));
        await cdp.until(`!!(${named("button", "Persisted reopen marker")})`);
        console.log(
          "PASS: abrupt database Worker termination preserves committed edit",
        );
      } finally {
        await cdp.command("Page.removeScriptToEvaluateOnNewDocument", {
          identifier: tracking.identifier,
        });
      }
    },
  );
  await cdp.navigate(new URL("/", address).href);
  await cdp.evaluate(
    `(${installWorkers.toString()})(${js(fixtureWorker.toString())})`,
  );
  const call = (worker: string, method: string, args = {}) =>
    cdp.evaluate(`opfsFixture.call(${js(worker)},${js({ method, ...args })})`);
  const marker = (receipt: any) => {
    expect(
      receipt,
      "VFS initialization must preserve/open the SQLite marker",
    ).toMatchObject({ ok: true, rows: [["persistent-marker"]] });
  };
  for (const mode of [
    "held-lock",
    "released-busy",
    "NotFoundError",
    "SecurityError",
    "QuotaExceededError",
    "UnknownError",
    "outside-cleanup",
  ]) {
    await check(`temporary cleanup ${mode}`, async () => {
      const directory = `opfs-test-${mode}-${crypto.randomUUID()}`;
      const actor = `${mode}-actor`,
        opener = `${mode}-opener`;
      await call(actor, "init", { directory });
      await call(opener, "init", { directory, modules });
      marker(await call(opener, "probe", { seed: true }));
      await call(actor, "hold");
      try {
        if (mode === "released-busy") await call(actor, "release-lock");
        else if (mode !== "held-lock") await call(actor, "close-held");
        const receipt = await call(opener, "probe", {
          inject: mode.includes("-") && mode !== "outside-cleanup" ? "" : mode,
        });
        console.log(JSON.stringify({ fixture: mode, receipt }));
        if (mode === "held-lock" || mode === "released-busy") {
          marker(receipt);
          expect(receipt.removalCalls).toBe(mode === "held-lock" ? 0 : 1);
          expect(await call(actor, "read-held")).toBe("held-marker");
          expect(await call(actor, "remnant")).toBe(true);
        } else if (mode === "NotFoundError") {
          marker(receipt);
          expect(receipt.removalCalls).toBe(1);
        } else {
          expect(receipt.removalCalls).toBe(1);
          expect(receipt).toMatchObject({
            ok: false,
            error:
              mode === "outside-cleanup" ? "NoModificationAllowedError" : mode,
          });
        }
      } finally {
        await call(actor, "close-held");
      }
      // Reclamation must remain possible; a permanently ignored directory fails.
      marker(await call(opener, "probe"));
      expect(await call(actor, "remnant")).toBe(false);
    });
  }
} finally {
  if (page) {
    await page.evaluate("globalThis.opfsFixture?.stop()").catch(() => {});
    await page.navigate(new URL("/", address).href).catch(() => {});
    await page
      .command("Storage.clearDataForOrigin", { origin, storageTypes: "all" })
      .catch(() => {});
    page.close();
  }
  hub.server.stop(true);
  hub.db.db.close();
  hub.auth.db.close();
}
if (!results.length || results.some((result) => !result.ok))
  throw Error(
    `${results.filter((result) => !result.ok).length}/${results.length} OPFS checks failed`,
  );
