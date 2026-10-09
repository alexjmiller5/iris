import { chromium, expect } from '@playwright/test';
import { mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin, workspacePage } from './test-origin';

// Usage: bun scripts/test-reference-create.ts <soma-checkout>
// Open http://iris-reference-create.localhost:5244/workspace?review in the dedicated test page first.
const url = process.env.IRIS_TEST_URL ?? 'http://iris-reference-create.localhost:5244/workspace?review';
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source) throw new Error('Usage: bun scripts/test-reference-create.ts <soma-checkout>');
const shots = process.env.IRIS_TEST_SCREENSHOTS;
if (shots) await mkdir(shots, { recursive: true });
let offline = false;
const { server, db } = await regressionHub(source, origin, 0, {
	wrap: (worker) => ({
		fetch: (request: Request, ...rest: unknown[]) =>
			offline ? new Response('offline', { status: 503 }) : worker.fetch(request, ...rest)
	})
});
const system = 'id TEXT PRIMARY KEY NOT NULL,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT';
for (const ddl of [
	`CREATE TABLE people (${system},name TEXT,role TEXT,email TEXT)`,
	`CREATE TABLE companies (${system},name TEXT,domain TEXT)`,
	`CREATE TABLE rooms (${system},code TEXT)`,
	`CREATE TABLE meetings (${system},title TEXT,host TEXT,attendees TEXT,company TEXT,room TEXT,fixed_host TEXT)`
]) {
	db.db.exec(ddl);
	db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z', ddl);
}
const stamp = '2026-01-01T00:00:00.000Z';
db.db.exec(`
 INSERT INTO catalog_tables(id,kind,display,purpose) VALUES
 ('people','table','name','Synthetic people'),('companies','table','name','Synthetic companies'),
 ('rooms','table','code','Synthetic rooms'),('meetings','table','title','Synthetic meetings');
 INSERT INTO catalog_properties(id,tbl,col,label,sort,type,required,default_value,options,ref_table,derived_by,immutable) VALUES
 ('people.name','people','name','Name',0,'text',1,NULL,NULL,NULL,NULL,0),
 ('people.role','people','role','Role',1,'select',0,'Friend','[{"v":"Friend"},{"v":"Colleague"}]',NULL,NULL,0),
 ('people.email','people','email','Email',2,'email',0,NULL,NULL,NULL,NULL,0),
 ('companies.name','companies','name','Name',0,'text',1,NULL,NULL,NULL,NULL,0),
 ('companies.domain','companies','domain','Domain',1,'text',1,NULL,NULL,NULL,NULL,0),
 ('rooms.code','rooms','code','Code',0,'text',0,NULL,NULL,NULL,'http:room-code',0),
 ('meetings.title','meetings','title','Title',0,'text',1,NULL,NULL,NULL,NULL,0),
 ('meetings.host','meetings','host','Host',1,'ref',0,NULL,NULL,'people',NULL,0),
 ('meetings.attendees','meetings','attendees','Attendees',2,'multi_ref',0,NULL,NULL,'people',NULL,0),
 ('meetings.company','meetings','company','Company',3,'ref',0,NULL,NULL,'companies',NULL,0),
 ('meetings.room','meetings','room','Room',4,'ref',0,NULL,NULL,'rooms',NULL,0),
 ('meetings.fixed_host','meetings','fixed_host','Fixed host',5,'ref',0,NULL,NULL,'people',NULL,1);
 INSERT INTO people(id,name,role,updated_at,hub_at) VALUES
 ('person-ada','Ada Lovelace','Colleague','${stamp}','${stamp}'),('person-grace','Grace Hopper','Friend','${stamp}','${stamp}');
 INSERT INTO rooms(id,code,updated_at,hub_at) VALUES ('room-1','R1','${stamp}','${stamp}');
 INSERT INTO meetings(id,title,host,attendees,fixed_host,updated_at,hub_at) VALUES
 ('meeting-1','Planning sync','person-ada','["person-grace"]','person-ada','${stamp}','${stamp}');
`);

