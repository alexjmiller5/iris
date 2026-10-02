import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';

const path = (relative: string) => fileURLToPath(new URL(relative, import.meta.url));
const hash = (source: string) => createHash('sha256').update(source).digest('base64');

export default defineConfig({
	plugins: [
		tailwindcss(),
		svelte({ configFile: false }),
		{
			name: 'standalone-editor-html',
			enforce: 'post',
			generateBundle(_options, bundle) {
				const chunks = Object.values(bundle).filter((file) => file.type === 'chunk');
				const styles = Object.values(bundle).filter(
					(file) => file.type === 'asset' && file.fileName.endsWith('.css')
				);
				if (
					chunks.length !== 1 ||
					styles.length === 0 ||
					chunks[0].imports.length ||
					// Rolldown records inlined dynamic imports as references to this same chunk.
					chunks[0].dynamicImports.some((name) => name !== chunks[0].fileName) ||
					Object.keys(bundle).length !== chunks.length + styles.length
				) {
					throw new Error(
						'Editor island must contain one script, inline CSS and no external assets.'
					);
				}
				const script = chunks[0].code.replace(/<\/script/gi, '<\\/script');
				const css = styles.map((file) => String(file.source)).join('\n');
				const csp = `default-src 'none'; script-src 'sha256-${hash(script)}'; style-src 'sha256-${hash(css)}'; base-uri 'none'; form-action 'none'`;
				for (const name of Object.keys(bundle)) delete bundle[name];
				this.emitFile({
					type: 'asset',
					fileName: 'editor.html',
					source: `<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="${csp}"><title>Markdown editor</title><style>${css}</style></head><body><script>${script}</script></body></html>\n`
				});
			}
		}
	],
	build: {
		target: 'safari17',
		outDir: path('../../packages/LifeKit/Sources/LifeKit/Resources'),
		emptyOutDir: false,
		cssCodeSplit: false,
		rolldownOptions: { output: { codeSplitting: false } },
		lib: { entry: path('./src/editor.ts'), name: 'LifeEditorIsland', formats: ['iife'] }
	}
});
