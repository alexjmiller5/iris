import { chromium, expect } from '@playwright/test';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin, workspacePage } from './test-origin';

const source = process.argv[2];
if (!source) throw new Error('Usage: bun scripts/test-sql-integrity.ts <life-data-checkout>');
const url = process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-sql-integrity.localhost:5198/workspace?review';
const origin = disposableOrigin(url);
const { server, db: hub } = await regressionHub(source, origin);
hub.db.query('UPDATE catalog_properties SET options_sql=? WHERE id=?').run("SELECT 'Fixed'); DELETE FROM widgets; --", 'widgets.tags');
const browser = await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP ?? 'http://127.0.0.1:9222');
try {
	const page = workspacePage(browser.contexts().flatMap(c => c.pages()), url);
	if (!page) throw new Error(`Open this dedicated test page: ${url}`);
	page.setDefaultTimeout(10000);
	const browserErrors: string[] = [];
	page.on('console', message => {
		if (message.type() !== 'error') return;
		// This fixture runs the row/schema Worker. Its optional notification feed
		// is absent; the dedicated services test exercises that separate handler.
		const location = message.location().url;
		const missingFeed = location.startsWith(server.url.origin + '/v1/notifications?')
			&& message.text().includes('404 (Not Found)');
		if (!missingFeed) browserErrors.push(`${location}: ${message.text()}`);
	});
	page.on('dialog', dialog => dialog.accept());
	await page.goto(new URL('/', url).href);
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('Storage.clearDataForOrigin', { origin, storageTypes: 'all' });
	await cdp.detach();
	await page.goto(url);
	await page.getByRole('button', { name: 'Open my workspace', exact: true }).click();
	await page.getByText('Connect to a hub', { exact: true }).click();await page.getByText('Use a device token', {exact:true}).click();
	await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/, ''));
	await page.getByLabel('Device token').fill('fixture');
	await page.getByRole('button',{name:'Connect',exact:true}).click();
	await expect(page.getByRole('button', { name: 'Fixture record', exact: true })).toBeVisible({ timeout: 30000 });
	// Expose the actual adapter only inside the test worker response. No test API
	// or arbitrary SQL operation is added to production dispatch.
	await page.context().route(`${origin}/src/lib/database.worker.ts*`, async route => {
		const response = await route.fetch();
		const original = await response.text();
		const body = original.replace('switch (method) {', `switch (method) {
			case '__test_all': return db.all(args.sql, args.params);
			case '__test_run': return db.run(args.sql, args.params);
			case '__test_calls': return scope.integrityCalls || 0;
			case '__test_function':
				sqlite.create_function(connection, 'integrity_tick', 0, SQLite.SQLITE_UTF8, 0,
					context => sqlite.result(context, scope.integrityCalls = (scope.integrityCalls || 0) + 1));
				return null;`);
		if (body === original) throw new Error('Worker test seam not found.');
		await route.fulfill({ response, body });
	});
	await page.evaluate(async () => {
		const { WorkspaceDatabase } = await import('/src/lib/database.ts');
		(window as any).sqlProbe = new WorkspaceDatabase();
		await (window as any).sqlProbe.request('open', { demo: false });
	});
	await page.context().unroute(`${origin}/src/lib/database.worker.ts*`);
	async function probe(method: string, args: Record<string, unknown> = {}) {
		return page.evaluate(async ({ method, args }) => {
			try { return { ok: true, value: await (window as any).sqlProbe.request(method, args) }; }
			catch (error: any) { return { ok: false, name: error.name, message: error.message, violations: error.violations }; }
		}, { method, args });
	}
	const rows = async () => (await probe('rows', { view: { table: 'widgets' } })).value;
	const original = await rows();
	expect(original).toHaveLength(3);
	// End-user reproduction: opening the editor alone loads options_sql.
	await page.getByRole('button', { name: 'Fixture record', exact: true }).click();
	const options = await probe('options', { table: 'widgets', column: 'tags' });
	const after = await rows();
	console.log(`Catalog options read: ok=${options.ok}, rows before=${original.length}, rows after=${after.length}`);
	expect(after).toEqual(original);
	expect(options.ok).toBe(false);
	await expect(page.getByRole('alert')).toBeVisible();
	console.log('PASS: opening catalog options rejects the escaped DELETE and preserves all rows');

	// Repair only synthetic metadata using the test-only run seam.
	expect((await probe('__test_run', { sql: 'UPDATE catalog_properties SET options_sql=? WHERE id=?', params: ["SELECT 'Dynamic' AS value", 'widgets.tags'] })).ok).toBe(true);
	const snapshot = async () => (await probe('snapshot')).value;
	const beforeWrite = await snapshot();
	expect((await probe('__test_run', { sql: 'UPDATE catalog_properties SET default_value=? WHERE id=?', params: ["sql:'Dynamic') AS value; DELETE FROM widgets; --", 'widgets.status'] })).ok).toBe(true);
	const write = await probe('write', { table: 'widgets', patch: { title: 'Rejected default' } });
	expect(write.ok).toBe(false);
	expect(write.name).toBe('ValidationError');
	expect(await rows()).toEqual(original);
	expect((await snapshot()).status).toEqual(beforeWrite.status);
	expect((await probe('__test_all', { sql: 'SELECT * FROM history' })).value).toEqual([]);
	console.log('PASS: escaped SQL default rolls back with structured validation error, no history or pending edits');

	expect((await probe('__test_run', {sql:'PRAGMA foreign_keys=ON'})).ok).toBe(true);
	for (const sql of [
		"UPDATE widgets SET title='Changed' RETURNING id",
		'SELECT 1; SELECT 2',
		'SELECT 1; DELETE FROM widgets',
		"SELECT 1 --\r'\n; PRAGMA foreign_keys=OFF; --'\n",
		'PRAGMA writable_schema=ON',
		'PRAGMA foreign_keys=ON',
		'PRAGMA foreign_keys=OFF',
		'BEGIN',
		"ATTACH ':memory:' AS extra"
	]) {
		const result = await probe('__test_all', { sql });
		expect(result.ok, sql).toBe(false);
		expect(await rows()).toEqual(original);
	}
	console.log('PASS: all rejects writes, multiple reads, mutating pragmas, transactions and ATTACH');
	expect((await probe('__test_function')).ok).toBe(true);
	expect((await probe('__test_all', { sql: 'SELECT integrity_tick(); SELECT 2' })).ok).toBe(false);
	expect((await probe('__test_calls')).value).toBe(0);
	expect((await probe('__test_all', { sql: 'SELECT integrity_tick() AS calls' })).value).toEqual([{ calls: 1 }]);
	console.log('PASS: extra statements are rejected before even the first SELECT function runs');
	const literal = await probe('__test_all', { sql: "SELECT '; DELETE FROM widgets; --' AS literal, ? AS value; /* ; */ -- ;\n", params: ['bound;value'] });
	expect(literal).toEqual({ ok: true, value: [{ literal: '; DELETE FROM widgets; --', value: 'bound;value' }] });
	expect((await probe('__test_all', { sql: 'PRAGMA main.table_info(widgets)' })).value.map((r: any) => r.name)).toContain('title');
	expect((await probe('__test_all', { sql: 'WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<3) SELECT sum(x) AS total FROM n' })).value).toEqual([{ total: 6 }]);
	console.log('PASS: literals, parameters, comments, introspection and recursive SELECT remain supported');
	// Rule preflight inspects FK effects through SQLite metadata. Permit this
	// read without permitting the connection-changing foreign_keys pragma.
	expect((await probe('__test_all', {sql:'PRAGMA main.foreign_key_list(widgets)'}))).toEqual({ok:true,value:[]});
	expect((await probe('__test_run', {sql:'CREATE TEMP TABLE fk_parent(id TEXT PRIMARY KEY); CREATE TEMP TABLE fk_child(id TEXT REFERENCES fk_parent(id) ON UPDATE CASCADE ON DELETE SET NULL)'})).ok).toBe(true);
	const foreignKeys=await probe('__test_all', {sql:'PRAGMA temp.foreign_key_list(fk_child)'});
	expect(foreignKeys.ok).toBe(true);
	expect(foreignKeys.value).toMatchObject([{table:'fk_parent',from:'id',to:'id',on_update:'CASCADE',on_delete:'SET NULL'}]);
	expect((await probe('__test_run', {sql:"INSERT INTO temp.fk_child VALUES ('absent')"})).ok).toBe(false);
	expect((await probe('__test_all', {sql:'SELECT count(*) AS n FROM temp.fk_child'})).value).toEqual([{n:0}]);
	expect((await probe('__test_run', {sql:'DROP TABLE temp.fk_child; DROP TABLE temp.fk_parent'})).ok).toBe(true);
	console.log('PASS: main and temporary foreign-key metadata can be read without changing enforcement');

	// Trusted DDL batches must stay sequential: the INSERT depends on CREATE.
	expect((await probe('__test_run', { sql: "CREATE TEMP TABLE ddl_probe(value TEXT); INSERT INTO ddl_probe VALUES ('kept;literal');" })).ok).toBe(true);
	expect((await probe('__test_all', { sql: 'SELECT * FROM ddl_probe' })).value).toEqual([{ value: 'kept;literal' }]);
	expect((await probe('__test_run', { sql: 'DROP TABLE ddl_probe' })).ok).toBe(true);
	expect((await probe('__test_run', { sql: 'UPDATE catalog_properties SET default_value=? WHERE id=?', params: ["sql:'Dynamic'", 'widgets.status'] })).ok).toBe(true);
	const saved = await probe('write', { table: 'widgets', patch: { title: 'Valid after rejection', tags: '["Fixed","Dynamic"]' } });
	expect(saved.ok).toBe(true);
	expect(saved.value.status).toBe('Dynamic');
	expect((await probe('write', { table: 'widgets', patch: { id: saved.value.id, body: 'With history' }, expectedUpdatedAt: saved.value.updated_at })).ok).toBe(true);
	expect((await probe('__test_all', { sql: 'SELECT col FROM history WHERE row_id=?', params: [saved.value.id] })).value).toEqual([{ col: 'body' }]);
	// Use a fresh, uninstrumented worker for the transport check. Chromium's
	// worker fetch interception can outlive removal of a Playwright route.
	hub.db.query('UPDATE catalog_properties SET options_sql=? WHERE id=?').run("SELECT 'Dynamic' AS value", 'widgets.tags');
	await page.evaluate(() => (window as any).sqlProbe.close());
	await page.reload();
	await page.getByRole('button', { name: 'Open my workspace', exact: true }).click();
	await page.getByText('Connect to a hub', { exact: true }).click();await page.getByText('Use a device token', {exact:true}).click();
	await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/, ''));
	await page.getByLabel('Device token').fill('fixture');
	await page.getByRole('button',{name:'Connect',exact:true}).click();
	await expect(page.getByText('Pending edits: 0', { exact: true })).toBeVisible({ timeout: 30000 });
	expect(hub.db.query('SELECT body FROM widgets WHERE id=?').get(saved.value.id)).toEqual({ body: 'With history' });
	expect(browserErrors).toEqual([]);
	console.log('PASS: schema replay, trusted DDL, create/edit/history and accepted sync still work');
} finally {
	await browser.close();
	await server.stop(true);
}
