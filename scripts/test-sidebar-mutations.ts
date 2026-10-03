import { resolve } from "node:path";
import { disposableOrigin } from "./test-origin";
disposableOrigin(
  process.env.LIFE_UI_TEST_URL ??
    "http://life-ui-recents.localhost:5236/workspace?review",
);
const source = process.argv[2];
if (!source) throw Error("Provide life-data checkout");
const model = "apps/web/src/lib/sidebar-recents.ts",
  tables = "apps/web/src/lib/SidebarTables.svelte",
  component = "apps/web/src/lib/SidebarRecents.svelte",
  page = "apps/web/src/routes/workspace/+page.svelte";
const mutations = [
  {
    name: "unread history is overwritten",
    file: page,
    before: "if (recentReadError) return;",
    after: "/* unread preference overwritten */",
    browser: "storage read",
  },
  {
    name: "record labels bypass shared display policy",
    file: model,
    before:
      "displayName(resolved.row, typeof display === 'string' ? display : undefined)",
    after: "String(resolved.row[String(display ?? 'id')] ?? resolved.row.id)",
  },
  {
    name: "identity drops saved-view context",
    file: model,
    before: "[destination.table, destination.view, destination.row]",
    after: "[destination.table, destination.row]",
  },
  {
    name: "history exceeds eight entries",
    file: model,
    before: "const limit = 8;",
    after: "const limit = 9;",
  },
  {
    name: "serialization leaks mutable extra fields",
    file: model,
    before: "entries: bounded(destinations)",
    after: "entries: destinations",
  },
  {
    name: "late label responses overwrite context",
    file: model,
    before: "if (!current()) return;",
    after: "/* lifetime ignored */",
    count: 4,
  },
  {
    name: "missing entries lose their reason",
    file: model,
    before:
      "unavailable: error instanceof Error ? error.message : String(error)",
    after: "unavailable: null",
  },
  {
    name: "system partition ignores core boolean",
    file: tables,
    before: "table.readOnly === true",
    after: "false",
  },
  {
    name: "unavailable recent remains clickable",
    file: component,
    before: "disabled={busy || entry.loading || !!entry.unavailable}",
    after: "disabled={busy || entry.loading}",
  },
  {
    name: "worker drops core catalog metadata",
    file: "apps/web/src/lib/database.worker.ts",
    before: "catalog: await local.catalog({}),",
    after:
      "catalog: await (await import('life-ui-core/client')).readCatalog(db),",
    browser: "system catalog",
  },
  {
    name: "recent choice discards despite Cancel",
    file: page,
    before:
      "if (!current() || busy || writing || bodySaving || !discard()) return false;",
    after: "if (!current() || busy || writing || bodySaving) return false;",
    browser: "cancelled discard",
  },
  {
    name: "superseded recent lookup still applies",
    file: page,
    before:
      "if (!current() || busy || writing || bodySaving || !discard()) return false;",
    after: "if (busy || writing || bodySaving || !discard()) return false;",
    browser: "late recent lookup",
  },
];
for (const mutation of mutations) {
  if (
    (process.argv.includes("--unit") && mutation.browser) ||
    (process.argv.includes("--browser") && !mutation.browser)
  )
    continue;
  const path = resolve(import.meta.dir, "..", mutation.file),
    original = await Bun.file(path).text();
  if (original.split(mutation.before).length !== (mutation.count ?? 1) + 1)
    throw Error(`Mutation target mismatch: ${mutation.name}`);
  if (process.argv.includes("--check")) {
    console.log("MATCHED:", mutation.name);
    continue;
  }
  const changed = original.replaceAll(mutation.before, mutation.after);
  try {
    await Bun.write(path, changed);
    const command = mutation.browser
      ? ["bun", "scripts/test-sidebar-recents.ts", source]
      : [
          "bun",
          "run",
          "--cwd",
          "apps/web",
          "test",
          "sidebar-recents.spec.ts",
          "sidebar-controls.spec.ts",
        ];
    const child = Bun.spawn(command, {
      cwd: resolve(import.meta.dir, ".."),
      env: { ...process.env, LIFE_UI_RECENTS_CASE: mutation.browser ?? "" },
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
      throw Error(`No behavioral assertion: ${mutation.name}\n${out}\n${err}`);
    console.log("KILLED:", mutation.name);
  } finally {
    if ((await Bun.file(path).text()) !== changed)
      throw Error(`Concurrent edit: ${path}`);
    await Bun.write(path, original);
  }
}
