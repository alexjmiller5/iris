// Run only while owning the route/worker and a dedicated disposable review page.
// Each real browser regression must detect the named behavioral mutation.
const source = process.argv[2];
if (!source) throw new Error('Usage: bun scripts/test-workspace-mutations.ts <soma-checkout> [--check]');
const checkOnly = process.argv.includes('--check');
const route = 'apps/web/src/routes/workspace/+page.svelte';
const worker = 'apps/web/src/lib/database.worker.ts';
const field = 'apps/web/src/lib/FieldEditor.svelte';
const bar = 'apps/web/src/lib/filter-bar.ts';
const mutations: { name: string; file: string; test: string; edits: [string | RegExp, string][] }[] = [
	{ name: 'write locks removed', file: route, test: 'trash reply locks', edits: [
		['class="workspace-controls" disabled={writing}', 'class="workspace-controls" disabled={false}'],
		[/\n\t\twriting \|\|\n\t\tselected\?\.deleted_at/, '\n\t\tselected?.deleted_at']
	] },
	{ name: 'canonical draft reconciliation removed', file: route, test: 'canonical SQL', edits: [
		['draft = rowDraft(stored);', '/* mutation: leave the draft unchanged */']
	] },
	{ name: 'dynamic options excluded', file: worker, test: 'dynamic options are available', edits: [
		['return local.options(args);', 'return (await readCatalog(db)).properties.find(p => p.tbl === args.table && p.col === args.column)?.options?.map(o => o.v) ?? [];']
	] },
	{ name: 'legacy selected values omitted', file: field, test: 'unknown selections', edits: [
		['...(multi ? list(value) : [value].filter(Boolean))', '...[]']
	] },
	{ name: 'old search and trash retained', file: route, test: 'workspace switch resets', edits: [
		["\t\tsearch = '';\n\t\ttrash = false;\n", ''],
		["search = definition?.search ?? '';", 'search = definition?.search ?? search;'],
		['trash = definition?.trash ?? false;', 'trash = definition?.trash ?? trash;']
	] },
	{ name: 'pending count frozen', file: route, test: 'pending count', edits: [
		['pendingEdits = state.status.pendingUiEdits;', 'pendingEdits = 0;']
	] },
	{ name: 'removing one chip drops the others', file: bar, test: 'combined filters', edits: [
		['} else filters.splice(ref.index, 1);', '} else filters.splice(0);']
	] },
	{ name: 'boolean filters always match checked', file: bar, test: 'boolean filters', edits: [
		["if (type === 'bool') return raw === 'true';", "if (type === 'bool') return true;"]
	] },
	{ name: 'empty numeric input becomes zero', file: bar, test: 'empty numeric', edits: [
		["rule.values.filter((v) => v.trim() !== '').map((v) => parse(v, type))", 'rule.values.map((v) => parse(v, type))']
	] }
];
for (const mutation of mutations) {
	const original = await Bun.file(mutation.file).text();
	let changed = original;
	for (const [before, after] of mutation.edits) {
		const matches = typeof before === 'string'
			? changed.split(before).length - 1
			: [...changed.matchAll(new RegExp(before.source, 'g'))].length;
		if (matches !== 1) throw new Error(`Expected one mutation target (${matches} found): ${mutation.name}`);
		changed = changed.replace(before, after);
	}
	if (checkOnly) { console.log(`MATCHED: ${mutation.name}`); continue; }
	try {
		await Bun.write(mutation.file, changed);
		const run = Bun.spawn(['bun', 'scripts/test-workspace-regressions.ts', source], {
			env: { ...process.env, IRIS_TEST_CASE: mutation.test }, stdout: 'pipe', stderr: 'pipe'
		});
		const [code, out, err] = await Promise.all([run.exited, new Response(run.stdout).text(), new Response(run.stderr).text()]);
		if (code === 0 || !err.includes('FAIL: ') || !err.includes('expect('))
			throw new Error(`Mutation did not produce a regression assertion: ${mutation.name}\n${out}\n${err}`);
		console.log(`KILLED: ${mutation.name}`);
	} finally {
		if (await Bun.file(mutation.file).text() !== changed)
			throw new Error(`Concurrent changes in ${mutation.file}; refusing to overwrite them.`);
		await Bun.write(mutation.file, original);
	}
}
