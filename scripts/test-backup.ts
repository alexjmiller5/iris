// Backup, export and restore in a real browser against the real hub Worker.
// The hub runs in this process over synthetic SQLite with an in-memory backup
// bucket; D1's export API is answered from that SQLite. Usage:
//   bun run --cwd apps/web dev -- --port 5291 --strictPort
//   LIFE_UI_TEST_URL=http://127.0.0.1:5291/workspace LIFE_UI_TEST_SHOTS=<dir> \
//     bun scripts/test-backup.ts <life-data-checkout>
// It launches its own headless Chrome with a fresh profile (clean OPFS).
import { chromium, expect as base, type Page } from '@playwright/test';
import { Database } from 'bun:sqlite';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { gunzipSync, gzipSync } from 'node:zlib';

const source = process.argv[2];
if (!source) throw new Error('Usage: bun scripts/test-backup.ts <life-data-checkout>');
const url = process.env.LIFE_UI_TEST_URL ?? 'http://127.0.0.1:5291/workspace';
const shots = process.env.LIFE_UI_TEST_SHOTS;
const port = Number(process.env.LIFE_UI_TEST_HUB_PORT ?? 5292);
const cdpPort = Number(process.env.LIFE_UI_TEST_CDP_PORT ?? 9341);
const expect = base.configure({ timeout: 30_000 });
const scratch = mkdtempSync(join(tmpdir(), 'life-ui-backup-'));
const downloads = join(scratch, 'downloads');
mkdirSync(downloads);

