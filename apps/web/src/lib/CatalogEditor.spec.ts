import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import CatalogEditor from './CatalogEditor.svelte';

test('catalog editor shows editable option descriptions and preserves the stable property identity', () => {
	const html = render(CatalogEditor, {
		props: {
			table: 'items',
			catalog: {
				tables: [],
				properties: [
					{
						id: 'opaque-property',
						tbl: 'items',
						col: 'state',
						type: 'select',
						label: 'State',
						updated_at: '2026-01-01T00:00:00.000Z',
						options: [{ v: 'Draft', d: 'Work in progress' }]
					}
				],
				rules: []
			},
			onproperty: async () => ({ col: 'state' }),
			onrule: async () => ({}),
			onclose: () => {}
		}
	}).body;
	expect(html).toContain('Work in progress');
	expect(html).toContain('Draft');
	expect(html).toContain('Property ID');
	expect(html).toContain('Save property');
	expect(html).toContain('Existing records are kept unchanged');
});

test('each option offers the palette with its color selected and a tinted preview', () => {
	const html = render(CatalogEditor, {
		props: {
			table: 'items',
			catalog: {
				tables: [],
				properties: [
					{
						id: 'items.state',
						tbl: 'items',
						col: 'state',
						type: 'select',
						options: [{ v: 'Draft', color: 'blue' }, { v: 'Plain' }]
					}
				],
				rules: []
			},
			onproperty: async () => ({ col: 'state' }),
			onrule: async () => ({}),
			onclose: () => {}
		}
	}).body;
	expect(html.match(/aria-label="Option 1 [a-z]+ color"/g)).toHaveLength(11);
	expect(html).toMatch(/aria-label="Option 1 blue color"[^>]*checked/);
	expect(html).toMatch(/aria-label="Option 2 no color"[^>]*checked/);
	expect(html).toContain('<span class="option-chip" data-color="blue">Draft</span>');
});
