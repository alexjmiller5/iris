import { expect, test } from 'bun:test';
import { resolve } from 'node:path';
import { disposableOrigin, workspacePage } from './test-origin';

test('rejection fixture resets require exactly the reserved origin and review path', () => {
 expect(disposableOrigin('http://iris-rejections.localhost:5238/workspace?review')).toBe('http://iris-rejections.localhost:5238');
 for (const url of ['http://iris-rejections.localhost:5239/workspace?review', 'http://iris-rejections.localhost:5238/workspace', 'https://iris-rejections.localhost:5238/workspace?review', 'http://iris-rejections.localhost.evil.test:5238/workspace?review']) expect(() => disposableOrigin(url)).toThrow('Refusing reset');
});

const fixtureAddress = 'http://iris-navigation.localhost:5224/workspace?review';
const tab = (url: string) => ({ url: () => url });
test('palette fixture reset is bounded to its reserved host and review path', () => {
	expect(disposableOrigin('http://iris-palette.localhost:5226/workspace?review')).toBe('http://iris-palette.localhost:5226');
	for (const address of ['http://iris-palette.localhost.example.test:5226/workspace?review', 'http://iris-palette.localhost:5226/workspace', 'http://iris-palette.localhost:5226/other?review']) {
		expect(() => disposableOrigin(address)).toThrow('Refusing reset');
	}
});
test('fixture selection survives product query changes without matching other origins or paths', () => {
	const intended = tab('http://iris-navigation.localhost:5224/workspace?table=odd+table&view=view%2F&row=row%26');
	const unrelated = [
		tab('http://iris-navigation.localhost:5224/workspace-other?review'),
		tab('http://iris-navigation.localhost.example.test:5224/workspace?review'),
		tab('http://iris-navigation.localhost:5225/workspace?review'),
		tab('https://iris-navigation.localhost:5224/workspace?review'),
		tab('http://fixture@iris-navigation.localhost:5224/workspace?review'),
		tab('about:blank')
	];
	expect(workspacePage([...unrelated, intended], fixtureAddress)).toBe(intended);
	expect(workspacePage(unrelated, fixtureAddress)).toBeUndefined();
});
test('fixture selection distinguishes observer tabs and refuses ambiguous identities', () => {
	const primary = tab(fixtureAddress.replace('?review', '?table=widgets'));
	const observer = tab(fixtureAddress + '&observer=1');
	expect(workspacePage([observer, primary], fixtureAddress)).toBe(primary);
	expect(workspacePage([primary, observer], fixtureAddress + '&observer=1')).toBe(observer);
	expect(() => workspacePage([primary, tab(primary.url() + '&row=one')], fixtureAddress)).toThrow('Ambiguous');
});

test('navigation fixture permits only its exact reserved host and review path', () => {
	expect(disposableOrigin('http://iris-navigation.localhost:5224/workspace?review')).toBe('http://iris-navigation.localhost:5224');
	for (const url of ['http://iris-navigation.localhost.example.test:5224/workspace?review', 'http://iris-navigation.localhost:5224/workspace', 'http://iris-navigation.localhost:5224/other?review']) {
		expect(() => disposableOrigin(url)).toThrow('Refusing reset');
	}
});

// Exercise each real runner before it can load a fixture or attach to Chrome.
// Removing the origin guard must fail these tests without clearing any storage.
test('incoming relationship fixture uses its own isolated origin', () => {
 expect(disposableOrigin('http://iris-incoming.localhost:5232/workspace?review')).toBe('http://iris-incoming.localhost:5232');
});

