import { resolve } from "node:path";
import { disposableOrigin } from "./test-origin";
disposableOrigin(
  process.env.IRIS_TEST_URL ??
    "http://iris-grid.localhost:5228/workspace?review",
);
const source = process.argv[2];
if (!source)
  throw Error(
    "Usage: bun scripts/test-grid-mutations.ts <soma-checkout> [--unit|--browser|--check]",
  );
const model = resolve(import.meta.dir, "../apps/web/src/lib/record-grid.ts");
const component = resolve(
  import.meta.dir,
  "../apps/web/src/lib/FieldEditor.svelte",
);
const host = resolve(
  import.meta.dir,
  "../apps/web/src/routes/workspace/+page.svelte",
);
const grid = resolve(import.meta.dir, "../apps/web/src/lib/RecordGrid.svelte");
const mutations = [
  {
    name: "duplicate reference chips reuse duplicate keys",
    file: component,
    before: "[...new Set(list(value))]",
    after: "list(value)",
  },
  {
    name: "rejected cell traps Tab in repeated writes",
    file: grid,
    before: "if (event.key === 'Tab' && cellState.error) return;",
    after: "/* trap Tab after rejection */",
    browser: "validation failure",
  },
  {
    name: "cursor uses first row instead of selected identity",
    file: model,
    before: "rows.findIndex((row) => String(row.id) === cell.rowId)",
    after: "0",
  },
  {
    name: "clear writes numeric zero",
    file: model,
    before: "\n\t\t\t? null\n\t\t\t: numeric",
    after: "\n\t\t\t? 0\n\t\t\t: numeric",
  },
  {
    name: "duplicate copies system identity",
    file: model,
    before: "!managed.has(p.col) && ",
    after: "",
  },
  {
    name: "late lookup replaces the active editor",
    file: model,
    before: "if (request !== generation) return;",
    after: "/* accept stale lookup */",
  },
  {
    name: "old failure publishes into the new context",
    file: model,
    before: "if (request === generation)",
    after: "if (true)",
    count: 2,
  },
  {
    name: "failed save loses the draft",
    file: model,
    before: "\n\t\t\t\t\t\tedit,\n\t\t\t\t\t\tphase: 'editing'",
    after: "\n\t\t\t\t\t\tedit: null,\n\t\t\t\t\t\tphase: 'editing'",
  },
  {
    name: "pending writes can be submitted twice",
    file: model,
    before:
      "if (state.phase === 'saving' || state.phase === 'loading') return false;",
    after: "if (state.phase === 'loading') return false;",
  },
  {
    name: "unchanged cell creates an extra write",
    file: model,
    before: "if (edit.raw === rawValue(edit.baseline[edit.cell.column]))",
    after: "if (false)",
  },
  {
    name: "read-only plain fields become editable",
    file: component,
    before:
      "inputmode={['number', 'int'].includes(property.type ?? '') ? 'decimal' : undefined}\n\t\t\t{disabled}",
    after:
      "inputmode={['number', 'int'].includes(property.type ?? '') ? 'decimal' : undefined}",
  },
  {
    name: "creation: copied null silently falls back to a SQL default",
    file: model,
    before: ": !explicit.has(property.col) && !Object.hasOwn(copied, property.col)",
    after: ": raw === ''",
  },
  {
    name: "whitespace numeric input becomes zero",
    file: model,
    before: "raw === '' || (numeric && raw.trim() === '')",
    after: "raw === ''",
  },

  {
    name: "cell writes omit the original revision",
    file: host,
    before: "expectedUpdatedAt: editRevision(cell.baseline)",
    after: "/* omit expected revision */",
    browser: "stale row",
  },
  {
    name: "cell entry skips the record draft guard",
    file: host,
    before: "!property || !canEditCell(property) || !discard()",
    after: "!property || !canEditCell(property)",
    browser: "pending write",
  },
  {
    name: "grid trash drops fresh revision",
    file: host,
    before: "expectedUpdatedAt: editRevision(found[0])",
    after: "/* omit revision */",
    browser: "grid trash",
  },
  {
    name: "late host lookup error crosses contexts",
    file: host,
    before: "if (!current()) return false;\n\t\t\tthrow e;",
    after: "throw e;",
    browser: "cancelled cell navigation",
  },
  {
    name: "virtualizer observes table instead of scroll container",
    file: grid,
    before: "\n\t\t\t\t{scrollRef}",
    after: "",
    render: true,
  },
  {
    name: "rejected keyboard commit loses input focus",
    file: grid,
    before: "if (!saved && cellState.phase === 'editing')",
    after: "if (false)",
    browser: "validation failure",
  },
  {
    name: "removed property hides retained raw draft",
    file: grid,
    before: "!columns.includes(edit.cell.column) ||",
    after: "",
    render: true,
  },
  {
    name: "changed editability leaves current input writable",
    file: grid,
    before:
      "disabled={busy || cellState.phase === 'saving' || !canEdit(property)}",
    after: "disabled={busy || cellState.phase === 'saving'}",
    count: 2,
    render: true,
  },
];
for (const mutation of mutations) {
  if (
    process.env.IRIS_GRID_MUTATION &&
    !mutation.name.includes(process.env.IRIS_GRID_MUTATION)
  )
    continue;
  if (
    (process.argv.includes("--unit") &&
      (mutation.browser || mutation.render)) ||
    (process.argv.includes("--browser") &&
      !mutation.browser &&
      !mutation.render)
  )
    continue;
  const original = await Bun.file(mutation.file).text();
  if (original.split(mutation.before).length !== (mutation.count ?? 1) + 1)
    throw Error(`Expected mutation target: ${mutation.name}`);
  if (process.argv.includes("--check")) {
    console.log("MATCHED", mutation.name);
    continue;
  }
  const changed = original.replaceAll(mutation.before, mutation.after);
  try {
    await Bun.write(mutation.file, changed);
    const command = mutation.render
      ? ["bun", "scripts/test-grid-components.ts"]
      : mutation.browser
        ? ["bun", "scripts/test-record-grid.ts", source]
        : [
            "bun",
            "run",
            "--cwd",
            "apps/web",
            "test",
            "src/lib/record-grid.spec.ts",
            "src/lib/FieldEditor.spec.ts",
          ];
    const child = Bun.spawn(command, {
      cwd: resolve(import.meta.dir, ".."),
      env: { ...process.env, IRIS_GRID_CASE: mutation.browser ?? "" },
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
      !(out + err).includes(
        mutation.browser || mutation.render ? "expect(" : "AssertionError",
      )
    )
      throw Error(
        `No behavioral assertion caught ${mutation.name}\n${out}\n${err}`,
      );
    console.log("KILLED", mutation.name);
  } finally {
    if ((await Bun.file(mutation.file).text()) !== changed)
      throw Error("Concurrent mutation edit; refusing overwrite");
    await Bun.write(mutation.file, original);
  }
}
