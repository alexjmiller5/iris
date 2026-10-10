import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import ViewFilter from './ViewFilter.svelte';

test('mixed date fields offer ordered comparisons and Today', () => {
	const html = render(ViewFilter, {
		props: {
			rule: { column: 'due', op: 'lte', values: ['2026-03-08'] },
			properties: [{ tbl: 'items', col: 'due', type: 'date_or_datetime', label: 'Due' }],
			onchange: () => {}
		}
	}).body;
	expect(html).toContain('aria-label="Compare with"');
	expect(html).toContain('Today');
	expect(html).toContain('is on or before');
	expect(html).toContain('value="2026-03-08"');
});

test('select values are a checkbox list with the chosen options checked', () => {
	const html = render(ViewFilter, {
		props: {
			rule: { column: 'status', op: 'eq', values: ['Done'] },
			properties: [
				{
					tbl: 'items',
					col: 'status',
					type: 'select',
					label: 'Status',
					options: [{ v: 'Open' }, { v: 'Done', color: 'green' }]
				}
			],
			onchange: () => {}
		}
	}).body;
	expect(html.match(/type="checkbox"/g)).toHaveLength(2);
	const chip = (value: string) =>
		new RegExp(`type="checkbox"[^>]*checked[^>]*>(\\s|<!--[^>]*-->)*<span[^>]*>${value}`);
	expect(html).toMatch(chip('Done'));
	expect(html).not.toMatch(chip('Open'));
	expect(html).toMatch(/<span class="option-chip" data-color="green">Done<\/span>/);
	expect(html).toMatch(/<span class="option-chip">Open<\/span>/);
});