// --- the hub: real Worker, synthetic SQLite, in-memory R2 -------------------
const { default: worker } = await import(resolve(source, 'worker/src/index.js'));
const { D1Shim } = await import(resolve(source, 'worker/test/d1shim.js'));
const { ensureAuthReady, hashToken } = await import(resolve(source, 'worker/src/auth.js'));
const { exportReplica } = await import(resolve(source, 'core/src/backup.ts'));
const { initCore } = await import(resolve(source, 'core/src/sync.ts'));
await import(resolve(source, 'worker/test/setup.js')); // crypto.DigestStream outside workerd
const driver = (sqlite: Database) => ({
	all: async (sql: string, params: unknown[] = []) => sqlite.query(sql).all(...(params as never[])) as Record<string, unknown>[],
	run: async (sql: string, params: unknown[] = []) => sqlite.query(sql).run(...(params as never[])).changes,
	async transaction<T>(body: () => Promise<T>) {
		sqlite.exec('BEGIN IMMEDIATE');
		try { const out = await body(); sqlite.exec('COMMIT'); return out; } catch (e) { sqlite.exec('ROLLBACK'); throw e; }
	}
});
async function dump(sqlite: Database) {
	let text = '';
	await exportReplica(driver(sqlite), { write: async (t: string) => void (text += t), close: async () => {} });
	return text;
}
const db = new D1Shim();
const auth = new D1Shim();
await ensureAuthReady(auth);
await auth.prepare('INSERT INTO _tokens(hash,name,scopes,label) VALUES (?,?,?,?)').bind(await hashToken('fixture'), 'Example device', 'full', 'Example device').run();
const system = `id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),deleted_at TEXT,hub_at TEXT`;
db.db.exec('CREATE TABLE _schema_log(id INTEGER PRIMARY KEY,applied_at TEXT NOT NULL,ddl TEXT NOT NULL)');
for (const [name, columns] of Object.entries({
	widgets: 'title TEXT, body TEXT, quantity INTEGER',
	catalog_tables: 'kind TEXT,display TEXT,purpose TEXT',
	catalog_properties: 'tbl TEXT,col TEXT,label TEXT,sort INTEGER,type TEXT,required INTEGER,default_value TEXT,options TEXT,options_sql TEXT,min_items INTEGER,max_items INTEGER,pattern TEXT,ref_table TEXT,derived_by TEXT,inputs TEXT,immutable INTEGER,deprecated INTEGER,description TEXT',
	catalog_rules: 'scope TEXT,tbl TEXT,col TEXT,kind TEXT,text TEXT,sql TEXT,cmd TEXT,enforce INTEGER',
	history: 'tbl TEXT,row_id TEXT,col TEXT,old TEXT,new TEXT,origin TEXT'
})) {
	const ddl = `CREATE TABLE "${name}" (${system},${columns})`;
	db.db.exec(ddl);
	db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z', ddl);
}
db.db.exec(`INSERT INTO catalog_tables(id,kind,display,purpose) VALUES ('widgets','table','title','Synthetic backup workspace');
INSERT INTO catalog_properties(id,tbl,col,label,sort,type,required) VALUES ('widgets.title','widgets','title','Title',0,'text',1),('widgets.body','widgets','body','Body',1,'markdown',0),('widgets.quantity','widgets','quantity','Quantity',2,'int',0);
INSERT INTO widgets(id,title,body,quantity) VALUES ('fixture-record','Fixture record','# From the hub',4);`);
// The seeded hub backup holds one row the hub itself no longer has.
const older = Database.deserialize(db.db.serialize());
older.exec("INSERT INTO widgets(id,title,body,quantity) VALUES ('backup-only','Backup-only widget','Restored from a backup',9)");
const seeded = gzipSync(await dump(older));
const SEEDED_KEY = 'daily/life-2026-10-01T09-10-00.sql.gz';
const sha = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
const objects = new Map<string, { body: Uint8Array; uploaded: Date; customMetadata: Record<string, string> }>();
objects.set(SEEDED_KEY, { body: seeded, uploaded: new Date('2026-10-01T09:12:00.000Z'), customMetadata: {} });
objects.set(`${SEEDED_KEY}.sha256`, { body: new Uint8Array(), uploaded: new Date('2026-10-01T09:12:00.000Z'), customMetadata: { sha256: sha(seeded) } });
const head = (key: string) => {
	const o = objects.get(key);
	return o && { key, size: o.body.length, uploaded: o.uploaded, customMetadata: o.customMetadata };
};
const bucket = {
	head: async (key: string) => head(key),
	get: async (key: string) => { const h = head(key); return h && { ...h, body: new Blob([objects.get(key)!.body]).stream() }; },
	put: async (key: string, body: BodyInit, options: { customMetadata?: Record<string, string> } = {}) =>
		void objects.set(key, { body: new Uint8Array(await new Response(body).arrayBuffer()), uploaded: new Date(), customMetadata: options.customMetadata ?? {} }),
	list: async ({ prefix = '' } = {}) => ({ objects: [...objects.keys()].filter((k) => k.startsWith(prefix)).sort().map((k) => head(k)!), truncated: false }),
	async createMultipartUpload(key: string) {
		const parts: Uint8Array[] = [];
		return {
			uploadPart: async (n: number, data: Uint8Array) => { parts[n - 1] = new Uint8Array(data); return { partNumber: n }; },
			complete: async () => void objects.set(key, { body: new Uint8Array(Buffer.concat(parts)), uploaded: new Date(), customMetadata: {} }),
			abort: async () => {}
		};
	}
};
// D1's export API, answered from the synthetic database.
const realFetch = globalThis.fetch;
globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
	const target = String(input instanceof Request ? input.url : input);
	if (target === 'https://signed.test/life') return new Response(await dump(db.db));
	if (target.startsWith('https://api.cloudflare.com/')) {
		const body = JSON.parse(String(init?.body ?? '{}'));
		return Response.json({ success: true, result: body.current_bookmark ? { status: 'complete', result: { signed_url: 'https://signed.test/life' } } : { status: 'active', at_bookmark: 'bm' } });
	}
	return realFetch(input, init);
}) as typeof fetch;
const origin = new URL(url).origin;
const env = { DB: db, AUTH_DB: auth, HUB_TOKEN: 'operator-fixture', CORS_ORIGINS: origin, BACKUPS: bucket, ACCOUNT_ID: 'acct', BACKUP_API_TOKEN: 'fixture', BACKUP_DATABASES: { life: 'synthetic' }, BACKUP_DATA_DATABASE: 'life' };
const hub = Bun.serve({ hostname: '127.0.0.1', port, fetch: (request) => worker.fetch(request, env, { waitUntil(p: Promise<unknown>) { void p.catch(() => {}); } }) });
const hubUrl = hub.url.href.replace(/\/$/, '');

// --- a disposable headless Chrome -------------------------------------------
const chrome = Bun.spawn(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '--headless=new', `--remote-debugging-port=${cdpPort}`, `--user-data-dir=${join(scratch, 'chrome')}`, '--no-first-run', '--window-size=1280,900', 'about:blank'], { stdout: 'ignore', stderr: 'ignore' });
let browser: Awaited<ReturnType<typeof chromium.connectOverCDP>> | undefined;
for (let i = 0; i < 50 && !browser; i++) browser = await chromium.connectOverCDP(`http://127.0.0.1:${cdpPort}`).catch(async () => (await Bun.sleep(200), undefined));
if (!browser) throw new Error('Chrome did not start');
const page = (browser.contexts()[0] ?? (await browser.newContext())).pages()[0] ?? (await browser.contexts()[0]!.newPage());
const cdp = await browser.newBrowserCDPSession();
await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: downloads });

