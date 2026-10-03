import { expect, test } from 'bun:test';
import { resolve } from 'node:path';

// Exercise each real runner before it can load a fixture or attach to Chrome.
// Removing the origin guard must fail these tests without clearing any storage.
const scripts = ['test-services.ts', 'test-sql-integrity.ts', 'test-workspace-regressions.ts', 'test-markdown-editor.ts', 'test-editor-island.ts', 'test-body-autosave.ts', 'test-search.ts', 'test-search-sync.ts', 'test-typed-filters.ts', 'test-saved-views.ts'];
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
