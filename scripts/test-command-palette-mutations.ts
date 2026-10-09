import { resolve } from "node:path";
import { disposableOrigin } from "./test-origin";

disposableOrigin(
  process.env.IRIS_TEST_URL ??
    "http://iris-palette.localhost:5226/workspace?review",
);
const source = process.argv[2];
if (!source)
  throw Error(
    "Usage: bun scripts/test-command-palette-mutations.ts <soma-checkout> [--unit|--browser|--check]",
  );
const model = resolve(
  import.meta.dir,
  "../apps/web/src/lib/command-palette.ts",
);
const component = resolve(
  import.meta.dir,
  "../apps/web/src/lib/SearchDialog.svelte",
);
const page = resolve(
  import.meta.dir,
  "../apps/web/src/routes/workspace/+page.svelte",
);
const mutations = [
  {
    name: "identity uses mutable labels",
    file: model,
    before:
      "return JSON.stringify([entry.kind, entry.table, entry.kind === 'table' ? null : entry.id]);",
    after: "return entry.label;",
  },
  {
    name: "record matches are filtered a second time",
    file: model,
    before: "...hits.map((hit)",
    after:
      "...hits.filter(hit => hit.label.toLowerCase().includes(query)).map((hit)",
  },
  {
    name: "keyboard selects unavailable views",
    file: model,
    before:
      "entries.filter((entry) => !('unavailable' in entry && entry.unavailable))",
    after: "entries",
  },
  {
    name: "late lists reset selection",
    file: model,
    before: "index < 0 ? entryKey(enabled[0]) : key",
    after: "entryKey(enabled[0])",
  },
  {
    name: "closed loaders publish and keep requesting",
    file: model,
    before: "if (!current()) return;",
    after: "/* ignore lifetime */",
    count: 3,
  },
  {
    name: "invalid core view loses its disabled reason",
    file: model,
    before: "view.unavailable || !view.view || !view.definition",
    after: "false",
  },
  {
    name: "component omits unavailable control state",
    file: component,
    before:
      "disabled={opening || !!('unavailable' in entry && entry.unavailable)}",
    after: "disabled={opening}",
  },
  {
    name: "palette ignores dirty cancel",
    file: page,
    before:
      "if (!current() || busy || writing || bodySaving || !discard()) return false;",
    after: "if (!current() || busy || writing || bodySaving) return false;",
    browser: "cancelled dirty",
  },
  {
    name: "closed destination still applies",
    file: page,
    before:
      "if (!current() || busy || writing || bodySaving || !discard()) return false;",
    after: "if (busy || writing || bodySaving || !discard()) return false;",
    browser: "closed destination",
  },
  {
    name: "saved destination ignores stable view id",
    file: page,
    before: "view: destination.kind === 'view' ? destination.id : null,",
    after: "view: null,",
    browser: "stale saved-view",
  },
];
for (const mutation of mutations) {
  if (
    (process.argv.includes("--unit") && mutation.browser) ||
    (process.argv.includes("--browser") && !mutation.browser)
  )
    continue;
  const original = await Bun.file(mutation.file).text();
  if (original.split(mutation.before).length !== (mutation.count ?? 1) + 1)
    throw Error(`Expected mutation target: ${mutation.name}`);
  if (process.argv.includes("--check")) {
    console.log(`MATCHED: ${mutation.name}`);
    continue;
  }
  const changed = original.replaceAll(mutation.before, mutation.after);
  try {
    await Bun.write(mutation.file, changed);
    const command = mutation.browser
      ? ["bun", "scripts/test-command-palette.ts", source]
      : [
          "bun",
          "run",
          "--cwd",
          "apps/web",
          "test",
          "src/lib/command-palette.spec.ts",
          "src/lib/SearchDialog.spec.ts",
          "src/lib/search-dialog.spec.ts",
        ];
    const child = Bun.spawn(command, {
      cwd: resolve(import.meta.dir, ".."),
      env: { ...process.env, IRIS_PALETTE_CASE: mutation.browser ?? "" },
      stdout: "pipe",
      stderr: "pipe",
    });
    const [code, out, err] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    if (
      code === 0 ||
      !(out + err).includes(mutation.browser ? "expect(" : "AssertionError")
    )
      throw Error(
        `Mutation did not produce a behavioral assertion: ${mutation.name}\n${out}\n${err}`,
      );
    console.log(`KILLED: ${mutation.name}`);
  } finally {
    if ((await Bun.file(mutation.file).text()) !== changed)
      throw Error(`Concurrent edit in ${mutation.file}; refusing overwrite`);
    await Bun.write(mutation.file, original);
  }
}
