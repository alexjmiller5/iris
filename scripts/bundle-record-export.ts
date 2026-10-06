import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { parseArgs } from "node:util";

// UI-owned serialization stays separate from generated Life Data core resources.
const { values } = parseArgs({
  args: process.argv.slice(2),
  options: {
    output: { type: "string" },
    check: { type: "boolean", default: false },
  },
});
const root = resolve(import.meta.dir, "..");
const output =
  values.output ??
  resolve(root, "packages/LifeKit/Sources/LifeKit/Resources/record-export.js");
const result = await Bun.build({
  entrypoints: [resolve(root, "apps/web/src/lib/export/native-entry.ts")],
  target: "browser",
  format: "iife",
  minify: { whitespace: true },
});
if (!result.success)
  throw new AggregateError(result.logs, "Record export bundle failed");
const script = await result.outputs[0].text();
if (values.check) {
  if ((await readFile(output, "utf8")) !== script)
    throw Error("Record export resource is stale.");
} else {
  await writeFile(output, script);
}