let failures = 0;
const shot = async (name: string) => { if (shots) await page.screenshot({ path: join(shots, `web-${name}.png`) }); };
async function check(name: string, body: () => Promise<void>) {
	try { await body(); console.log(`ok - ${name}`); }
	catch (error) { failures++; console.log(`not ok - ${name}\n${error}`); await shot(`failed-${name.replace(/\W+/g, '-')}`); }
}
/** Waits for exactly one new finished download and returns its path. */
async function downloaded(action: () => Promise<void>) {
	const before = new Set(readdirSync(downloads));
	await action();
	let file: string | undefined;
	await expect.poll(() => (file = readdirSync(downloads).find((f) => !before.has(f) && !f.endsWith('.crdownload')))).toBeTruthy();
	await Bun.sleep(300);
	return join(downloads, file!);
}
const dialog = () => page.getByRole('dialog', { name: 'Backup' });
const records = () => page.locator('main');
const sqlite3 = (dbPath: string, sql: string) => Bun.spawnSync(['sqlite3', dbPath, sql]).stdout.toString().trim();

try {
	await page.goto(url, { timeout: 180_000 });
	await page.getByRole('button', { name: 'Open my workspace', exact: true }).click();
	await page.getByText('Connect to a hub', { exact: true }).click();
	await page.getByText('Use a device token', { exact: true }).click();
	await page.getByLabel('Hub address').fill(hubUrl);
	await page.getByLabel('Device token').fill('fixture');
	await page.getByRole('button', { name: 'Connect', exact: true }).click();
	await expect(page.getByRole('button', { name: 'Fixture record', exact: true })).toBeVisible();
	await page.getByRole('button', { name: 'Backup', exact: true }).click();
	await expect(dialog().getByRole('heading', { name: 'Hub backups' })).toBeVisible();
	await expect(dialog().getByRole('listitem')).toHaveCount(1).catch(async (e) => {
		console.log(await dialog().innerText());
		throw e;
	});
	await shot('01-backup-dialog');

	await check('download replica saves the whole SQLite file', async () => {
		const file = await downloaded(() => dialog().getByRole('button', { name: 'Download replica' }).click());
		const pages = Number(sqlite3(file, 'PRAGMA page_count')) * Number(sqlite3(file, 'PRAGMA page_size'));
		expect(statSync(file).size).toBe(pages);
		expect(sqlite3(file, 'PRAGMA integrity_check')).toBe('ok');
		expect(sqlite3(file, "SELECT title FROM widgets")).toBe('Fixture record');
		await expect(dialog().getByText(/Downloaded the SQLite database/)).toBeVisible();
	});

	await check('export SQL imports into a fresh CLI data directory', async () => {
		const file = await downloaded(() => dialog().getByRole('button', { name: 'Export SQL dump' }).click());
		expect(readFileSync(file, 'utf8').startsWith('-- life-data-dump: 1\nBEGIN TRANSACTION;')).toBe(true);
		const dir = join(scratch, 'cli');
		mkdirSync(dir);
		const imported = Bun.spawnSync(['sh', '-c', `sqlite3 "${dir}/life.db" < "${file}"`]);
		expect(imported.exitCode).toBe(0);
		const out = Bun.spawnSync(['life', 'sql', 'SELECT id, title FROM widgets ORDER BY id'], { env: { ...process.env, LIFE_DATA_DIR: dir } });
		expect(JSON.parse(out.stdout.toString())).toEqual([{ id: 'fixture-record', title: 'Fixture record' }]);
		await expect(dialog().getByText(/Exported 1 rows from 1 tables|Exported \d+ rows/)).toBeVisible();
		await shot('02-exported');
	});

	await check('hub backups download verified and back up now is rate limited', async () => {
		const file = await downloaded(() => dialog().getByRole('button', { name: `Download: ${SEEDED_KEY}` }).click());
		expect(sha(readFileSync(file))).toBe(sha(seeded));
		expect(gunzipSync(readFileSync(file)).toString()).toContain('Backup-only widget');
		await dialog().getByRole('button', { name: 'Back up now' }).click();
		await expect(dialog().getByText(/The hub saved a backup/)).toBeVisible();
		await expect(dialog().getByRole('listitem')).toHaveCount(2);
		await expect(dialog().getByRole('listitem').first()).toContainText('manual');
		await shot('03-backed-up');
		await dialog().getByRole('button', { name: 'Back up now' }).click();
		await expect(dialog().getByRole('alert')).toContainText('once an hour');
		await shot('04-rate-limited');
	});

	await check('a damaged file is refused before anything changes', async () => {
		const damaged = join(scratch, 'damaged.sql.gz');
		writeFileSync(damaged, seeded.subarray(0, seeded.length - 9));
		await dialog().getByLabel('Choose a backup file').setInputFiles(damaged);
		await expect(dialog().getByRole('alert')).toContainText('could not be read');
		await expect(dialog().getByRole('heading', { name: 'Restore preview' })).toHaveCount(0);
		await shot('05-damaged-file');
	});

	await check('a hub backup restores after preview and typed confirmation; the hub receives what it lacked', async () => {
		await dialog().getByRole('button', { name: `Restore…: ${SEEDED_KEY}` }).click();
		await expect(dialog().getByRole('heading', { name: 'Restore preview' })).toBeVisible();
		const widgets = dialog().getByRole('row').filter({ hasText: 'widgets' });
		await expect(widgets).toContainText('2 (2 live)');
		await expect(widgets).toContainText('1 (1 live)');
		const restore = dialog().getByRole('button', { name: 'Restore', exact: true });
		await expect(restore).toBeDisabled();
		await dialog().getByLabel(/Type replace to confirm/).fill('Replace');
		await expect(restore).toBeDisabled();
		await dialog().getByLabel(/Type replace to confirm/).fill('replace');
		await shot('06-restore-preview');
		await restore.click();
		await expect(dialog().getByText(/Restored \d+ rows/)).toBeVisible({ timeout: 60_000 });
		await expect(dialog().getByRole('heading', { name: 'Recovery copies' })).toBeVisible();
		await shot('07-restored');
		await dialog().getByRole('button', { name: 'Close' }).click();
		await expect(records().getByRole('button', { name: 'Backup-only widget', exact: true })).toBeVisible();
		await shot('08-restored-records');
		await expect.poll(() => db.db.query("SELECT title FROM widgets WHERE id='backup-only'").get(), { timeout: 30_000 }).toEqual({ title: 'Backup-only widget' });
	});

	await check('the sample workspace restores a file and undoes it from its recovery copy', async () => {
		const backup = join(scratch, 'synthetic.sql.gz');
		writeFileSync(backup, seeded);
		await page.getByRole('button', { name: 'Switch workspace', exact: true }).click();
		await page.getByRole('button', { name: 'Try sample workspace', exact: true }).click();
		await expect(page.getByRole('button', { name: 'A place to start', exact: true })).toBeVisible();
		await page.getByRole('button', { name: 'Backup', exact: true }).click();
		await expect(dialog().getByRole('heading', { name: 'Hub backups' })).toHaveCount(0);
		await dialog().getByLabel('Choose a backup file').setInputFiles(backup);
		await expect(dialog().getByRole('heading', { name: 'Restore preview' })).toBeVisible();
		await expect(dialog().getByRole('row').filter({ hasText: 'notes' })).toContainText('Removed');
		await dialog().getByLabel(/Type replace to confirm/).fill('replace');
		await dialog().getByRole('button', { name: 'Restore', exact: true }).click();
		await expect(dialog().getByText(/Restored \d+ rows/)).toBeVisible({ timeout: 60_000 });
		await dialog().getByRole('button', { name: 'Close' }).click();
		await expect(records().getByRole('button', { name: 'Backup-only widget', exact: true })).toBeVisible();
		await page.getByRole('button', { name: 'Backup', exact: true }).click();
		await dialog().getByRole('button', { name: 'Restore…: recovery copy' }).first().click();
		await expect(dialog().getByRole('row').filter({ hasText: 'notes' })).toContainText('Added');
		await dialog().getByLabel(/Type replace to confirm/).fill('replace');
		await dialog().getByRole('button', { name: 'Restore', exact: true }).click();
		await expect(dialog().getByText(/Restored \d+ rows/)).toBeVisible({ timeout: 60_000 });
		await shot('09-sample-undone');
		await dialog().getByRole('button', { name: 'Close' }).click();
		await expect(records().getByRole('button', { name: 'A place to start', exact: true })).toBeVisible();
	});

	await check('the dialog fits a phone-width window', async () => {
		await page.setViewportSize({ width: 390, height: 844 });
		await page.getByRole('button', { name: 'Backup', exact: true }).click().catch(async () => {
			await page.getByRole('button', { name: /sidebar/i }).first().click();
			await page.getByRole('button', { name: 'Backup', exact: true }).click();
		});
		await expect(dialog()).toBeVisible();
		expect(await dialog().evaluate((d) => d.scrollWidth <= d.clientWidth + 1)).toBe(true);
		await shot('10-narrow');
		await dialog().getByRole('button', { name: 'Close' }).click();
	});
} finally {
	await browser.close().catch(() => {});
	chrome.kill();
	hub.stop(true);
	globalThis.fetch = realFetch;
	rmSync(scratch, { recursive: true, force: true });
}
console.log(failures ? `${failures} failed` : 'PASS: replica download, SQL export, hub backups and restore with recovery in a real browser');
process.exit(failures ? 1 : 0);
