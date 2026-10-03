import { expect, test } from 'bun:test';
import { resolve } from 'node:path';
import { disposableOrigin, workspacePage } from './test-origin';

const fixtureAddress = 'http://life-ui-navigation.localhost:5224/workspace?review';
const tab = (url: string) => ({ url: () => url });
test('palette fixture reset is bounded to its reserved host and review path', () => {
	expect(disposableOrigin('http://life-ui-palette.localhost:5226/workspace?review')).toBe('http://life-ui-palette.localhost:5226');
	for (const address of ['http://life-ui-palette.localhost.example.test:5226/workspace?review', 'http://life-ui-palette.localhost:5226/workspace', 'http://life-ui-palette.localhost:5226/other?review']) {
		expect(() => disposableOrigin(address)).toThrow('Refusing reset');
	}
});
test('fixture selection survives product query changes without matching other origins or paths', () => {
	const intended = tab('http://life-ui-navigation.localhost:5224/workspace?table=odd+table&view=view%2F&row=row%26');
	const unrelated = [
		tab('http://life-ui-navigation.localhost:5224/workspace-other?review'),
		tab('http://life-ui-navigation.localhost.example.test:5224/workspace?review'),
		tab('http://life-ui-navigation.localhost:5225/workspace?review'),
		tab('https://life-ui-navigation.localhost:5224/workspace?review'),
		tab('http://fixture@life-ui-navigation.localhost:5224/workspace?review'),
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
	expect(disposableOrigin('http://life-ui-navigation.localhost:5224/workspace?review')).toBe('http://life-ui-navigation.localhost:5224');
	for (const url of ['http://life-ui-navigation.localhost.example.test:5224/workspace?review', 'http://life-ui-navigation.localhost:5224/workspace', 'http://life-ui-navigation.localhost:5224/other?review']) {
		expect(() => disposableOrigin(url)).toThrow('Refusing reset');
	}
});

// Exercise each real runner before it can load a fixture or attach to Chrome.
// Removing the origin guard must fail these tests without clearing any storage.
test('incoming relationship fixture uses its own isolated origin', () => {
 expect(disposableOrigin('http://life-ui-incoming.localhost:5232/workspace?review')).toBe('http://life-ui-incoming.localhost:5232');
});

const scripts = ['test-incoming-references.ts', 'test-services.ts', 'test-sql-integrity.ts', 'test-workspace-regressions.ts', 'test-markdown-editor.ts', 'test-editor-island.ts', 'test-body-autosave.ts', 'test-search.ts', 'test-search-sync.ts', 'test-typed-filters.ts', 'test-saved-views.ts', 'test-table-invariants.ts', 'test-partial-sync.ts', 'test-reference-navigation.ts', 'test-reference-mutations.ts', 'test-workspace-navigation.ts', 'test-navigation-mutations.ts', 'test-read-dependencies.ts', 'test-remote-browse.ts', 'test-command-palette.ts', 'test-command-palette-mutations.ts', 'test-session-undo.ts', 'test-session-undo-mutations.ts'];
const unsafe = [
	'https://example.com/workspace?review',
	'http://localhost:5198/workspace?review',
	'http://127.0.0.1:5198/workspace?review',
	'http://life-ui-services.localhost.example.com/workspace?review',
	'http://life-ui-services.localhost:5198/workspace',
	'http://life-ui-services.localhost:5198/other?review',
	'http://fixture@life-ui-services.localhost:5198/workspace?review',
	'https://life-ui-services.localhost:5198/workspace?review'
];
for (const script of scripts) {
	for (const url of unsafe) {
		test(`${script} refuses to reset ${url}`, async () => {
			const child = Bun.spawn([process.execPath, resolve(import.meta.dir, script), '/missing-life-ui-test-source', '/missing-life-ui-test-source'], {
				env: { ...process.env, LIFE_UI_TEST_URL: url }, stdout: 'pipe', stderr: 'pipe'
			});
			const error = await new Response(child.stderr).text();
			expect(await child.exited).not.toBe(0);
			expect(error).toContain('Refusing reset outside a reserved Life UI test origin');
		});
	}
}
