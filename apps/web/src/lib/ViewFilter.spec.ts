import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import ViewFilter from './ViewFilter.svelte';

test('mixed date fields expose the Today control to the user', () => {
	const html = render(ViewFilter, {
		props: {
			filter: { column: 'due', op: 'lte', value: '2026-03-08' },
			properties: [{ tbl: 'items', col: 'due', type: 'date_or_datetime', label: 'Due' }],
			onchange: () => {},
			onremove: () => {}
		}
	}).body;
	expect(html).toContain('aria-label="Date comparison"');
	expect(html).toContain('value="today"');
});
