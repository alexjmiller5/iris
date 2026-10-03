# Web quick navigation

Open **Find records** with Cmd+K or Ctrl+K. The dialog groups tables, saved views
and records in one keyboard list. Empty input shows navigation choices; typing
filters table/view labels and requests shared-core record search. Unavailable
saved views show the core's reason and cannot be selected.

Record search keeps its 200 ms debounce, literal-prefix FTS behavior, plain-text
excerpts and 50-row pages. More results advances the record offset independently
of navigation choices. Navigation label matching is case-insensitive substring
matching over already loaded metadata, not another record-search implementation.

The host reads saved views progressively through `listViews({table})` once per
dialog opening. Closing or switching workspace invalidates late receipts and
stops further list requests. Metadata failures leave table choices and record
search usable. Choosing a table or saved view re-resolves its current catalog and
definition through the existing workspace destination helper. Pending writes
block navigation; cancelling draft discard retains the dialog, draft and URL.
Successful navigation uses the same table/view URL and history behavior as the
workspace controls. The dialog never receives a database or credentials.

`SearchDialog.svelte` retains `search(text, offset)`, `onchoose(hit)`, `onclose()`
and `incomplete`. Optional `destinations`, `navigationLoading`, `navigationError`
and `onnavigate(destination)` supply host navigation. Both choice callbacks may
return `false` to keep the dialog open. Destination identities include kind,
table and stable view/record ID; arriving groups preserve the keyboard selection.

## Verification

Run `bun run test`, `bun run check`, `bun run --cwd apps/web lint` and
`bun run build`. The fixture uses synthetic data and the actual Worker/OPFS
database with a disposable hub from a compatible life-data checkout. Open an
owned Chrome fixture tab at the reserved origin below and serialize CDP access
with any other browser test clients:

```sh
LIFE_UI_TEST_URL=http://life-ui-palette.localhost:5226/workspace?review \
  bun scripts/test-command-palette.ts /path/to/life-data
LIFE_UI_TEST_URL=http://life-ui-palette.localhost:5226/workspace?review \
  bun scripts/test-command-palette-mutations.ts /path/to/life-data
```

Set `LIFE_UI_TEST_CDP` for the browser endpoint and `LIFE_UI_TEST_SCREENSHOTS`
for desktop/narrow screenshots. `LIFE_UI_PALETTE_CASE` narrows an E2E case;
mutation `--unit` / `--browser` select a layer and `--check` verifies mutation
targets without changing source. Do not run unit/build commands against the
same Vite server during E2E: SvelteKit generation can reload the fixture.

Native navigation entries are a separate parity check; this web component does
not change native resources or close the broader search task.