const browser = await chromium.connectOverCDP(process.env.IRIS_TEST_CDP ?? 'http://127.0.0.1:9222');
const failures: string[] = [];
try {
	const page = workspacePage(browser.contexts().flatMap((c) => c.pages()), url);
	if (!page) throw new Error('Open the dedicated reference-create fixture page first.');
	page.setDefaultTimeout(8000);
	page.on('dialog', (dialog) => void dialog.accept().catch(() => {}));
	await page.setViewportSize({ width: 1280, height: 960 });
	// Other agents edit this checkout concurrently; never let dev-server reloads restart the fixture.
	await page.routeWebSocket(/:\/\/[^/]+\/(\?token=|$)/, () => {});
	await page.goto(new URL('/', url).href);
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('Storage.clearDataForOrigin', { origin, storageTypes: 'all' });
	await cdp.detach();
	await page.goto(url);
	await page.waitForLoadState('networkidle', { timeout: 120000 });
	await page.getByRole('button', { name: 'Open my workspace', exact: true }).click();
	await page.getByText('Connect to a hub', { exact: true }).click();
	await page.getByText('Use a device token', { exact: true }).click();
	await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/, ''));
	await page.getByLabel('Device token').fill('fixture');
	await page.getByRole('button', { name: 'Connect', exact: true }).click();
	await expect(page.getByLabel('Sync status: Synced', { exact: true })).toBeVisible({ timeout: 15000 });
	// Local writes push automatically; 'online' wakes a scheduler that backed off while the hub was down.
	const pushed = async (done: () => boolean) => {
		await page.evaluate(() => window.dispatchEvent(new Event('online')));
		try {
			await expect.poll(done, { timeout: 15000 }).toBe(true);
		} catch (error) {
			const pill = await page.locator('.sync-status').first().getAttribute('title').catch(() => null);
			const label = await page.locator('.sync-status').first().innerText().catch(() => '');
			throw new Error(`${error}\nSync pill: ${label} (${pill}); hub people: ${JSON.stringify(db.db.query('SELECT name,deleted_at FROM people').all())}; meeting: ${JSON.stringify(db.db.query('SELECT host,attendees,company FROM meetings').all())}`);
		}
	};
	const editor = page.getByRole('complementary', { name: 'Record editor', exact: true });
	const create = (text: string) => editor.getByRole('button', { name: `Create “${text}”`, exact: true });
	const shot = async (name: string) => {
		if (shots) await page.screenshot({ path: resolve(shots, `web-${name}.png`) });
	};
	async function openMeeting() {
		if (await editor.isVisible())
			await editor.getByRole('button', { name: 'Close record', exact: true }).click();
		await page.getByRole('button', { name: 'meetings', exact: true }).click();
		await page.getByRole('button', { name: 'Planning sync', exact: true }).click();
		await expect(editor.getByRole('textbox', { name: 'Title', exact: true })).toHaveValue('Planning sync');
	}
	async function check(name: string, run: () => Promise<void>) {
		try {
			await openMeeting();
			await run();
			console.log(`PASS: ${name}`);
		} catch (error) {
			failures.push(name);
			console.error(`FAIL: ${name}\n${error}`);
			await shot(`failure-${failures.length}`);
		}
	}
	const peopleNamed = (name: string) =>
		db.db.query('SELECT * FROM people WHERE name=? AND deleted_at IS NULL').all(name) as Record<string, unknown>[];

	await check('creation is offered only without an exact match, then fills the ref offline', async () => {
		const search = editor.getByLabel('Search Host', { exact: true });
		await search.fill('Ada Lovelace');
		await expect(editor.getByRole('option', { name: 'Ada Lovelace' }).first()).toBeAttached();
		await expect(create('Ada Lovelace')).toHaveCount(0);
		offline = true;
		await search.fill('Katherine Johnson');
		await expect(create('Katherine Johnson')).toBeVisible();
		await shot('offer');
		await create('Katherine Johnson').click();
		await expect(
			editor.getByLabel('Host', { exact: true }).locator('option:checked')
		).toHaveText('Katherine Johnson');
		await expect(create('Katherine Johnson')).toHaveCount(0);
		await expect(page.getByRole('button', { name: 'Undo last saved change', exact: true })).toBeEnabled();
		await shot('created-ref');
		await editor.getByRole('button', { name: 'Save record', exact: true }).click();
		await expect(editor.getByText('Edit record / Saved', { exact: true })).toBeVisible();
		expect(peopleNamed('Katherine Johnson')).toEqual([]);
		offline = false;
		const host = () =>
			(db.db.query("SELECT host FROM meetings WHERE id='meeting-1'").get() as { host: string }).host;
		await pushed(() => host() === peopleNamed('Katherine Johnson')[0]?.id);
		expect(peopleNamed('Katherine Johnson')[0]?.role).toBe('Friend');
	});

	await check('multi_ref creation appends the new id after existing selections', async () => {
		await editor.getByLabel('Search Attendees', { exact: true }).fill('Dorothy Vaughan');
		await create('Dorothy Vaughan').click();
		const related = editor.getByRole('group', { name: 'Attendees related records', exact: true });
		await expect(related.getByRole('button', { name: /^Open / })).toHaveText([
			'Grace Hopper',
			'Dorothy Vaughan'
		]);
		await shot('created-multi');
		await editor.getByRole('button', { name: 'Save record', exact: true }).click();
		await expect(editor.getByText('Edit record / Saved', { exact: true })).toBeVisible();
		const attendees = () =>
			(db.db.query("SELECT attendees FROM meetings WHERE id='meeting-1'").get() as { attendees: string })
				.attendees;
		await pushed(() => attendees().includes(String(peopleNamed('Dorothy Vaughan')[0]?.id)));
		expect(JSON.parse(attendees())).toEqual(['person-grace', peopleNamed('Dorothy Vaughan')[0]?.id]);
	});

	await check('required fields open the editor; validation keeps it open; Save fills the ref', async () => {
		await editor.getByLabel('Search Company', { exact: true }).fill('Initech');
		await create('Initech').click();
		const dialog = page.getByRole('dialog', { name: 'New record', exact: true });
		await expect(dialog.getByLabel('Name', { exact: true })).toHaveValue('Initech');
		await expect(dialog.getByLabel('Domain', { exact: true })).toHaveValue('');
		await expect(dialog.getByLabel('Domain', { exact: true })).toBeFocused();
		await shot('handoff');
		await dialog.getByRole('button', { name: 'Save record', exact: true }).click();
		await expect(dialog.getByRole('alert')).toContainText('domain');
		await dialog.getByLabel('Domain', { exact: true }).fill('initech.example');
		await dialog.getByRole('button', { name: 'Save record', exact: true }).click();
		await expect(dialog).toHaveCount(0);
		await expect(editor.getByLabel('Company', { exact: true }).locator('option:checked')).toHaveText(
			'Initech'
		);
		await shot('handoff-saved');
		await editor.getByRole('button', { name: 'Save record', exact: true }).click();
		await expect(editor.getByText('Edit record / Saved', { exact: true })).toBeVisible();
	});

	await check('cancel leaves the source draft and the target table untouched', async () => {
		await editor.getByRole('textbox', { name: 'Title', exact: true }).fill('Unsaved title');
		await editor.getByLabel('Search Company', { exact: true }).fill('Globex');
		await create('Globex').click();
		const dialog = page.getByRole('dialog', { name: 'New record', exact: true });
		await dialog.getByLabel('Domain', { exact: true }).fill('globex.example');
		await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
		await expect(dialog).toHaveCount(0);
		await expect(editor.getByRole('textbox', { name: 'Title', exact: true })).toHaveValue('Unsaved title');
		await expect(editor.getByLabel('Company', { exact: true }).locator('option:checked')).toHaveText(
			'Initech'
		);
		await pushed(() => db.db.query("SELECT 1 FROM companies WHERE name='Initech'").all().length === 1);
		expect(db.db.query("SELECT 1 FROM companies WHERE name='Globex'").all()).toEqual([]);
	});

	await check('Undo removes a record created in place', async () => {
		await editor.getByLabel('Search Host', { exact: true }).fill('Undo Person');
		await create('Undo Person').click();
		await expect(editor.getByLabel('Host', { exact: true }).locator('option:checked')).toHaveText(
			'Undo Person'
		);
		await page.getByRole('button', { name: 'Undo last saved change', exact: true }).click();
		await expect(page.getByRole('status').filter({ hasText: 'Undid the last saved change in people' })).toBeVisible();
		const undone = () =>
			db.db.query("SELECT deleted_at FROM people WHERE name='Undo Person'").all() as { deleted_at: string | null }[];
		await pushed(() => undone().length === 1 && undone()[0].deleted_at !== null);
		expect(peopleNamed('Undo Person')).toEqual([]);
	});

	await check('immutable sources and derived display properties offer no creation', async () => {
		await expect(editor.getByLabel('Search Fixed host', { exact: true })).toBeDisabled();
		await editor.getByLabel('Search Room', { exact: true }).fill('R9');
		await expect(editor.getByRole('button', { name: /^Create “/ })).toHaveCount(0);
	});

	await check('the hand-off editor fits a phone-width viewport', async () => {
		await page.setViewportSize({ width: 390, height: 844 });
		try {
			await editor.getByLabel('Search Company', { exact: true }).fill('Umbrella');
			await create('Umbrella').click();
			const dialog = page.getByRole('dialog', { name: 'New record', exact: true });
			await expect(dialog.getByLabel('Name', { exact: true })).toHaveValue('Umbrella');
			const box = (await dialog.boundingBox())!;
			expect(box.x).toBeGreaterThanOrEqual(0);
			expect(box.x + box.width).toBeLessThanOrEqual(390);
			await shot('handoff-phone');
			await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
		} finally {
			await page.setViewportSize({ width: 1280, height: 960 });
		}
	});
} finally {
	for (const page of browser.contexts().flatMap((c) => c.pages()))
		if (page.url().startsWith(origin)) await page.unrouteAll().catch(() => {});
	await browser.close();
	server.stop(true);
	db.db.close();
}
if (failures.length) {
	console.error(`${failures.length} reference creation checks failed`);
	process.exit(1);
}
