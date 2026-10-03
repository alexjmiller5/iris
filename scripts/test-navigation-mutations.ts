// Serialize with all other CDP clients and own this checkout while mutating it.
import { disposableOrigin } from "./test-origin";

disposableOrigin(
  process.env.LIFE_UI_TEST_URL ??
    "http://life-ui-navigation.localhost:5224/workspace?review",
);
const source = process.argv[2];
if (!source)
  throw new Error(
    "Usage: bun scripts/test-navigation-mutations.ts <life-data-checkout> [--check]",
  );
const page = "apps/web/src/routes/workspace/+page.svelte";
const model = "apps/web/src/lib/workspace-navigation.ts";
const mutations = [
  {
    name: "closed editor leaves its row in the URL",
    file: page,
    before: "void reflectLocation();\n\t\treturn true;",
    after: "return true;",
    test: "graph and trash",
  },
  {
    name: "linked destination hides refresh errors",
    file: page,
    before: "version = editorVersion;\n\t\t\tawait Promise.all",
    after: "/* retain obsolete version */\n\t\t\tawait Promise.all",
    test: "destination refresh",
  },
  {
    name: "lookup permits a source write",
    file: page,
    before:
      "disabled={busy || navigationLoading || readOnly || blocked || trash}",
    after: "disabled={busy || readOnly || blocked || trash}",
    test: "pending linked lookup",
  },
  {
    name: "copy retains unrelated query and fragment",
    file: model,
    before: "new URL(url.pathname, url.origin)",
    after: "new URL(url.href)",
    test: "Copy link",
  },
  {
    name: "Back ignores cancelled discard",
    file: page,
    before: "if ((opened && busy) || !discard()) {",
    after: "if (opened && busy) {",
    test: "Back cancellation",
  },
  {
    name: "Back bypasses pending write receipt",
    file: page,
    before: "if ((opened && busy) || !discard()) {",
    after: "if (!writing && !bodySaving && !discard()) {",
    test: "pending write",
  },
  {
    name: "reload ignores the linked destination",
    file: page,
    before: "await restoreLocation(linked);",
    after: "await reflectLocation(true);",
    test: "row reload",
  },
  {
    name: "view URL uses mutable display name",
    file: page,
    before: "view: chosenView?.id ?? null,",
    after: "view: chosenView?.name ?? null,",
    test: "saved view and row",
  },
  {
    name: "stale linked lookup changes the editor",
    file: page,
    before: "if (!current()) return;\n\t\t\tresetView();",
    after: "resetView();",
    test: "newer record wins",
  },
  {
    name: "new record lookup fails to invalidate old link",
    file: page,
    before: "if (!database || busy) return false;\n\t\tlocationRequest++;",
    after: "if (!database || busy) return false;",
    test: "newer record wins",
  },
  {
    name: "missing record silently falls back",
    file: model,
    before: "if (!row)\n",
    after: "if (false)\n",
    test: "absent targets",
  },
  {
    name: "URL record projection drops hidden properties",
    file: model,
    before: "filters: [{ column: 'id', op: 'eq', value: destination.row }],",
    after:
      "columns: ['id', 'headline'], filters: [{ column: 'id', op: 'eq', value: destination.row }],",
    test: "saved view and row",
  },
];

for (const mutation of mutations) {
  const original = await Bun.file(mutation.file).text();
  if (original.split(mutation.before).length !== 2)
    throw new Error(`Expected one target: ${mutation.name}`);
  const changed = original.replace(mutation.before, mutation.after);
  if (process.argv.includes("--check")) {
    console.log(`MATCHED: ${mutation.name}`);
    continue;
  }
  try {
    await Bun.write(mutation.file, changed);
    const run = Bun.spawn(
      ["bun", "scripts/test-workspace-navigation.ts", source],
      {
        env: { ...process.env, LIFE_UI_NAVIGATION_CASE: mutation.test },
        stdout: "pipe",
        stderr: "pipe",
      },
    );
    const [code, out, err] = await Promise.all([
      run.exited,
      new Response(run.stdout).text(),
      new Response(run.stderr).text(),
    ]);
    if (code === 0 || !err.includes("FAIL: ") || !err.includes("expect("))
      throw new Error(
        `Mutation did not produce a regression assertion: ${mutation.name}\n${out}\n${err}`,
      );
    console.log(
      `KILLED: ${mutation.name}\n${err.split("\n").slice(0, 10).join("\n")}`,
    );
  } finally {
    if ((await Bun.file(mutation.file).text()) !== changed)
      throw new Error(
        `Concurrent change in ${mutation.file}; refusing to overwrite it.`,
      );
    await Bun.write(mutation.file, original);
  }
}
