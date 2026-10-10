import { workspacePage } from './test-origin';
import { chromium, expect, type Page } from '@playwright/test';

// Background sync without any sync control: pushes after a write, pulls outside
// rows the moment the hub's wake socket signals them, stays quiet while idle,
// survives offline, keeps drafts, and one tab leads. Needs scripts/test-hub.ts.
const url = process.env.IRIS_TEST_URL ?? 'http://127.0.0.1:5197/workspace';
const hub = process.env.IRIS_TEST_HUB ?? 'http://127.0.0.1:5200';
const shots = process.env.IRIS_TEST_SHOTS;
const auth = { Authorization: 'Bearer fixture', 'Content-Type': 'application/json' };
async function hubRow(id: string) {
	const response = await fetch(`${hub}/v1/rows/pull`, {
		method: 'POST',
		headers: auth,
		body: JSON.stringify({
			table: 'widgets',
			columns: ['id', 'title', 'quantity'],
			since: '',
			limit: 200
		})
	});
	return ((await response.json()) as { rows: Record<string, unknown>[] }).rows.find(
		(row) => row.id === id
	);
}
async function hubInsert(id: string, title: string) {
	const response = await fetch(`${hub}/v1/rows/push`, {
		method: 'POST',
		headers: auth,
		body: JSON.stringify({
			table: 'widgets',
			columns: ['id', 'title', 'quantity', 'updated_at'],
			rows: [{ id, title, quantity: 1, updated_at: new Date().toISOString() }]
		})
	});
	expect(((await response.json()) as { upserted: number }).upserted).toBe(1);
}
async function shot(page: Page, name: string) {
	if (shots) await page.screenshot({ path: `${shots}/${name}.png` });
}
const browser = await chromium.connectOverCDP(process.env.IRIS_TEST_CDP ?? 'http://127.0.0.1:9222');
let offline: (() => Promise<void>) | undefined;
let second: Page | undefined;
try {
	const page = workspacePage(browser.contexts().flatMap((c) => c.pages()), url);
	if (!page) throw new Error(`Open this dedicated test page first: ${url}`);
	page.setDefaultTimeout(10000);
	await page.reload();
	await page.evaluate(() => localStorage.removeItem('iris:sidebar'));
	const connect = async (target: Page) => {
		await target.getByRole('button', { name: 'Open my workspace', exact: true }).click();
		// A cold dev server compiles the database worker on first open.
		await expect(target.getByText('Connect to a hub', { exact: true })).toBeVisible({
			timeout: 30000
		});
		await target.getByText('Connect to a hub', { exact: true }).click();
		await target.getByText('Use a device token', { exact: true }).click();
		await target.getByLabel('Hub address').fill(hub);
		await target.getByLabel('Device token').fill('fixture');
		await target.getByRole('button', { name: 'Connect', exact: true }).click();
		await expect(target.getByRole('heading', { name: 'widgets', exact: true })).toBeVisible({
			timeout: 15000
		});
	};
	await connect(page);
	const pill = page.getByLabel(/^Sync status:/);
	await expect(pill).toHaveAccessibleName('Sync status: Live');
	for (const name of ['Sync now', 'Cancel sync', 'Refresh', 'Refresh usage'])
		await expect(page.getByRole('button', { name, exact: true })).toHaveCount(0);
	await shot(page, '01-synced');

	const grid = page.getByRole('grid', { name: 'Records', exact: true });
	const cell = (column: string, id = 'fixture-record') =>
		grid.locator(`[data-row="${id}"][data-column="${column}"]`);
	const group = (label: string) => page.getByRole('group', { name: `Edit ${label}`, exact: true });
	async function editTitle(id: string, value: string, save = true) {
		await cell('title', id).focus();
		await cell('title', id).press('Enter');
		await group('Title').getByRole('textbox', { name: 'Title', exact: true }).fill(value);
		if (save) await group('Title').getByRole('button', { name: 'Save cell', exact: true }).click();
	}

	// A committed cell reaches the hub within about a second, with no click.
	const pushed = `Pushed ${Date.now()}`;
	await editTitle('fixture-record', pushed);
	const pushStart = Date.now();
	await expect
		.poll(async () => (await hubRow('fixture-record'))?.title, { timeout: 5000, intervals: [100] })
		.toBe(pushed);
	const pushMs = Date.now() - pushStart;
	expect(pushMs).toBeLessThan(2000);
	await expect(grid.getByText('Saving…')).toHaveCount(0);

	// Idle with a live socket: no timer-driven rounds (the fallback is a minute).
	// Our own push comes back as one wake first; let that round finish.
	await expect(pill).toHaveAccessibleName('Sync status: Live');
	await page.waitForTimeout(2000);
	const cursorReads: string[] = [];
	const countCursor = (request: { url(): string }) => {
		if (new URL(request.url()).pathname === '/v1/cursor') cursorReads.push(request.url());
	};
	page.context().on('request', countCursor);
	await page.waitForTimeout(10_000);
	page.context().off('request', countCursor);
	expect(cursorReads).toHaveLength(0);

	// A row written elsewhere appears without interaction, as soon as the hub signals it.
	const outsideId = `outside-${Date.now()}`;
	await hubInsert(outsideId, `Outside ${outsideId}`);
	const pullStart = Date.now();
	await expect(cell('title', outsideId)).toBeVisible({ timeout: 5000 });
	const pullMs = Date.now() - pullStart;
	expect(pullMs).toBeLessThan(1500);
	await shot(page, '02-outside-row');

	// An open cell draft survives a pull that changes the table underneath it.
	await editTitle('fixture-record', 'Unsaved draft text', false);
	await hubInsert(`draft-guard-${Date.now()}`, 'Arrives during a draft');
	await expect(grid.getByText('Arrives during a draft')).toBeVisible({ timeout: 5000 });
	await expect(group('Title').getByRole('textbox', { name: 'Title', exact: true })).toHaveValue(
		'Unsaved draft text'
	);
	await group('Title').getByRole('button', { name: 'Discard', exact: true }).click();

	// Offline: edits stay local and the pill counts them; reconnecting drains them.
	const network = await page.context().newCDPSession(page);
	await network.send('Network.enable');
	const conditions = (on: boolean) =>
		network.send('Network.emulateNetworkConditions', {
			offline: !on,
			latency: 0,
			downloadThroughput: -1,
			uploadThroughput: -1
		});
	offline = async () => {
		await conditions(true).catch(() => {});
		await network.detach().catch(() => {});
	};
	await conditions(false);
	await expect(pill).toHaveAccessibleName('Sync status: Offline');
	const local = `Offline ${Date.now()}`;
	await editTitle(outsideId, local);
	await expect(pill).toHaveAccessibleName('Sync status: Offline · 1 pending');
	await expect(cell('title', outsideId)).toContainText(local);
	await shot(page, '03-offline-pending');
	expect((await hubRow(outsideId))?.title).not.toBe(local);
	await conditions(true);
	await expect(pill).toHaveAccessibleName('Sync status: Live', { timeout: 5000 });
	await expect.poll(async () => (await hubRow(outsideId))?.title, { timeout: 5000 }).toBe(local);
	await offline();
	offline = undefined;
	await shot(page, '04-drained');

	// Two connected tabs: exactly one holds the sync loop, and a hidden tab hands it over.
	const leaders = async (target: Page) =>
		target.evaluate(async () =>
			(await navigator.locks.query()).held!.filter(
				(lock) => lock.name === 'iris:sync-leader:workspace'
			).length
		);
	second = await page.context().newPage();
	await second.goto(url);
	await connect(second);
	await expect.poll(() => leaders(second!)).toBe(1);
	const leaderTab = await second.evaluate(() => document.visibilityState);
	expect(leaderTab).toBe('visible');
	await second.close();
	second = undefined;
	await page.bringToFront();
	await expect.poll(() => leaders(page)).toBe(1);

	// Cmd+\ toggles the sidebar, and the choice survives a reload.
	const sidebar = page.locator('#workspace-sidebar');
	await page.keyboard.press('Meta+Backslash');
	await expect(sidebar).toBeHidden();
	await expect(page.getByRole('button', { name: 'Show sidebar', exact: true })).toBeVisible();
	await shot(page, '05-sidebar-collapsed');
	await page.reload();
	await page.getByRole('button', { name: 'Open my workspace', exact: true }).click();
	await expect(page.getByRole('button', { name: 'Show sidebar', exact: true })).toBeVisible();
	await expect(sidebar).toBeHidden();
	await page.keyboard.press('Meta+Backslash');
	await expect(sidebar).toBeVisible();
	await page.getByRole('button', { name: 'Hide sidebar', exact: true }).click();
	await expect(sidebar).toBeHidden();
	await page.getByRole('button', { name: 'Show sidebar', exact: true }).click();
	await expect(sidebar).toBeVisible();
	await shot(page, '06-sidebar-open');
	console.log(
		`PASS: pushed in ${pushMs} ms, no idle rounds in 10 s, outside row in ${pullMs} ms, offline drained, one leader, sidebar toggles and persists`
	);
} finally {
	await offline?.();
	await second?.close().catch(() => {});
	await browser.close();
}
