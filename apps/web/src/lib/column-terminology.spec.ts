import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import SortMenu from './SortMenu.svelte';
import ViewFilter from './ViewFilter.svelte';
import ViewControls from './ViewControls.svelte';
import PresentationControls from './PresentationControls.svelte';

test('sort and advanced filter controls name columns', () => {
	const sorts = render(SortMenu, {
		props: {
			id: 'sort',
			sorts: [{ column: 'title', direction: 'asc' }],
			properties: [{ col: 'title' }],
			onchange: () => {}
		}
	}).body;
	expect(sorts).toContain('aria-label="Sort 1 column"');
	const filter = render(ViewFilter, {
		props: {
			rule: { column: 'title', op: 'eq', values: [] },
			properties: [{ col: 'title' }],
			pick: true,
			onchange: () => {}
		}
	}).body;
	expect(filter).toContain('aria-label="Column"');
});

test.each([
	[{ kind: 'calendar', dateColumn: 'day' }, ['Calendar date column', 'Calendar end date column']],
	[{ kind: 'gallery' }, ['Gallery cover column']],
	[{ kind: 'board', groupColumn: 'state' }, ['Board group column']]
])('presentation controls name columns for %j', (value, labels) => {
	const html = render(PresentationControls, {
		props: {
			value,
			properties: [
				{ col: 'day', type: 'date' },
				{ col: 'cover', type: 'text' },
				{ col: 'state', type: 'select' }
			],
			onchange: () => {}
		} as never
	}).body;
	for (const label of labels as string[]) expect(html).toContain(`aria-label="${label}"`);
	expect(html).not.toMatch(/aria-label="[^"]*property/i);
});

test('row actions use column vocabulary for unavailable fields and additions', () => {
	const html = render(ViewControls, {
		props: {
			properties: [{ col: 'active' }],
			actions: [{ id: 'action', label: 'Action', values: { missing: 'kept' } }],
			columns: [],
			timeZone: 'UTC',
			onchange: () => {}
		}
	}).body;
	expect(html).toContain('Unavailable column: missing');
	expect(html).toContain('Add column value');
});
