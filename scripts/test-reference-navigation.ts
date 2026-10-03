import { chromium, expect } from '@playwright/test';
import { resolve } from 'node:path';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin } from './test-origin';

const url = process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-relations.localhost:5223/workspace?review';
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source) throw new Error('Usage: bun scripts/test-reference-navigation.ts <life-data-checkout>');
const { server, db } = await regressionHub(source, origin);
const schema = await Bun.file(resolve(import.meta.dir, '../packages/core/schema/saved-views.json')).json();
const system = 'id TEXT PRIMARY KEY NOT NULL,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT';
for (const ddl of [
	`CREATE TABLE projects (${system},headline TEXT,detail TEXT,code TEXT,count INTEGER)`,
	`ALTER TABLE widgets ADD COLUMN parent TEXT`,
	`ALTER TABLE widgets ADD COLUMN related TEXT`,
	`ALTER TABLE widgets ADD COLUMN fixed_parent TEXT`,
	`ALTER TABLE widgets ADD COLUMN absent TEXT`,
	'ALTER TABLE catalog_properties ADD COLUMN source TEXT',
	'ALTER TABLE catalog_properties ADD COLUMN source_ref TEXT',
	...schema.ddl
]) {
	db.db.exec(ddl);
	db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z', ddl);
}
for (const [table, records] of [['catalog_tables', [schema.table]], ['catalog_properties', schema.properties]] as const) {
	for (const record of records) {
		const columns = Object.keys(record);
		db.db.query(`INSERT INTO ${table} (${columns.map(c => '"' + c + '"').join(',')}) VALUES (${columns.map(() => '?').join(',')})`).run(...Object.values(record));
	}
}
db.db.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)').run('project-view', 'Project headlines', 'projects', JSON.stringify({ version: 1, columns: ['headline'] }));
db.db.exec(`
 INSERT INTO catalog_tables(id,kind,display,purpose) VALUES ('projects','table','headline','Synthetic reference targets');
 INSERT INTO catalog_properties(id,tbl,col,label,sort,type,ref_table,immutable) VALUES
 ('projects.headline','projects','headline','Headline',0,'text',NULL,0),
 ('projects.detail','projects','detail','Detail',1,'text',NULL,0),
 ('projects.code','projects','code','Code',2,'text',NULL,0),
 ('projects.count','projects','count','Count',3,'int',NULL,0),
 ('widgets.parent','widgets','parent','Parent',5,'ref','projects',0),
 ('widgets.related','widgets','related','Related',6,'multi_ref','projects',0),
 ('widgets.fixed_parent','widgets','fixed_parent','Fixed parent',7,'ref','projects',1),
 ('widgets.absent','widgets','absent','Absent',8,'ref','projects',0);
 INSERT INTO projects(id,headline,detail,code,count,updated_at,hub_at) VALUES
 ('fixture-record','Target project','Full target detail','hidden-code',73,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z'),
 ('target-two','Second project','Second detail','second-code',19,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z');
 UPDATE widgets SET parent='fixture-record',related='["fixture-record","target-two"]',fixed_parent='target-two',absent='missing-target' WHERE id='fixture-record';
`);

