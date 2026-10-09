import { chromium, expect as base } from '@playwright/test';
import { installCoreSchemas, logDDL, regressionHub } from './workspace-regression-hub';
import { disposableOrigin, synced, workspacePage } from './test-origin';

// Write locks, SQL defaults, dynamic options, typed filter chips, column settings,
// workspace switching and durable pending counts on a synthetic hub workspace.
// Open the reserved review page in a disposable Chrome first; this runner clears
// only that origin's storage. IRIS_TEST_CASE runs the cases whose name contains it.
// Shared build hosts can be slow; waits are generous, never fixed sleeps.
const expect = base.configure({ timeout: 15000 });
const url = process.env.IRIS_TEST_URL ?? 'http://iris-write-fixes.localhost:5196/workspace?review';
const source = process.argv[2];
if (!source) throw new Error('Usage: bun scripts/test-workspace-regressions.ts <soma-checkout>');
const origin = disposableOrigin(url);
const { server, db, auth } = await regressionHub(source, origin);
// Saved views give the table a default view, which the filter bar edits.
await installCoreSchemas(db, source, ['saved-views', 'view-defaults']);
logDDL(db, 'ALTER TABLE widgets ADD COLUMN active INTEGER');
db.db.exec(`INSERT INTO catalog_properties(id,tbl,col,label,sort,type) VALUES ('widgets.active','widgets','active','Active',5,'bool');
	UPDATE widgets SET active=1 WHERE id='fixture-record';
	UPDATE widgets SET active=0 WHERE id='second-record';`);
