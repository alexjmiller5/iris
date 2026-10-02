import { chromium, expect } from '@playwright/test';
import { regressionHub } from './workspace-regression-hub';
import { disposableOrigin } from './test-origin';

// Create a dedicated chrome-control group first. This origin must be disposable:
// the runner clears only its own OPFS/localStorage before exercising the real app.
const url = process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-write-fixes.localhost:5196/workspace?review';
const source = process.argv[2];
if (!source) throw new Error('Usage: bun scripts/test-workspace-regressions.ts <life-data-checkout>');
const origin = disposableOrigin(url);
const { server } = await regressionHub(source, origin);
const browser = await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP ?? 'http://127.0.0.1:9222');
const failures: string[] = [];
try {
	const page = browser.contexts().flatMap(c => c.pages()).find(p => p.url() === url);
	if (!page) throw new Error(`Open the dedicated test page first: ${url}`);
	page.setDefaultTimeout(5000);
	await page.setViewportSize({ width: 1280, height: 960 });
	page.on('dialog', dialog => dialog.accept());
	await page.goto(new URL('/', url).href);
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('Storage.clearDataForOrigin', { origin, storageTypes: 'all' });
	await cdp.detach();
	await page.addInitScript(() => {
		const state = window as any;
		state.holdWrites = false;
		state.heldWrites = [];
		state.releaseWrites = () => { state.holdWrites = false; state.heldWrites.splice(0).forEach((deliver: () => void) => deliver()); };
		const Original = window.Worker;
		window.Worker = class extends Original {
			writes = new Set<number>();
			postMessage(message: any, ...args: any[]) {
				if (message.method === 'write') this.writes.add(message.id);
				return super.postMessage(message, ...args as [any]);
			}
			set onmessage(handler: any) {
				super.onmessage = event => {
					const write = this.writes.delete(event.data.id);
					const deliver = () => handler.call(this, event);
					if (write && state.holdWrites) state.heldWrites.push(deliver);
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
	await page.getByRole('button', { name: 'Sync now', exact: true }).click();
	await expect(page.getByRole('button', { name: 'Fixture record', exact: true })).toBeVisible({ timeout: 15000 });
	const save = page.getByRole('button', { name: 'Save record', exact: true });
	async function reopen() {
		await page.reload();
		await page.getByRole('button', { name: 'Open my workspace', exact: true }).click();
		await expect(page.getByRole('heading', { name: 'widgets', exact: true })).toBeVisible();
	}
	async function check(name: string, body: () => Promise<void>) {
		if (process.env.LIFE_UI_TEST_CASE && !name.includes(process.env.LIFE_UI_TEST_CASE)) return;
		await reopen();
		try { await body(); console.log(`PASS: ${name}`); }
		catch (error) { failures.push(name); console.error(`FAIL: ${name}\nURL: ${page.url()}\n${error}`); }
		finally { await page.evaluate(() => (window as any).releaseWrites()); }
	}
	async function heldSave() {
		await page.evaluate(() => { (window as any).holdWrites = true; });
		await save.click();
		await page.waitForFunction(() => (window as any).heldWrites.length > 0);
	}
	await check('write in flight locks editable fields', async () => {
		await page.getByRole('button', { name: 'Fixture record', exact: true }).click();
		if (await page.getByRole('button', { name: 'Body source', exact: true }).getAttribute('aria-pressed') !== 'true') await page.getByRole('button', { name: 'Body source', exact: true }).click();
		await page.getByRole('textbox', { name: 'Body', exact: true }).fill('Saved body');
		await heldSave();
		if (await page.getByRole('button', { name: 'Body source', exact: true }).getAttribute('aria-pressed') !== 'true') await page.getByRole('button', { name: 'Body source', exact: true }).click();
		await expect(page.getByRole('textbox', { name: 'Body', exact: true })).toBeDisabled();
		await expect(page.getByLabel('Tags', { exact: true })).toBeDisabled();
		await page.evaluate(() => (window as any).releaseWrites());
		await expect(save).toBeEnabled();
		await reopen();
		await page.getByRole('button', { name: 'Fixture record', exact: true }).click();
		if (await page.getByRole('button', { name: 'Body source', exact: true }).getAttribute('aria-pressed') !== 'true') await page.getByRole('button', { name: 'Body source', exact: true }).click();
		await expect(page.getByRole('textbox', { name: 'Body', exact: true })).toHaveValue('Saved body');
	});
	await check('write in flight locks record table workspace and route navigation', async () => {
		await page.getByRole('button', { name: 'Fixture record', exact: true }).click();
		if (await page.getByRole('button', { name: 'Body source', exact: true }).getAttribute('aria-pressed') !== 'true') await page.getByRole('button', { name: 'Body source', exact: true }).click();
		await page.getByRole('textbox', { name: 'Body', exact: true }).fill('Still record one');
		await heldSave();
		for (const name of ['Second record', 'Close record', 'Switch workspace', 'Table graph'])
			await expect(page.getByRole('button', { name, exact: true })).toBeDisabled();
		await expect(page.getByRole('navigation', { name: 'Tables' }).getByRole('button')).toBeDisabled();
		await page.locator('a.wordmark').evaluate((el: HTMLAnchorElement) => el.click());
		await expect(page).toHaveURL(url);
		await page.evaluate(() => (window as any).releaseWrites());
		await expect(save).toBeEnabled();
		await page.getByRole('button', { name: 'Close record', exact: true }).click();
		await page.getByRole('button', { name: 'Second record', exact: true }).click();
		if (await page.getByRole('button', { name: 'Body source', exact: true }).getAttribute('aria-pressed') !== 'true') await page.getByRole('button', { name: 'Body source', exact: true }).click();
		await expect(page.getByRole('textbox', { name: 'Body', exact: true })).toHaveValue('Second body');
	});
	await check('canonical SQL and physical defaults survive another edit', async () => {
		await page.getByRole('button', { name: 'New record', exact: true }).click();
		await page.getByRole('textbox', { name: 'Title', exact: true }).fill('Default proof');
		await save.click();
		await expect(save).toBeEnabled();
		await expect(page.getByLabel('Quantity', { exact: true })).toHaveValue('42');
		await expect(page.getByLabel('Status', { exact: true })).toHaveValue('Dynamic');
		if (await page.getByRole('button', { name: 'Body source', exact: true }).getAttribute('aria-pressed') !== 'true') await page.getByRole('button', { name: 'Body source', exact: true }).click();
		await page.getByRole('textbox', { name: 'Body', exact: true }).fill('Unrelated change');
		await save.click();
		await expect(save).toBeEnabled();
		await reopen();
		await page.getByRole('button', { name: 'Default proof', exact: true }).click();
		await expect(page.getByLabel('Quantity', { exact: true })).toHaveValue('42');
		await expect(page.getByLabel('Status', { exact: true })).toHaveValue('Dynamic');
	});
	await check('dynamic options load and unknown selections remain visible', async () => {
		await page.getByRole('button', { name: 'Legacy record', exact: true }).click();
		const tags = page.getByLabel('Tags', { exact: true });
		await expect(tags.locator('option')).toHaveCount(3);
		await expect(tags.locator('option:checked')).toHaveText(['Dynamic', 'Legacy']);
		// Native ctrl/cmd selection retains the existing selections.
		await tags.evaluate((el: HTMLSelectElement) => { const option = [...el.options].find(o => o.value === 'Fixed')!; option.selected = true; el.dispatchEvent(new Event('change', { bubbles: true })); });
		await expect(tags.locator('option:checked')).toHaveText(['Fixed', 'Dynamic', 'Legacy']);
		await save.click();
		await expect(page.getByRole('alert')).toContainText('Legacy');
		await expect(tags.locator('option:checked')).toHaveText(['Fixed', 'Dynamic', 'Legacy']);
		await tags.selectOption(['Fixed', 'Dynamic']);
		await save.click();
		await expect(save).toBeEnabled();
		await expect(page.getByRole('alert')).toHaveCount(0);
		await reopen();
		await page.getByRole('button', { name: 'Legacy record', exact: true }).click();
		await expect(tags.locator('option:checked')).toHaveText(['Fixed', 'Dynamic']);
	});
	await check('dynamic options are available before a new record has values', async () => {
		await page.getByRole('button', { name: 'New record', exact: true }).click();
		await expect(page.getByLabel('Status', { exact: true }).locator('option[value="Dynamic"]')).toHaveCount(1);
		await expect(page.getByLabel('Tags', { exact: true }).locator('option')).toHaveText(['Fixed', 'Dynamic']);
		await page.getByRole('textbox', { name: 'Title', exact: true }).fill('Dynamic proof');
		await page.getByLabel('Status', { exact: true }).selectOption('Dynamic');
		await page.getByLabel('Tags', { exact: true }).selectOption(['Fixed', 'Dynamic']);
		await save.click();
		await expect(save).toBeEnabled();
		await expect(page.getByRole('alert')).toHaveCount(0);
		await reopen();
		await page.getByRole('button', { name: 'Dynamic proof', exact: true }).click();
		await expect(page.getByLabel('Tags', { exact: true }).locator('option:checked')).toHaveText(['Fixed', 'Dynamic']);
	});
	await check('trash reply locks navigation until the original editor closes', async () => {
		await page.getByRole('button', { name: 'Second record', exact: true }).click();
		await page.evaluate(() => { (window as any).holdWrites = true; });
		await page.getByRole('button', { name: 'Move to trash', exact: true }).click();
		await page.waitForFunction(() => (window as any).heldWrites.length > 0);
		await expect(page.getByRole('button', { name: 'Fixture record', exact: true })).toBeDisabled();
		await expect(page.getByRole('button', { name: 'Close record', exact: true })).toBeDisabled();
		await page.evaluate(() => (window as any).releaseWrites());
		await expect(page.getByRole('complementary', { name: 'Record editor' })).toHaveCount(0);
		await page.getByRole('button', { name: 'Trash', exact: true }).click();
		await page.getByRole('button', { name: 'Second record', exact: true }).click();
		await page.getByRole('button', { name: 'Restore record', exact: true }).click();
		await expect(page.getByRole('complementary', { name: 'Record editor' })).toHaveCount(0);
	});
	await check('workspace switch resets sort filters search and trash', async () => {
		await page.getByLabel('Sort by').selectOption('quantity');
		await page.getByRole('button', { name: 'Ascending', exact: true }).click();
		await page.getByLabel('Filter property').selectOption('quantity');
		await page.getByLabel('Filter value').fill('42');
		await page.getByRole('button', { name: 'Apply filter', exact: true }).click();
		await page.getByLabel('Search records').fill('Fixture');
		await page.getByRole('button', { name: 'Trash', exact: true }).click();
		await page.getByRole('button', { name: 'Switch workspace', exact: true }).click();
		await page.getByRole('button', { name: 'Try sample workspace', exact: true }).click();
		await expect(page.getByRole('heading', { name: 'notes', exact: true })).toBeVisible();
		await expect(page.getByRole('button', { name: 'A place to start', exact: true })).toBeVisible();
		await expect(page.getByLabel('Search records')).toHaveValue('');
		await expect(page.getByLabel('Sort by')).toHaveValue('id');
		await expect(page.getByLabel('Filter property')).toHaveValue('');
		await expect(page.getByRole('button', { name: 'Ascending', exact: true })).toBeVisible();
	});
	await check('pending count survives reload and clears after accepted sync', async () => {
		const pending = page.getByText(/^Pending edits: \d+$/);
		await expect(pending).toBeVisible();
		const before = Number((await pending.innerText()).split(':')[1]);
		await page.getByRole('button', { name: 'New record', exact: true }).click();
		await page.getByRole('textbox', { name: 'Title', exact: true }).fill('Pending proof');
		await save.click();
		await expect(save).toBeEnabled();
		await expect(pending).toHaveText(`Pending edits: ${before + 1}`);
		await reopen();
		await expect(pending).toHaveText(`Pending edits: ${before + 1}`);
		await page.getByText('Connect to a hub', { exact: true }).click();
		await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/, ''));
		await page.getByLabel('Device token').fill('fixture');
		await page.getByRole('button', { name: 'Sync now', exact: true }).click();
		await expect(pending).toHaveText('Pending edits: 0');
	});
	if (failures.length) throw new Error(`${failures.length} regression(s) failed: ${failures.join('; ')}`);
} finally {
	await browser.close();
	await server.stop(true);
}
