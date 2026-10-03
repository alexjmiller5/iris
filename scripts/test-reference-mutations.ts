// Run only while owning this route and a dedicated disposable browser page.
import { disposableOrigin } from './test-origin';

disposableOrigin(process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-relations.localhost:5223/workspace?review');
const source = process.argv[2];
if (!source) throw new Error('Usage: bun scripts/test-reference-mutations.ts <life-data-checkout> [--check]');
const file = 'apps/web/src/routes/workspace/+page.svelte';
const mutations: { name: string; test: string; edits: [string | RegExp, string][] }[] = [
	{ name: 'source table used for the target ID', test: 'single reference', edits: [
		['table: target.table,', 'table,']
	] },
	{ name: 'target read projects away editable fields', test: 'single reference', edits: [
		["filters: [{ column: 'id', op: 'eq', value: target.id }],", "columns: ['id', 'headline'], filters: [{ column: 'id', op: 'eq', value: target.id }],"]
	] },
	{ name: 'picker cache reused instead of reading the target', test: 'fresh opening', edits: [
		[/found = await workspace\.request\('rows', \{\s*view: \{\s*table: target\.table,[\s\S]*?\n\t\t\t\}\);/, 'found = Object.values(references).flat().filter(row => row.id === target.id).slice(0, 1);']
	] },
	{ name: 'discard confirmation bypassed', test: 'cancelled discard', edits: [
		['if (!discard()) return false;\n\t\tresetView();', 'resetView();']
	] },
	{ name: 'stale successful lookup accepted', test: 'held old-record', edits: [
		['if (!current()) return false;', '/* mutation: accept stale success */']
	] },
	{ name: 'stale failed lookup displayed', test: 'held old-record', edits: [
		['if (current()) throw e;', 'throw e;'],
		['if (current()) error = message(e);', 'error = message(e);']
	] },
	{ name: 'immutable references cannot be opened', test: 'immutable references', edits: [
		['disabled={busy || relationOpening === editorVersion || !available}', 'disabled={locked(p) || busy || relationOpening === editorVersion || !available}']
	] },
	{ name: 'skipped local targets cannot be opened', test: 'skipped tables', edits: [
		['catalog.tables.some((target) => target.id === p.ref_table)}', 'catalog.tables.some((target) => target.id === p.ref_table) && !skipped.includes(p.ref_table)}']
	] },
	{ name: 'body write no longer disables opening', test: 'body autosave locks', edits: [
		['disabled={busy || relationOpening === editorVersion || !available}', 'disabled={relationOpening === editorVersion || !available}']
	] },
	{ name: 'destination saved views never loaded', test: 'destination saved views', edits: [
		['await Promise.all([loadRows(), loadViews(), loadWriteability()]).catch((e) => {', 'await Promise.all([loadRows(), loadWriteability()]).catch((e) => {']
	] }
];

for (const mutation of mutations) {
	const original = await Bun.file(file).text();
	let changed = original;
	for (const [before, after] of mutation.edits) {
		const count = typeof before === 'string' ? changed.split(before).length - 1 : [...changed.matchAll(new RegExp(before.source, 'g'))].length;
		if (count !== 1) throw new Error(`Expected one mutation target (${count} found): ${mutation.name}`);
		changed = changed.replace(before, after);
	}
	if (process.argv.includes('--check')) { console.log(`MATCHED: ${mutation.name}`); continue; }
	try {
		await Bun.write(file, changed);
		const run = Bun.spawn(['bun', 'scripts/test-reference-navigation.ts', source], {
			env: { ...process.env, LIFE_UI_REFERENCE_CASE: mutation.test }, stdout: 'pipe', stderr: 'pipe'
		});
		const [code, out, err] = await Promise.all([run.exited, new Response(run.stdout).text(), new Response(run.stderr).text()]);
		if (code === 0 || !err.includes('FAIL: ') || !err.includes('expect('))
			throw new Error(`Mutation did not produce a regression assertion: ${mutation.name}\n${out}\n${err}`);
		console.log(`KILLED: ${mutation.name}\n${err.split('\n').slice(0, 10).join('\n')}`);
	} finally {
		if (await Bun.file(file).text() !== changed) throw new Error(`Concurrent changes in ${file}; refusing to overwrite them.`);
		await Bun.write(file, original);
	}
}
