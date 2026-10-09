import { createHash } from "node:crypto";
import { copyFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";

// All compiler state stays in Nix's build directory or a disposable external directory.
const root = resolve(import.meta.dir, "..");
const vendor = join(root, "vendor/wa-sqlite");
const args = new Set(process.argv.slice(2));
if (
  [...args].some((arg) => !["--write", "--check", "--rebuild"].includes(arg)) ||
  (args.has("--write") && args.has("--check"))
)
  throw new Error(
    "Usage: bun scripts/build-wa-sqlite.ts [--check | --write] [--rebuild]",
  );
const manifest = JSON.parse(
  await readFile(join(vendor, "manifest.json"), "utf8"),
);
const web = JSON.parse(
  await readFile(join(root, "apps/web/package.json"), "utf8"),
);
if (
  web.dependencies["wa-sqlite"] !==
  `github:rhashimoto/wa-sqlite#${manifest.waSqlite.revision}`
)
  throw new Error(
    "The wa-sqlite JS API/VFS dependency must match the WASM source revision.",
  );
const scratch = await mkdtemp(join(tmpdir(), "iris-wa-sqlite-"));
try {
  for (const name of ["flake.nix", "flake.lock", "manifest.json"])
    await copyFile(join(vendor, name), join(scratch, name));
  const process = Bun.spawn(
    [
      "nix",
      "build",
      `path:${scratch}`,
      "--no-link",
      "--no-write-lock-file",
      "--json",
      ...(args.has("--rebuild") ? ["--rebuild"] : []),
    ],
    { stdout: "pipe", stderr: "inherit" },
  );
  const output = await new Response(process.stdout).text();
  if (await process.exited) throw new Error("Pinned wa-sqlite build failed.");
  const [
    {
      outputs: { out },
    },
  ] = JSON.parse(output);
  for (const name of ["wa-sqlite.mjs", "wa-sqlite.wasm", "LICENSE"]) {
    const built = await readFile(join(out, name));
    const sha256 = createHash("sha256").update(built).digest("hex");
    if (args.has("--write")) {
      await writeFile(join(vendor, name), built);
      manifest.artifacts[name] = sha256;
    } else {
      const committed = await readFile(join(vendor, name));
      if (!built.equals(committed) || sha256 !== manifest.artifacts[name])
        throw new Error(
          `${name} differs from the pinned build or recorded SHA-256.`,
        );
    }
    console.log(`${name} ${sha256}`);
  }
  if (args.has("--write"))
    await writeFile(
      join(vendor, "manifest.json"),
      `${JSON.stringify(manifest, null, 2)}\n`,
    );
  console.log(
    args.has("--write")
      ? "Regenerated pinned FTS5 artifacts."
      : "Pinned FTS5 artifacts match byte for byte.",
  );
} finally {
  await rm(scratch, { recursive: true, force: true });
}
