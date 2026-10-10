import { resolve } from "node:path";
import { disposableOrigin } from "./test-origin";
disposableOrigin(
  process.env.IRIS_TEST_URL ??
    "http://iris-markdown.localhost:5198/workspace?review",
);
const source = process.argv[2];
if (!source) throw Error("Provide the soma checkout");
const model = resolve(import.meta.dir, "../apps/web/src/lib/record-undo.ts");
const page = resolve(
  import.meta.dir,
  "../apps/web/src/routes/workspace/+page.svelte",
);
const mutations = [
  {
    name: "unchanged fields stay stale",
    file: model,
    before: "values[column] === (before[column] ?? '')",
    after: "false",
  },
  {
    name: "newer drafts are overwritten",
    file: model,
    before: "values[column] === (before[column] ?? '')",
    after: "true",
  },
  {
    name: "baseline uses old values",
    file: model,
    before: "[column, after[column] ?? '']",
    after: "[column, before[column] ?? '']",
  },
  {
    name: "newer drafts do not require review",
    file: model,
    before: "columns.some((column) => next[column] !== baseline[column])",
    after: "false",
  },
  {
    name: "new catalog fields enter mounted draft",
    file: model,
    before: "Object.keys(values)",
    after: "Object.keys(after)",
  },
  {
    name: "unsaved draft becomes saved baseline",
    file: model,
    before: "JSON.stringify(baseline)",
    after: "JSON.stringify(next)",
  },
  {
    name: "undo does not pause autosave",
    file: page,
    before: "undoPaused = reconciled.dirty;",
    after: "undoPaused = false;",
    count: 4,
    browser: "a rejected edit",
  },
  {
    name: "restoring loses the kept draft",
    file: page,
    before: "const preserveDraft = restoring && undoPaused;",
    after: "const preserveDraft = false;",
    browser: "undoing creation",
  },
  {
    name: "undo uses the wrong receipt",
    file: page,
    before: "receiptId: action.receiptId",
    after: "receiptId: 'missing-receipt'",
    browser: "edit undo restores",
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
    throw Error("Mutation target moved: " + mutation.name);
  if (process.argv.includes("--check")) {
    console.log("MATCHED: " + mutation.name);
    continue;
  }
  try {
    await Bun.write(
      mutation.file,
      original.replaceAll(mutation.before, mutation.after),
    );
    const child = Bun.spawn(
      mutation.browser
        ? ["bun", "scripts/test-session-undo.ts", source]
        : [
            "bun",
            "run",
            "--cwd",
            "apps/web",
            "test",
            "src/lib/record-undo.spec.ts",
          ],
      {
        cwd: resolve(import.meta.dir, ".."),
        env: { ...process.env, IRIS_UNDO_CASE: mutation.browser ?? "" },
        stdout: "pipe",
        stderr: "pipe",
      },
    );
    const [status, out, err] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    if (status === 0) throw Error("Mutation survived: " + mutation.name);
    if (
      !/AssertionError|expect\(.*\)|expected |Error: element\(s\) not found/s.test(
        out + err,
      )
    )
      throw Error(
        "Mutation had no assertion failure: " +
          mutation.name +
          "\n" +
          out +
          err,
      );
    console.log("CAUGHT: " + mutation.name);
    if (mutation.browser) console.log((out + err).slice(0, 1800));
  } finally {
    await Bun.write(mutation.file, original);
  }
}
