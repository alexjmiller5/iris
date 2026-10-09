import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vitest/config';
import adapter from '@sveltejs/adapter-cloudflare';
import { sveltekit } from '@sveltejs/kit/vite';

export default defineConfig({
	plugins: [
		tailwindcss(),
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			adapter: adapter()
		})
	],
	// The database worker's dependencies are known up front, so the first open
	// never stops to re-optimize and reload the page.
	optimizeDeps: { include: ['wa-sqlite', 'wa-sqlite/src/examples/OPFSCoopSyncVFS.js'] },
	// Browser checks pin the served page: edits by other tools in a shared checkout
	// must not reload it mid-test.
	server: process.env.IRIS_DEV_NO_HMR ? { hmr: false } : undefined,
	test: {
		expect: { requireAssertions: true },
		projects: [
			{
				extends: './vite.config.ts',
				test: {
					name: 'server',
					environment: 'node',
					include: ['src/**/*.{test,spec}.{js,ts}'],
					exclude: ['src/**/*.svelte.{test,spec}.{js,ts}']
				}
			}
		]
	}
});
