import { createHash } from "node:crypto";
import {
  mkdtemp,
  readFile,
  writeFile,
  readdir,
  copyFile,
  mkdir,
  rm,
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
  const sourceRoot = resolve(dirname(sourcePath), '../..');
  const schemaPath = join(sourceRoot, 'core/contract/core.json');
  const pinSchemaPath = join(sourceRoot, 'core/schema/sidebar-pins.json');
  const viewSchemaPath = join(sourceRoot, 'core/schema/saved-views.json');
  await mkdir(join(root, 'packages/core/schema'), { recursive: true });
  await copyFile(viewSchemaPath, join(root, 'packages/core/schema/saved-views.json'));
  await copyFile(pinSchemaPath, join(root, 'packages/core/schema/sidebar-pins.json'));
  const fixtureDir = join(root, 'packages/LifeKit/Tests/LifeKitTests/Fixtures');
  await mkdir(fixtureDir, { recursive: true });
  await copyFile(join(sourceRoot, 'tests/fixtures/read-dependencies.json'), join(fixtureDir, 'read-dependencies.json'));
  await copyFile(join(sourceRoot, 'tests/fixtures/enrollment-policy.json'), join(fixtureDir, 'enrollment-policy.json'));
  const generatorPath = join(sourceRoot, 'scripts/generate-core-contract.ts');
  const { generateContract } = await import(generatorPath);
  const generated = generateContract(JSON.parse(await readFile(schemaPath, 'utf8')));
  if (await readFile(join(dirname(sourcePath), 'contract.generated.ts'), 'utf8') !== generated.typescript
    || await readFile(join(sourceRoot, 'core/generated/CoreContract.generated.swift'), 'utf8') !== generated.swift) {
    throw new Error('Source core contract is stale; regenerate it in life-data first.');
  }
  const contractDir = join(root, 'packages/core/contract');
  const swiftDir = join(root, 'packages/LifeKit/Sources/LifeKit/Generated');
  await mkdir(contractDir, { recursive: true });
  await mkdir(swiftDir, { recursive: true });
  await copyFile(schemaPath, join(contractDir, 'core.json'));
  await copyFile(generatorPath, join(contractDir, 'generate-core-contract.ts'));
  await writeFile(join(root, 'packages/core/contract.generated.ts'), generated.typescript);
  await writeFile(join(swiftDir, 'CoreContract.generated.swift'), generated.swift);
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
  try {
    const declarations = Bun.spawn(
      [
        "bun",
        "x",
        "--no-install",
        "tsc",
        "--ignoreConfig",
        "--strict",
        "--declaration",
        "--emitDeclarationOnly",
        "--target",
        "ES2022",
        "--module",
        "esnext",
        "--moduleResolution",
        "bundler",
        "--allowImportingTsExtensions",
        "--resolveJsonModule",
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
    coreHash.update('schema/saved-views.json\0').update(await readFile(viewSchemaPath));
    coreHash.update('schema/sidebar-pins.json\0').update(await readFile(pinSchemaPath));
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
        "--strict",
        "--declaration",
        "--emitDeclarationOnly",
        "--target",
        "ES2022",
        "--module",
        "esnext",
        "--moduleResolution",
        "bundler",
        "--allowImportingTsExtensions",
        "--resolveJsonModule",
        "--skipLibCheck",
        "--outDir",
        temp,
        clientPath,
      ],
      { cwd: root, stdout: "inherit", stderr: "inherit" },
    );
    if ((await clientDeclarations.exited) !== 0)
      throw new Error("Client declarations failed");
    const clientTypes = join(temp, "src");
    for (const name of await readdir(clientTypes))
      if (name.endsWith(".d.ts") && name !== "validate.d.ts")
        await copyFile(join(clientTypes, name), join(root, "packages/core", name));

    // Relative script imports of client.js need the same declaration entrypoint
    // as the package export, not a similarly named internal source module.
    await writeFile(join(root, 'packages/core/client.d.ts'), coreBanner + "export * from './index.d.ts';\n");
    console.log(`Bundled validator ${sourceHash}`);
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
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