const browser = await chromium.connectOverCDP(process.env.IRIS_TEST_CDP ?? 'http://127.0.0.1:9222');
const failures: string[] = [];
try {
	const page = workspacePage(browser.contexts().flatMap(c => c.pages()), url);
	if (!page) throw new Error(`Open the dedicated test page first: ${url}`);
	page.setDefaultTimeout(15000);
	await page.bringToFront();
	await page.setViewportSize({ width: 1280, height: 960 });
	page.on('dialog', dialog => dialog.accept());
	if (await page.getByRole('button', { name: 'Switch workspace', exact: true }).count()) {
		await page.getByRole('button', { name: 'Switch workspace', exact: true }).click();
		await expect.poll(() => page.workers().length).toBe(0);
	}
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
	// Device tokens live in memory: a reopened workspace syncs again only after Connect.
	async function connect() {
		await page.getByText('Connect to a hub', { exact: true }).click({ timeout: 30000 });
		await page.getByText('Use a device token', { exact: true }).click();
		await page.getByLabel('Hub address').fill(server.url.href.replace(/\/$/, ''));
		await page.getByLabel('Device token').fill('fixture');
		await page.getByRole('button', { name: 'Connect', exact: true }).click();
		await expect(page.getByLabel(/^Sync status:/)).toHaveAccessibleName('Sync status: Synced', { timeout: 30000 });
	}
	await connect();
	await page.getByRole('navigation', { name: 'Tables' }).getByRole('button', { name: 'widgets', exact: true }).click({ timeout: 15000 });
	await expect(page.getByRole('button', { name: 'Fixture record', exact: true })).toBeVisible();
	const save = page.getByRole('button', { name: 'Save record', exact: true });
	const chips = page.getByRole('group', { name: 'Sort and filters', exact: true });
	const editor = page.getByRole('dialog', { name: 'Edit filter', exact: true });
	const shown = (count: number) => page.getByText(`${count} ${count === 1 ? 'record' : 'records'} shown`, { exact: true });
	async function reopen() {
		await page.reload();
		await page.getByRole('button', { name: 'Open my workspace', exact: true }).click({ timeout: 30000 });
		await expect(page.getByRole('heading', { name: 'widgets', exact: true })).toBeVisible();
		await expect(page.getByLabel('View', { exact: true })).not.toHaveValue('');
		const close = page.getByRole('button', { name: 'Close record', exact: true });
		if (await close.count()) await close.click();
	}
	async function check(name: string, body: () => Promise<void>) {
		if (process.env.IRIS_TEST_CASE && !name.includes(process.env.IRIS_TEST_CASE)) return;
		await reopen();
		// Filter edits save into the view; a failed case must not filter the next one.
		const leftover = chips.getByRole('button', { name: /^Remove filter: / });
		while (await leftover.count()) await leftover.first().click();
		try { await body(); console.log(`PASS: ${name}`); }
		catch (error) { failures.push(name); console.error(`FAIL: ${name}\nURL: ${page.url()}\n${error}`); }
		finally { await page.evaluate(() => (window as any).releaseWrites()); }
	}
	async function heldSave() {
		await page.evaluate(() => { (window as any).holdWrites = true; });
		await save.click();
		await page.waitForFunction(() => (window as any).heldWrites.length > 0);
	}
	async function bodySource() {
		if (!await page.locator('textarea[aria-label="Body"]').isVisible()) {
			await page.getByRole('button', { name: 'Body options', exact: true }).click();
			await page.getByRole('menuitem', { name: 'Body source', exact: true }).click();
		}
		return page.getByRole('textbox', { name: 'Body', exact: true });
	}
	/** Filter, search the property list, Enter: the new chip's editor opens. */
	async function addFilter(property: string) {
		const search = page.getByLabel('Filter by property');
		// A sync refresh can land on the opening click; open until the list shows.
		await expect(async () => {
			if (!(await search.isVisible())) await page.getByRole('button', { name: /^Filter(, \d+ active)?$/ }).click();
			await expect(search).toBeVisible({ timeout: 1000 });
		}).toPass({ timeout: 15000 });
		await search.fill(property);
		await page.keyboard.press('Enter');
		await expect(editor).toBeVisible();
	}
	/** The applied view's filters as the hub stores them once the automatic push lands
	 * (the case must have connected after its reopen). */
	async function storedFilters() {
		const id = await page.getByLabel('View', { exact: true }).inputValue();
		const row = db.db.query('SELECT definition FROM views WHERE id=?').get(id) as any;
		return row ? JSON.parse(row.definition).filters ?? [] : null;
	}
	await check('column settings hide, reorder and resize without dropping hidden edit values', async () => {
		const headers = page.locator('[role="columnheader"]:not(.selection)');
		await expect(headers).toHaveText(['Record', 'Quantity', 'Status', 'Tags', 'Active']);
		await page.getByText('Columns', { exact: true }).click();
		await page.getByRole('checkbox', { name: 'Show Body', exact: true }).check();
		await page.getByRole('checkbox', { name: 'Show Quantity', exact: true }).uncheck();
		for (let i = 0; i < 3; i++) await page.getByRole('button', { name: 'Move Body left', exact: true }).click();
		await expect(headers).toHaveText(['Record', 'Body', 'Status', 'Tags', 'Active']);
		const bodyHeader = page.locator('[role="columnheader"]', { hasText: 'Body' });
		const before = (await bodyHeader.boundingBox())!.width;
		await page.getByRole('spinbutton', { name: 'Width Body', exact: true }).fill('500');
		await page.getByRole('spinbutton', { name: 'Width Body', exact: true }).press('Tab');
		await expect.poll(async () => (await bodyHeader.boundingBox())!.width).toBeGreaterThan(before);
		await page.getByText('Columns', { exact: true }).click();
		await page.getByRole('button', { name: 'Fixture record', exact: true }).click();
		await expect(page.getByLabel('Quantity', { exact: true })).toHaveValue('42');
		await page.getByRole('button', { name: 'Close record', exact: true }).click();
	});
	await check('combined filters intersect records and removable chips keep the remaining clauses', async () => {
		await addFilter('Title');
		await editor.getByLabel('Value', { exact: true }).fill('Fixture record');
		await page.keyboard.press('Escape');
		await expect(shown(1)).toBeVisible();
		await expect(page.getByRole('button', { name: 'Fixture record', exact: true })).toBeVisible();
		await addFilter('Body');
		await expect(editor.getByLabel('Condition', { exact: true })).toHaveValue('contains');
		await editor.getByLabel('Value', { exact: true }).fill('Second');
		await page.keyboard.press('Escape');
		await expect(shown(0)).toBeVisible();
		await expect(page.getByRole('button', { name: 'Second record', exact: true })).not.toBeVisible();
		await expect(page.getByRole('button', { name: 'Fixture record', exact: true })).not.toBeVisible();
		await chips.getByRole('button', { name: 'Remove filter: Body: Second', exact: true }).click();
		await expect(shown(1)).toBeVisible();
		await expect(page.getByRole('button', { name: 'Fixture record', exact: true })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Second record', exact: true })).not.toBeVisible();
		await chips.getByRole('button', { name: 'Remove filter: Title: Fixture record', exact: true }).click();
		await expect(page.getByRole('button', { name: 'Second record', exact: true })).toBeVisible();
		await expect(page.getByRole('button', { name: /^Remove filter/ })).toHaveCount(0);
	});
	await check('boolean filters match checked and unchecked records', async () => {
		await connect();
		await addFilter('Active');
		await expect(editor.getByRole('radio', { name: 'Checked', exact: true })).toBeChecked();
		await expect(chips.getByRole('button', { name: 'Active: checked', exact: true })).toBeVisible();
		await expect(shown(1)).toBeVisible();
		await expect(page.getByRole('button', { name: 'Fixture record', exact: true })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Second record', exact: true })).not.toBeVisible();
		await editor.getByText('Unchecked', { exact: true }).click();
		await expect(editor.getByRole('radio', { name: 'Unchecked', exact: true })).toBeChecked();
		await expect(chips.getByRole('button', { name: 'Active: unchecked', exact: true })).toBeVisible();
		await expect(shown(1)).toBeVisible();
		await expect(page.getByRole('button', { name: 'Second record', exact: true })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Fixture record', exact: true })).not.toBeVisible();
		await page.keyboard.press('Escape');
		await expect.poll(storedFilters, { timeout: 20000 }).toEqual([{ column: 'active', op: 'eq', value: false }]);
		await chips.getByRole('button', { name: 'Remove filter: Active: unchecked', exact: true }).click();
		await expect(shown(3)).toBeVisible();
	});
	await check('empty numeric input never becomes a zero filter', async () => {
		await connect();
		await addFilter('Quantity');
		await expect.poll(storedFilters, { timeout: 20000 }).toEqual([]);
		const value = editor.getByLabel('Value', { exact: true });
		await value.fill('0');
		await expect(shown(0)).toBeVisible();
		await value.fill('');
		await expect(shown(3)).toBeVisible();
		await page.keyboard.press('Escape');
		await expect(editor).toBeHidden();
		await expect(page.getByRole('button', { name: /^Remove filter/ })).toHaveCount(0);
		await expect(shown(3)).toBeVisible();
		// Two later sync rounds cover the autosave delay and its push.
		await synced(page);
		await synced(page);
		expect(await storedFilters()).toEqual([]);
	});
	await check('write in flight locks editable fields', async () => {
		await page.getByRole('button', { name: 'Fixture record', exact: true }).click();
		await (await bodySource()).fill('Saved body');
		await heldSave();
		await expect(await bodySource()).toBeDisabled();
		await expect(page.getByLabel('Tags', { exact: true })).toBeDisabled();
		await page.evaluate(() => (window as any).releaseWrites());
		await expect(save).toBeEnabled();
		await reopen();
		await page.getByRole('button', { name: 'Fixture record', exact: true }).click();
		await expect(await bodySource()).toHaveValue('Saved body');
	});
	await check('write in flight locks record table workspace and route navigation', async () => {
		await page.getByRole('button', { name: 'Fixture record', exact: true }).click();
		await (await bodySource()).fill('Still record one');
		await heldSave();
		for (const name of ['Second record', 'Close record', 'Switch workspace', 'Table graph'])
			await expect(page.getByRole('button', { name, exact: true })).toBeDisabled();
		await expect(page.getByRole('navigation', { name: 'Tables', exact: true }).getByRole('button', { name: 'widgets', exact: true })).toBeDisabled();
		const currentURL = page.url();
		await page.locator('a.wordmark').evaluate((el: HTMLAnchorElement) => el.click());
		await expect(page).toHaveURL(currentURL);
		await page.evaluate(() => (window as any).releaseWrites());
		await expect(save).toBeEnabled();
		await page.getByRole('button', { name: 'Close record', exact: true }).click();
		await page.getByRole('button', { name: 'Second record', exact: true }).click();
		await expect(await bodySource()).toHaveValue('Second body');
	});
	await check('canonical SQL and physical defaults survive another edit', async () => {
		await page.getByRole('button', { name: 'New record', exact: true }).click();
		await page.getByRole('textbox', { name: 'Title', exact: true }).fill('Default proof');
		await save.click();
		await expect(save).toBeEnabled();
		await expect(page.getByLabel('Quantity', { exact: true })).toHaveValue('42');
		await expect(page.getByLabel('Status', { exact: true })).toHaveValue('Dynamic');
		await (await bodySource()).fill('Unrelated change');
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
		await page.getByRole('complementary', { name: 'Record editor' }).getByRole('button', { name: 'Move to trash', exact: true }).click();
		await page.waitForFunction(() => (window as any).heldWrites.length > 0);
		await expect(page.getByRole('button', { name: 'Fixture record', exact: true })).toBeDisabled();
		await expect(page.getByRole('button', { name: 'Close record', exact: true })).toBeDisabled();
		await page.evaluate(() => (window as any).releaseWrites());
		await expect(page.getByRole('complementary', { name: 'Record editor' })).toHaveCount(0);
		await page.getByRole('button', { name: 'Trash', exact: true }).click();
		await page.getByRole('button', { name: 'Second record', exact: true }).click();
		await page.getByRole('complementary', { name: 'Record editor' }).getByRole('button', { name: 'Restore record', exact: true }).click();
		await expect(page.getByRole('complementary', { name: 'Record editor' })).toHaveCount(0);
	});
	await check('pending count survives reload and clears after accepted sync', async () => {
		const pending = page.locator('[data-pending]');
		await expect(pending).toBeVisible();
		const before = Number(await pending.getAttribute('data-pending'));
		await page.getByRole('button', { name: 'New record', exact: true }).click();
		await page.getByRole('textbox', { name: 'Title', exact: true }).fill('Pending proof');
		await save.click();
		await expect(save).toBeEnabled();
		await expect(page.locator(`[data-pending="${before + 1}"]`)).toBeVisible();
		await reopen();
		await expect(page.locator(`[data-pending="${before + 1}"]`)).toBeVisible();
		await connect();
		await expect(page.locator('[data-pending="0"]')).toBeVisible();
	});
	// Last: its sort and filter stay saved in the widgets view.
	await check('workspace switch resets sort filters search and trash', async () => {
		await page.getByRole('button', { name: /^Sort/ }).click();
		await page.getByRole('dialog', { name: 'Sort' }).getByLabel('Add sort').selectOption('quantity');
		await page.keyboard.press('Escape');
		await addFilter('Quantity');
		await editor.getByLabel('Value', { exact: true }).fill('42');
		await page.keyboard.press('Escape');
		await expect(chips.getByRole('button', { name: 'Quantity: = 42', exact: true })).toBeVisible();
		await page.getByLabel('Search records').fill('Fixture');
		await expect(shown(1)).toBeVisible();
		await page.getByRole('button', { name: 'Trash', exact: true }).click();
		await expect(page.getByRole('button', { name: 'All records', exact: true })).toBeVisible();
		await page.getByRole('button', { name: 'Switch workspace', exact: true }).click();
		await page.getByRole('button', { name: 'Try sample workspace', exact: true }).click();
		await expect(page.getByRole('heading', { name: 'notes', exact: true })).toBeVisible();
		await expect(page.getByRole('button', { name: 'A place to start', exact: true })).toBeVisible();
		await expect(page.getByLabel('Search records')).toHaveValue('');
		await expect(page.getByRole('button', { name: 'Trash', exact: true })).toBeVisible();
		await expect(chips.getByRole('button')).toHaveCount(0);
		await expect(page.getByRole('button', { name: 'Filter', exact: true })).toBeVisible();
		await expect(page.getByRole('button', { name: 'Sort', exact: true })).toBeVisible();
	});
	if (failures.length) throw new Error(`${failures.length} regression(s) failed: ${failures.join('; ')}`);
} finally {
	await browser.close();
	server.stop(true);
	db.db.close();
	auth.db.close();
}
