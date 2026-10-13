import { chromium, expect as base } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { installCoreSchemas, logDDL, regressionHub } from './workspace-regression-hub';
import { disposableOrigin, recordReady, recordSaved, workspacePage } from './test-origin';

// Timed due values on a synthetic hub: a saved view comparing with relative Now
// re-runs by itself when a floating local time comes due, the record editor's
// optional time beside a mixed date (Remove time returns to date-only), the grid's
// locale display, and an axe audit of the editor in light and dark.
// Open the reserved review page in a disposable Chrome first:
//   IRIS_DEV_NO_HMR=1 bun run dev -- --port 5297
//   IRIS_TEST_CDP=<endpoint> bun scripts/test-due-times.ts <soma-checkout>
// IRIS_TEST_SHOTS=<dir> keeps light and dark screenshots of the editor.
const expect = base.configure({ timeout: 15000 });
const url = process.env.IRIS_TEST_URL ?? 'http://iris-due-times.localhost:5297/workspace?review';
const origin = disposableOrigin(url);
const source = process.argv[2];
if (!source) throw Error('Provide the soma checkout');
const shots = process.env.IRIS_TEST_SHOTS;
const axe = readFileSync(new URL('../node_modules/axe-core/axe.min.js', import.meta.url), 'utf8');

/** This machine's wall clock as a floating local time; the browser shares its zone. */
const local = (date: Date) => {
	const parts = Object.fromEntries(
		new Intl.DateTimeFormat('en-US', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
			.formatToParts(date)
			.map((p) => [p.type, p.value])
	);
	return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`;
};
// The next whole minute at least 40 s away, so the view loads before it comes due.
const dueAt = new Date(Math.ceil((Date.now() + 40000) / 60000) * 60000);
const dueSoon = local(dueAt);
const today = local(new Date()).slice(0, 10);
if (dueSoon.slice(0, 10) !== today) throw Error('Run outside the last minutes before midnight');

const { server, db } = await regressionHub(source, origin);
await installCoreSchemas(db, source, ['saved-views', 'view-defaults']);
logDDL(db, 'ALTER TABLE widgets ADD COLUMN due TEXT');
db.db.exec(`INSERT INTO catalog_properties(id,tbl,col,label,sort,type) VALUES ('widgets.due','widgets','due','Due',5,'date_or_datetime');
	UPDATE widgets SET due='${today}' WHERE id='fixture-record';
	UPDATE widgets SET due='${dueSoon}' WHERE id='second-record';
	UPDATE widgets SET due='2999-01-01T09:00' WHERE id='legacy-record';`);
db.db
	.query('INSERT INTO views(id,name,tbl,definition) VALUES (?,?,?,?)')
	.run('due-now', 'Due now', 'widgets', JSON.stringify({ version: 2, columns: ['title', 'due'], filters: [{ column: 'due', op: 'lte', relative: 'now' }], sort: [{ column: 'due', direction: 'asc' }] }));
const hubDue = (id: string) => (db.db.query('SELECT due FROM widgets WHERE id=?').get(id) as { due: string }).due;

const browser = await chromium.connectOverCDP(process.env.IRIS_TEST_CDP ?? 'http://127.0.0.1:9222');
try {
	const page = workspacePage(browser.contexts().flatMap((c) => c.pages()), url);
	if (!page) throw Error('Open the reserved review page');
	page.setDefaultTimeout(15000);
	await page.bringToFront();
	await page.setViewportSize({ width: 1280, height: 900 });
	await page.goto('about:blank');
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('Storage.clearDataForOrigin', { origin, storageTypes: 'all' });
	await cdp.detach();
	await page.goto(url);
	await page.getByRole('button', { name: 'Open my workspace', exact: true }).click({ timeout: 30000 });
	await page.getByText('Connect to a hub', { exact: true }).click({ timeout: 30000 });
	await page.getByText('Use a device token', { exact: true }).click();
	await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/, ''));
	await page.getByLabel('Device token').fill('fixture');
	await page.getByRole('button', { name: 'Connect', exact: true }).click();
	await page.getByRole('navigation', { name: 'Tables' }).getByRole('button', { name: 'widgets', exact: true }).click({ timeout: 15000 });
	await page.getByRole('combobox', { name: 'View', exact: true }).selectOption('due-now');
	const row = (name: string) => page.getByRole('button', { name, exact: true });
	await expect(row('Fixture record')).toBeVisible();
	await expect(row('Second record')).toHaveCount(0);
	await expect(row('Legacy record')).toHaveCount(0);
	console.log('PASS: a date-only value due today counts all day; a later time waits');
	await page.getByRole('button', { name: 'Due: on or before Now', exact: true }).click();
	await expect(page.getByRole('radio', { name: 'Now', exact: true })).toBeChecked();
	if (shots) await page.screenshot({ path: `${shots}/due-now-filter.png` });
	await page.keyboard.press('Escape');
	// No interaction: the view's own timer re-runs it when the time comes due.
	await expect(row('Second record')).toBeVisible({ timeout: dueAt.getTime() - Date.now() + 20000 });
	expect(Date.now()).toBeGreaterThanOrEqual(dueAt.getTime());
	console.log('PASS: the Now view re-ran by itself when the floating time came due');
	const time = new Intl.DateTimeFormat(undefined, { timeStyle: 'short', timeZone: 'UTC' }).format(new Date(`${dueSoon}:00Z`));
	await expect(page.getByRole('row').filter({ hasText: 'Second record' })).toContainText(time);
	console.log('PASS: the grid shows the floating time in the locale format');

	await row('Second record').click();
	await recordReady(page);
	const date = page.getByLabel('Due', { exact: true });
	const clock = page.getByLabel('Due time', { exact: true });
	await expect(date).toHaveValue(today);
	await expect(clock).toHaveValue(dueSoon.slice(11));
	const audit = async (scheme: string) => {
		await page.emulateMedia({ colorScheme: scheme as 'light' | 'dark' });
		if (!(await page.evaluate(() => 'axe' in window))) await page.addScriptTag({ content: axe });
		const { violations } = await page.evaluate(() =>
			(window as unknown as { axe: { run: (c: unknown, o: unknown) => Promise<any> } }).axe.run(document, { resultTypes: ['violations'] })
		);
		const serious = (violations as { id: string; impact: string }[]).filter((v) => ['serious', 'critical'].includes(v.impact));
		if (serious.length) throw Error(`${scheme}: ${serious.map((v) => v.id).join(', ')}`);
		await clock.scrollIntoViewIfNeeded();
		if (shots) await page.screenshot({ path: `${shots}/due-time-editor-${scheme}.png` });
	};
	await audit('light');
	await audit('dark');
	await page.emulateMedia({ colorScheme: 'light' });
	console.log('PASS: the editor with a time passes axe in light and dark');

	await page.getByRole('button', { name: 'Remove time', exact: true }).click();
	await recordSaved(page);
	await expect(clock).toHaveValue('');
	await expect.poll(() => hubDue('second-record'), { timeout: 20000 }).toBe(today);
	console.log('PASS: Remove time saves a date-only value');
	await clock.fill('15:45');
	await clock.press('Tab');
	await recordSaved(page);
	await expect.poll(() => hubDue('second-record'), { timeout: 20000 }).toBe(`${today}T15:45`);
	await expect(page.getByRole('button', { name: 'Remove time', exact: true })).toBeVisible();
	console.log('PASS: a time beside the date saves a floating local time');
} finally {
	await browser.close().catch(() => {});
	server.stop(true);
}
