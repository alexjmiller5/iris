import { createHash } from "node:crypto";
import {
  mkdtemp,
  readFile,
  writeFile,
  readdir,
  copyFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

// Build artifacts only. The validator source is owned by life-data.
const source = process.argv[2];
if (!source)
  throw new Error(
    "Usage: bun scripts/bundle-core.ts <life-core/src/validate.ts> | --native",
  );
const root = resolve(import.meta.dir, "..");
if (source !== "--native") {
  const sourcePath = resolve(source);
  const sourceHash = createHash("sha256")
    .update(await readFile(sourcePath))
    .digest("hex");
  const banner = `// Generated from life-core/src/validate.ts. SHA-256: ${sourceHash}\n`;
  const browser = await Bun.build({
    entrypoints: [sourcePath],
    root: dirname(sourcePath),
    target: "browser",
    format: "esm",
    minify: { whitespace: true },
  });
  if (!browser.success)
    throw new AggregateError(browser.logs, "Validator build failed");
  await writeFile(
    join(root, "packages/core/validate.js"),
    banner + (await browser.outputs[0].text()),
  );

  const temp = await mkdtemp(join(tmpdir(), "life-ui-types-"));
  const declarations = Bun.spawn(
    [
      "bun",
      "x",
      "--no-install",
      "tsc",
      "--ignoreConfig",
      "--declaration",
      "--emitDeclarationOnly",
      "--target",
      "ES2022",
      "--module",
      "esnext",
      "--skipLibCheck",
      "--outDir",
      temp,
      sourcePath,
    ],
    { cwd: root, stdout: "inherit", stderr: "inherit" },
  );
  if ((await declarations.exited) !== 0)
    throw new Error("Validator declarations failed");
  await writeFile(
    join(root, "packages/core/validate.d.ts"),
    banner + (await readFile(join(temp, "validate.d.ts"), "utf8")),
  );
  // The web workspace consumes the full core from the same source checkout.
  const coreHash = createHash("sha256");
  for (const name of (await readdir(dirname(sourcePath)))
    .filter((n) => n.endsWith(".ts"))
    .sort()) {
    coreHash
      .update(name + "\0")
      .update(await readFile(join(dirname(sourcePath), name)));
  }
  const coreBanner = `// Generated from life-core. SHA-256: ${coreHash.digest("hex")}\n`;
  const clientPath = join(dirname(sourcePath), "index.ts");
  const client = await Bun.build({
    entrypoints: [clientPath],
    root: dirname(clientPath),
    target: "browser",
    format: "esm",
    minify: { whitespace: true },
  });
  if (!client.success)
    throw new AggregateError(client.logs, "Client core build failed");
  await writeFile(
    join(root, "packages/core/client.js"),
    coreBanner + (await client.outputs[0].text()),
  );
  const clientDeclarations = Bun.spawn(
    [
      "bun",
      "x",
      "--no-install",
      "tsc",
      "--ignoreConfig",
      "--declaration",
      "--emitDeclarationOnly",
      "--target",
      "ES2022",
      "--module",
      "esnext",
      "--moduleResolution",
      "bundler",
      "--allowImportingTsExtensions",
      "--skipLibCheck",
      "--outDir",
      temp,
      clientPath,
    ],
    { cwd: root, stdout: "inherit", stderr: "inherit" },
  );
  if ((await clientDeclarations.exited) !== 0)
    throw new Error("Client declarations failed");
  for (const name of await readdir(temp))
    if (name.endsWith(".d.ts") && name !== "validate.d.ts")
      await copyFile(join(temp, name), join(root, "packages/core", name));

  console.log(`Bundled validator ${sourceHash}`);
}

// CI rebuilds the native adapter from the checked-in client without life-data.
const clientSource = await readFile(
  join(root, "packages/core/client.js"),
  "utf8",
);
const coreBanner = clientSource.match(
  /^\/\/ Generated from life-core\. SHA-256: [a-f0-9]{64}\n/,
)?.[0];
if (!coreBanner)
  throw new Error(
    "Client core is missing its source SHA-256 banner; regenerate with bundle:core.",
  );

const native = await Bun.build({
  entrypoints: [join(root, "scripts/native-core.ts")],
  target: "browser",
  format: "iife",
  minify: { whitespace: true },
});
if (!native.success)
  throw new AggregateError(native.logs, "Native core build failed");
await writeFile(
  join(root, "packages/LifeKit/Sources/LifeKit/Resources/life-core.js"),
  coreBanner + (await native.outputs[0].text()),
);
console.log("Bundled native core from packages/core/client.js");
