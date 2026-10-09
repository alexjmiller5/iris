// Run only while owning the route/worker and a dedicated disposable review page.
// Each real browser regression must detect the named behavioral mutation.
const source = process.argv[2];
if (!source) throw new Error('Usage: bun scripts/test-workspace-mutations.ts <life-data-checkout> [--check]');
const checkOnly = process.argv.includes('--check');
const route = 'apps/web/src/routes/workspace/+page.svelte';
const worker = 'apps/web/src/lib/database.worker.ts';
const mutations: { name: string; file: string; test: string; edits: [string | RegExp, string][] }[] = [
	{ name: 'write locks removed', file: route, test: 'write in flight locks', edits: [
		['class="workspace-controls" disabled={writing}', 'class="workspace-controls" disabled={false}'],
		[/writing\s*\|\|\s*!!p\.derived_by/, '!!p.derived_by']
	] },
	{ name: 'canonical draft reconciliation removed', file: route, test: 'canonical SQL', edits: [
		['draft = rowDraft(stored);', '/* mutation: leave the draft unchanged */']
	] },
	{ name: 'dynamic options excluded', file: worker, test: 'dynamic options are available', edits: [
		['return local.options(args);', 'return (await readCatalog(db)).properties.find(p => p.tbl === args.table && p.col === args.column)?.options?.map(o => o.v) ?? [];']
	] },
	{ name: 'legacy selected values omitted', file: route, test: 'unknown selections', edits: [
		["...(p.type === 'multi_select' ? list(draft[p.col]) : [draft[p.col]].filter(Boolean))", '...[]']
	] },
	{ name: 'old filters retained', file: route, test: 'workspace switch resets', edits: [
		['filters = [];', '/* mutation: keep filters */']
	] },
	{ name: 'pending count frozen', file: route, test: 'pending count', edits: [
		['pendingEdits = state.status.pendingUiEdits;', 'pendingEdits = 0;']
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
			env: { ...process.env, LIFE_UI_TEST_CASE: mutation.test }, stdout: 'pipe', stderr: 'pipe'
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