const scripts = ['test-creation-intent.ts', 'test-rejection-inbox.ts', 'test-sidebar-recents.ts', 'test-sidebar-mutations.ts', 'test-incoming-references.ts', 'test-enrollment.ts', 'test-services.ts', 'test-sql-integrity.ts', 'test-workspace-regressions.ts', 'test-markdown-editor.ts', 'test-editor-island.ts', 'test-record-autosave.ts', 'test-search.ts', 'test-search-sync.ts', 'test-saved-views.ts', 'test-table-invariants.ts', 'test-partial-sync.ts', 'test-reference-navigation.ts', 'test-reference-create.ts', 'test-reference-mutations.ts', 'test-workspace-navigation.ts', 'test-navigation-mutations.ts', 'test-read-dependencies.ts', 'test-remote-browse.ts', 'test-command-palette.ts', 'test-command-palette-mutations.ts', 'test-session-undo.ts', 'test-session-undo-mutations.ts', 'test-record-grid.ts', 'test-grid-components.ts', 'test-grid-mutations.ts', 'test-grid-undo.ts', 'test-grid-undo-mutations.ts'];
const unsafe = [
	'https://example.com/workspace?review',
	'http://localhost:5198/workspace?review',
	'http://127.0.0.1:5198/workspace?review',
	'http://iris-services.localhost.example.com/workspace?review',
	'http://iris-services.localhost:5198/workspace',
	'http://iris-services.localhost:5198/other?review',
	'http://fixture@iris-services.localhost:5198/workspace?review',
	'https://iris-services.localhost:5198/workspace?review'
];
for (const script of scripts) {
	for (const url of unsafe) {
		test(`${script} refuses to reset ${url}`, async () => {
			const child = Bun.spawn([process.execPath, resolve(import.meta.dir, script), '/missing-iris-test-source', '/missing-iris-test-source'], {
				env: { ...process.env, IRIS_TEST_URL: url }, stdout: 'pipe', stderr: 'pipe'
			});
			const error = await new Response(child.stderr).text();
			expect(await child.exited).not.toBe(0);
			expect(error).toContain('Refusing reset outside a reserved Iris test origin');
		});
	}
}

test('enrollment storage reset requires exactly the reserved origin and port',()=>{
 expect(disposableOrigin('http://iris-enrollment.localhost:5230/workspace?review')).toBe('http://iris-enrollment.localhost:5230');
 for(const address of ['http://iris-enrollment.localhost:5231/workspace?review','http://iris-enrollment.localhost/workspace?review','https://iris-enrollment.localhost:5230/workspace?review','http://iris-enrollment.localhost:5230/workspace','http://iris-enrollment.localhost.example.test:5230/workspace?review'])expect(()=>disposableOrigin(address)).toThrow('Refusing reset');
});

test('grid fixtures permit only the reserved origin and review path', () => {
	expect(disposableOrigin('http://iris-grid.localhost:5228/workspace?review')).toBe('http://iris-grid.localhost:5228');
	for (const address of ['http://iris-grid.localhost:5228/workspace', 'http://iris-grid.localhost.evil.test:5228/workspace?review', 'http://iris-grid.localhost:5228/other?review'])
		expect(() => disposableOrigin(address)).toThrow('Refusing reset');
});

 test('grid enrollment integration reset uses exactly reserved5234', () => {
 expect(disposableOrigin('http://iris-grid-enrollment.localhost:5234/workspace?review')).toBe('http://iris-grid-enrollment.localhost:5234');
 for(const address of ['http://iris-grid-enrollment.localhost:5235/workspace?review','https://iris-grid-enrollment.localhost:5234/workspace?review','http://iris-grid-enrollment.localhost:5234/other?review','http://iris-grid-enrollment.localhost.evil.test:5234/workspace?review']) expect(()=>disposableOrigin(address)).toThrow('Refusing reset');
});

test('recents fixture reset requires its exact reserved host and port',()=>{
 expect(disposableOrigin('http://iris-recents.localhost:5236/workspace?review')).toBe('http://iris-recents.localhost:5236');
 for(const url of ['http://iris-recents.localhost:5237/workspace?review','http://iris-recents.localhost:5236/workspace','http://iris-recents.localhost.example.test:5236/workspace?review']) expect(()=>disposableOrigin(url)).toThrow('Refusing reset');
});

 test('creation fixture reset requires exactly reserved5242',()=>{
 expect(disposableOrigin('http://iris-creation.localhost:5242/workspace?review')).toBe('http://iris-creation.localhost:5242');
 for(const address of ['http://iris-creation.localhost:5243/workspace?review','https://iris-creation.localhost:5242/workspace?review','http://iris-creation.localhost:5242/workspace','http://iris-creation.localhost.evil.test:5242/workspace?review']) expect(()=>disposableOrigin(address)).toThrow('Refusing reset');
});

test('catalog editor fixture reset is limited to its exact origin',()=>{
 expect(disposableOrigin('http://iris-catalog.localhost:5282/workspace?review')).toBe('http://iris-catalog.localhost:5282');
 for(const address of ['http://iris-catalog.localhost:5283/workspace?review','https://iris-catalog.localhost:5282/workspace?review','http://iris-catalog.localhost:5282/workspace'])expect(()=>disposableOrigin(address)).toThrow('Refusing reset');
});
