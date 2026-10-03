import { chromium, expect } from '@playwright/test';
import { disposableOrigin, workspacePage } from './test-origin';

const url = process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-markdown.localhost:5198/workspace?review';
disposableOrigin(url);
const artifact = Bun.file(new URL('../packages/LifeKit/Sources/LifeKit/Resources/editor.html', import.meta.url));
expect(await artifact.exists(), 'native editor must be bundled').toBe(true);
const html = await artifact.text();
const browser = await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP ?? 'http://127.0.0.1:9222');
try {
	const page = workspacePage(browser.contexts().flatMap(c => c.pages()), url);
	if (!page) throw Error('Open the dedicated editor test page');
	await page.addInitScript(() => {
		const state = window as unknown as { events: unknown[]; webkit: unknown };
		state.events = [];
		state.webkit = { messageHandlers: { editor: { postMessage(message: unknown) { state.events.push(message); } } } };
	});
	await page.route(url, route => route.fulfill({ body: html, contentType: 'text/html' }));
	await page.setViewportSize({width:390,height:844});
	await page.goto(url);
	await expect.poll(() => page.evaluate(() => (window as any).events)).toEqual([{type: 'ready'}]);
	const value = '# Native draft\n\n<mention-page url="https://example.com/kept"/>\n';
	await page.evaluate(value => (window as any).lifeEditor.setDocument({id:'draft-1',value,label:'Body',readOnly:false}), value);
	await expect(page.getByRole('heading', {name:'Native draft'})).toBeVisible();
	await page.getByRole('button', {name:'Body source', exact:true}).click();
	await expect(page.getByRole('textbox', {name:'Body',exact:true})).toHaveValue(value);
	expect(await page.getByRole('textbox', {name:'Body',exact:true}).evaluate(node => parseFloat(getComputedStyle(node).fontSize)), 'Source focus must not trigger iOS input zoom').toBeGreaterThanOrEqual(16);
	await expect.poll(() => page.evaluate(() => (window as any).events)).toEqual([{type:'ready'}]);
	await page.getByRole('textbox', {name:'Body',exact:true}).fill('Edited locally');
	await expect.poll(() => page.evaluate(() => (window as any).events.at(-1))).toEqual({type:'change',id:'draft-1',value:'Edited locally'});
	const snapshot = await page.evaluate(() => (window as any).lifeEditor.getDocument());
	expect(snapshot).toEqual({id:'draft-1',value:'Edited locally',label:'Body',readOnly:false});
	await page.evaluate(() => (window as any).lifeEditor.setDocument({id:'draft-2',value:'Second record',label:'Body',readOnly:true}));
	await page.getByRole('button', {name:'Body source',exact:true}).click();
	await expect(page.getByRole('textbox', {name:'Body',exact:true})).toBeDisabled();
	await expect(page.getByRole('textbox', {name:'Body',exact:true})).toHaveValue('Second record');
	const rejected = await page.evaluate(() => { try { (window as any).lifeEditor.setDocument({id:'bad'}); return false; } catch { return true; } });
	expect(rejected).toBe(true);
	await expect(page.getByRole('textbox', {name:'Body',exact:true})).toHaveValue('Second record');
	await page.evaluate(() => (window as any).lifeEditor.setDocument({id:'draft-3',value:'Final',label:'Body',readOnly:false}));
	await expect(page.getByRole('textbox',{name:'Body',exact:true})).toBeEditable();
	await page.getByRole('textbox',{name:'Body',exact:true}).press('End');
	await page.getByRole('textbox',{name:'Body',exact:true}).pressSequentially('!');
	const finalKeystroke = await page.evaluate(() => (window as any).lifeEditor.getDocument());
	expect(finalKeystroke).toEqual({id:'draft-3',value:'Final!\n',label:'Body',readOnly:false});
	const blocked = await page.evaluate(async () => { try { await fetch('https://example.com/forbidden'); return false; } catch { return true; } });
	expect(blocked).toBe(true);
	console.log('PASS: native editor bundle, exact host source, typed change identity, readonly, malformed input and network isolation');
} finally { await browser.close(); }