const browser = await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP ?? 'http://127.0.0.1:9222');
const failures: string[] = [];
try {
	const page = browser.contexts().flatMap(c => c.pages()).find(p => p.url() === url);
	if (!page) throw new Error('Open the dedicated relation fixture page first.');
	page.setDefaultTimeout(8000);
	page.on('requestfailed', request => console.error('Fixture request failed:', request.url(), request.failure()?.errorText));
	let acceptDiscard = true;
	let dialogs = 0;
	page.on('dialog', dialog => { dialogs++; return acceptDiscard ? dialog.accept() : dialog.dismiss(); });
	await page.setViewportSize({ width: 1280, height: 960 });
	await page.goto(new URL('/', url).href);
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('Storage.clearDataForOrigin', { origin, storageTypes: 'all' });
	await cdp.detach();
	await page.addInitScript(() => {
		const state = window as any;
		state.relationReads = [];
		state.holdRelation = false;
		state.holdWrites = false;
		state.heldRelations = [];
		state.heldWrites = [];
		state.releaseRelations = (fail = false) => {
			state.holdRelation = false;
			state.heldRelations.splice(0).forEach((deliver: (fail: boolean) => void) => deliver(fail));
		};
		state.releaseWrites = () => {
			state.holdWrites = false;
			state.heldWrites.splice(0).forEach((deliver: () => void) => deliver());
		};
		const Original = window.Worker;
		window.Worker = class extends Original {
			requests = new Map<number, any>();
			postMessage(message: any, ...args: any[]) {
				this.requests.set(message.id, message);
				return super.postMessage(message, ...args as [any]);
			}
			set onmessage(handler: any) {
				super.onmessage = event => {
					const request = this.requests.get(event.data.id);
					this.requests.delete(event.data.id);
					if (request?.method === 'sync') state.syncReply = event.data;
					const view = request?.args?.view;
					const relation = request?.method === 'rows' && view?.table === 'projects' && view.filters?.some((f: any) => f.column === 'id');
					if (relation) state.relationReads.push(view);
					const deliver = (fail = false) => handler.call(this, fail ? { data: { ...event.data, error: { message: 'Held lookup failed' } } } : event);
					if (relation && state.holdRelation) state.heldRelations.push(deliver);
					else if (request?.method === 'write' && state.holdWrites) state.heldWrites.push(deliver);
					else deliver();
				};
			}
		};
	});
	await page.goto(url);
	await page.getByRole('button', { name: 'Open my workspace', exact: true }).click();
	await page.getByText('Connect to a hub', { exact: true }).click();
	await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/, ''));
	await page.getByLabel('Device token').fill('fixture');
	const sync = page.getByRole('button', { name: 'Sync now', exact: true });
	await sync.click();
	await expect(sync).toBeEnabled({ timeout: 15000 });
	expect((await page.evaluate(() => (window as any).syncReply))?.error).toBeUndefined();
	const editor = page.getByRole('complementary', { name: 'Record editor', exact: true });
	const group = (name: string) => editor.getByRole('group', { name: `${name} related records`, exact: true });
	const open = (property = 'Parent', target = 'Target project') => group(property).getByRole('button', { name: `Open ${target}`, exact: true });
	async function sourceRecord() {
		acceptDiscard = true;
		await page.evaluate(() => { (window as any).releaseRelations(); (window as any).releaseWrites(); });
		if (await editor.isVisible()) await editor.getByRole('button', { name: 'Close record', exact: true }).click();
		await page.getByRole('button', { name: 'widgets', exact: true }).click();
		await page.getByRole('button', { name: 'Fixture record', exact: true }).click();
		await expect(editor.getByLabel('Parent', { exact: true }).locator('option[value="fixture-record"]')).toHaveText('Target project');
	}
	async function check(name: string, run: () => Promise<void>) {
		if (process.env.LIFE_UI_REFERENCE_CASE && !name.includes(process.env.LIFE_UI_REFERENCE_CASE)) return;
		try { await sourceRecord(); await run(); console.log(`PASS: ${name}`); }
		catch (error) { failures.push(name); console.error(`FAIL: ${name}\n${error}`); }
		finally { acceptDiscard = true; await page.evaluate(() => { (window as any).releaseRelations(); (window as any).releaseWrites(); }); }
	}
	await check('single reference opens a fresh full row in the target table without a write', async () => {
		await page.evaluate(() => { (window as any).relationReads = []; });
		await open().click();
		await expect(editor.getByLabel('Headline', { exact: true })).toHaveValue('Target project');
		await expect(editor.getByLabel('Count', { exact: true })).toHaveValue('73');
		await expect(editor.getByLabel('Code', { exact: true })).toHaveValue('hidden-code');
		const reads = await page.evaluate(() => (window as any).relationReads);
		expect(reads.some((v: any) => v.filters[0].value === 'fixture-record' && !v.columns)).toBe(true);
		await expect(page.getByText('Pending edits: 0', { exact: true })).toBeVisible();
		expect(db.db.query('SELECT parent,related FROM widgets WHERE id=?').get('fixture-record')).toEqual({ parent: 'fixture-record', related: '["fixture-record","target-two"]' });
	});
	await check('multi reference opening is separate from removing its selection', async () => {
		await open('Related', 'Second project').click();
		await expect(editor.getByLabel('Headline', { exact: true })).toHaveValue('Second project');
		await sourceRecord();
		await expect(group('Related').getByRole('button', { name: 'Remove Second project', exact: true })).toBeVisible();
		await group('Related').getByRole('button', { name: 'Remove Second project', exact: true }).click();
		await expect(open('Related', 'Second project')).toHaveCount(0);
		await expect(editor.getByRole('textbox', { name: 'Title', exact: true })).toHaveValue('Fixture record');
	});
	await check('opening a relation refreshes the destination saved views', async () => {
		await open().click();
		await expect(editor.getByLabel('Headline', { exact: true })).toHaveValue('Target project');
		const views = page.getByRole('combobox', { name: 'View', exact: true });
		await expect(views.locator('option[value="project-view"]')).toHaveText('Project headlines');
		await expect(views).toHaveValue('');
	});
	await check('cancelled discard retains the source draft and restores action focus', async () => {
		await editor.getByRole('textbox', { name: 'Title', exact: true }).fill('Unsaved source title');
		acceptDiscard = false;
		const before = dialogs;
		await open().click();
		await expect.poll(() => dialogs).toBe(before + 1);
		await expect(open()).toBeEnabled();
		await expect(editor.getByRole('textbox', { name: 'Title', exact: true })).toHaveValue('Unsaved source title');
		await expect(open()).toBeFocused();
		await expect(editor.getByLabel('Parent', { exact: true })).toHaveValue('fixture-record');
		acceptDiscard = true;
		await open().click();
		await expect(editor.getByLabel('Headline', { exact: true })).toHaveValue('Target project');
	});
	await check('immutable references remain keyboard navigable', async () => {
		await expect(editor.getByLabel('Fixed parent', { exact: true })).toBeDisabled();
		const action = open('Fixed parent', 'Second project');
		await expect(action).toBeEnabled();
		await action.focus(); await page.keyboard.press('Enter');
		await expect(editor.getByLabel('Headline', { exact: true })).toHaveValue('Second project');
	});
	await check('fresh opening observes a synced target change after picker labels loaded', async () => {
		const revision = new Date().toISOString();
		db.db.query('UPDATE projects SET detail=?,updated_at=?,hub_at=? WHERE id=?').run('Fresh target detail', revision, revision, 'fixture-record');
		await sync.click(); await expect(sync).toBeEnabled();
		await open().click();
		await expect(editor.getByLabel('Detail', { exact: true })).toHaveValue('Fresh target detail');
		await expect(editor.getByRole('heading', { name: 'Target project', exact: true })).toBeFocused();
	});
	await check('read-only source records still allow opening related records', async () => {
		const revision = new Date().toISOString();
		db.db.query('UPDATE catalog_tables SET kind=?,updated_at=?,hub_at=? WHERE id=?').run('system', revision, revision, 'widgets');
		try {
			await sync.click(); await expect(sync).toBeEnabled();
			await expect(editor.getByRole('textbox', { name: 'Title', exact: true })).toBeDisabled();
			await expect(open()).toBeEnabled();
			await open().click();
			await expect(editor.getByLabel('Headline', { exact: true })).toHaveValue('Target project');
		} finally {
			const restored = new Date().toISOString();
			db.db.query('UPDATE catalog_tables SET kind=?,updated_at=?,hub_at=? WHERE id=?').run('table', restored, restored, 'widgets');
			await sync.click(); await expect(sync).toBeEnabled();
		}
	});
	await check('missing targets preserve the editor and explain local unavailability', async () => {
		await editor.getByRole('textbox', { name: 'Title', exact: true }).fill('Keep unavailable draft');
		await open('Absent', 'missing-target').click();
		await expect(page.getByRole('alert')).toContainText('not available locally');
		await expect(editor.getByRole('textbox', { name: 'Title', exact: true })).toHaveValue('Keep unavailable draft');
		await expect(editor.getByLabel('Absent', { exact: true })).toHaveValue('missing-target');
	});
	await check('trashed targets cannot open through stale picker labels', async () => {
		const revision = new Date().toISOString();
		db.db.query('UPDATE projects SET deleted_at=?,updated_at=?,hub_at=? WHERE id=?').run(revision, revision, revision, 'target-two');
		try {
			await sync.click(); await expect(sync).toBeEnabled();
			await open('Related', 'Second project').click();
			await expect(page.getByRole('alert')).toContainText('not available locally');
			await expect(editor.getByRole('textbox', { name: 'Title', exact: true })).toHaveValue('Fixture record');
		} finally {
			const restored = new Date().toISOString();
			db.db.query('UPDATE projects SET deleted_at=NULL,updated_at=?,hub_at=? WHERE id=?').run(restored, restored, 'target-two');
			await sync.click(); await expect(sync).toBeEnabled();
		}
	});
	await check('skipped tables retain navigable local targets and explain absent ones', async () => {
		await page.getByLabel('Automatic sync row limit', { exact: true }).fill('1');
		try {
			await sync.click(); await expect(sync).toBeEnabled();
			await expect(open()).toBeEnabled();
			await open('Absent', 'missing-target').click();
			await expect(page.getByRole('alert')).toContainText('not available locally');
			await expect(editor.getByRole('textbox', { name: 'Title', exact: true })).toHaveValue('Fixture record');
			await open().click();
			await expect(editor.getByLabel('Headline', { exact: true })).toHaveValue('Target project');
		} finally {
			await page.getByLabel('Automatic sync row limit', { exact: true }).fill('50000');
			await sync.click(); await expect(sync).toBeEnabled();
		}
	});
	await check('held old-record replies and errors cannot replace the current editor', async () => {
		for (const fail of [false, true]) {
			await sourceRecord();
			await page.evaluate(() => { (window as any).holdRelation = true; });
			await open().click();
			await page.waitForFunction(() => (window as any).heldRelations.length > 0);
			await editor.getByRole('button', { name: 'Close record', exact: true }).click();
			await page.getByRole('button', { name: 'Second record', exact: true }).click();
			await page.evaluate(fail => (window as any).releaseRelations(fail), fail);
			await expect(editor.getByRole('textbox', { name: 'Title', exact: true })).toHaveValue('Second record');
			await expect(page.getByRole('alert')).toHaveCount(0);
		}
	});
	await check('pending writes lock reference navigation until the receipt arrives', async () => {
		await page.evaluate(() => { (window as any).holdWrites = true; });
		await editor.getByLabel('Absent', { exact: true }).selectOption('');
		await editor.getByRole('textbox', { name: 'Title', exact: true }).fill('Pending title');
		await page.getByRole('button', { name: 'Save record', exact: true }).click();
		await page.waitForFunction(() => (window as any).heldWrites.length > 0);
		await expect(open()).toBeDisabled();
		await page.evaluate(() => (window as any).releaseWrites());
		await expect(open()).toBeEnabled();
		await editor.getByRole('textbox', { name: 'Title', exact: true }).fill('Fixture record');
		await page.getByRole('button', { name: 'Save record', exact: true }).click();
		await expect(page.getByRole('button', { name: 'Save record', exact: true })).toBeEnabled();
	});
	await check('body autosave locks reference navigation until the receipt arrives', async () => {
		// Make the fixture valid for an independent selective run, too.
		await editor.getByLabel('Absent', { exact: true }).selectOption('');
		await page.getByRole('button', { name: 'Save record', exact: true }).click();
		await expect(page.getByRole('button', { name: 'Save record', exact: true })).toBeEnabled();
		await page.evaluate(() => { (window as any).holdWrites = true; });
		await editor.getByRole('button', { name: 'Body source', exact: true }).click();
		await editor.getByRole('textbox', { name: 'Body', exact: true }).fill('Body waiting for its receipt');
		await page.waitForFunction(() => (window as any).heldWrites.length > 0);
		await expect(open()).toBeDisabled();
		await page.evaluate(() => (window as any).releaseWrites());
		await expect(open()).toBeEnabled();
		await open().click();
		await expect(editor.getByLabel('Headline', { exact: true })).toHaveValue('Target project');
	});
	await check('reference controls fit desktop and narrow screens', async () => {
		const longTitle = 'A related project with a deliberately long descriptive title';
		const revision = new Date().toISOString();
		db.db.query('UPDATE projects SET headline=?,updated_at=?,hub_at=? WHERE id=?').run(longTitle, revision, revision, 'target-two');
		await sync.click(); await expect(sync).toBeEnabled();
		await sourceRecord();
		for (const width of [1280, 390]) {
			await page.setViewportSize({ width, height: 960 });
			await open('Related', longTitle).scrollIntoViewIfNeeded();
			const bounds = await group('Related').boundingBox();
			expect(bounds?.x).toBeGreaterThanOrEqual(0);
			expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(width);
			expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
			const remove = group('Related').getByRole('button', { name: `Remove ${longTitle}`, exact: true });
			await expect(remove).toBeVisible();
			const linkBounds = await open('Related', longTitle).boundingBox();
			const removeBounds = await remove.boundingBox();
			expect(removeBounds!.x).toBeGreaterThanOrEqual(linkBounds!.x + linkBounds!.width);
			if (process.env.LIFE_UI_TEST_SCREENSHOTS)
				await page.screenshot({ path: resolve(process.env.LIFE_UI_TEST_SCREENSHOTS, `relations-${width}.png`) });
		}
		await open('Related', longTitle).focus(); await page.keyboard.press('Enter');
		await expect(editor.getByLabel('Headline', { exact: true })).toHaveValue(longTitle);
		await page.setViewportSize({ width: 1280, height: 960 });
	});
	await check('held workspace replies cannot replace a newly opened workspace', async () => {
		await page.evaluate(() => { (window as any).holdRelation = true; });
		await open().click();
		await page.waitForFunction(() => (window as any).heldRelations.length > 0);
		await page.getByRole('button', { name: 'Switch workspace', exact: true }).click();
		await page.getByRole('button', { name: 'Try sample workspace', exact: true }).click();
		await page.getByRole('button', { name: 'A place to start', exact: true }).click();
		await page.evaluate(() => (window as any).releaseRelations());
		await expect(editor.getByRole('textbox', { name: 'Title', exact: true })).toHaveValue('A place to start');
		await expect(page.getByRole('alert')).toHaveCount(0);
	});
	if (failures.length) throw new Error(`${failures.length} relation regression(s) failed: ${failures.join('; ')}`);
} finally {
	const page = browser.contexts().flatMap(c => c.pages()).find(p => p.url() === url);
	await page?.evaluate(() => { (window as any).releaseRelations?.(); (window as any).releaseWrites?.(); }).catch(() => {});
	await browser.close();
	server.stop(true);
	db.db.close();
}
