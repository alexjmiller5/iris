import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import RecordGrid from './RecordGrid.svelte';

test('grid exposes labeled cells by identity and a guarded bottom creation action', () => {
	const window = new Window();
	window.document.body.innerHTML = render(RecordGrid, {
		props: {
			rows: [{ id: 'a', title: 'Alpha', qty: 0 }],
			properties: [
				{ col: 'title', label: 'Record' },
				{ col: 'qty', label: 'Quantity', type: 'int' }
			],
			widths: {},
			busy: false,
			canCreate: false,
			format: (_p, value) => String(value ?? ''),
			canEdit: () => true,
			onbegin: async () => false as const,
			oncommit: async () => ({}),
			onopen: async () => false,
			onnew: async () => false,
			onduplicate: async () => false
		}
	}).body;
	expect(window.document.querySelector('[role="grid"]')).not.toBeNull();
	expect(window.document.querySelector('input[type="checkbox"]')).toBeNull();
	expect(
		window.document.querySelector('[role="gridcell"][data-row="a"][data-column="qty"]')?.textContent
	).toContain('0');
	expect(
		window.document.querySelector('[aria-label="New record at bottom"]')?.hasAttribute('disabled')
	).toBe(true);
	window.close();
});

test.each([false, true])(
	'grid offers its guarded %s trash action independently of creation',
	(trash) => {
		const window = new Window();
		const actionLabel = trash ? 'Restore record' : 'Move to trash';
		window.document.body.innerHTML = render(RecordGrid, {
			props: {
				rows: [{ id: 'a', title: 'Alpha' }],
				properties: [{ col: 'title' }],
				widths: {},
				busy: false,
				canCreate: false,
				canTrash: true,
				trash,
				format: (_p: unknown, value: unknown) => String(value ?? ''),
				canEdit: () => false,
				onbegin: async () => false as const,
				oncommit: async () => ({}),
				onopen: async () => false,
				onnew: async () => false,
				onduplicate: async () => false,
				ontrash: async () => false
			} as never
		}).body;
		// Named by its visible text so speech and voice control agree.
		const action = [...window.document.querySelectorAll('.grid-actions button')].find(
			(button) => button.textContent?.trim() === actionLabel
		);
		expect(action?.hasAttribute('aria-label')).toBe(false);
		// No row selected yet. In Trash, creation can stay unavailable while Restore exists.
		expect(action?.hasAttribute('disabled')).toBe(true);
		window.close();
	}
);

test('configured action columns reorder data and keep the first visible data cell tabbable', () => {
	const window = new Window();
	window.document.body.innerHTML = render(RecordGrid, {
		props: {
			selectedIds: [],
			rows: [{ id: 'a', title: 'Alpha', state: 'Open', updated_at: '2026-01-01T00:00:00.000Z' }],
			properties: [
				{ col: 'title', label: 'Title' },
				{ col: 'state', label: 'State' }
			],
			widths: {},
			busy: false,
			canCreate: false,
			actions: [{ id: 'close', label: 'Close item', values: { state: 'Closed' } }],
			actionLayout: [
				{ kind: 'action', id: 'close' },
				{ kind: 'column', id: 'state' },
				{ kind: 'column', id: 'title' }
			],
			canRunAction: false,
			onaction: async () => {},
			format: (_p: unknown, value: unknown) => String(value ?? ''),
			canEdit: () => false,
			onbegin: async () => false,
			oncommit: async () => ({}),
			onopen: async () => false,
			onnew: async () => false,
			onduplicate: async () => false
		} as never
	}).body;
	expect([...window.document.querySelectorAll('th')].map((e) => e.textContent?.trim())).toEqual([
		'', // The loaded-page selection checkbox precedes configured data/action columns.
		'Close item',
		'State',
		'Title'
	]);
	expect(window.document.querySelector('[data-column="state"]')?.getAttribute('tabindex')).toBe(
		'0'
	);
	expect(window.document.querySelector('[data-column="title"]')?.getAttribute('tabindex')).toBe(
		'-1'
	);
	expect(
		window.document.querySelector('button[aria-label="Close item"]')?.hasAttribute('disabled')
	).toBe(true);
	window.close();
});

test('select and multi-select cells show option chips tinted by catalog color', () => {
	const window = new Window();
	window.document.body.innerHTML = render(RecordGrid, {
		props: {
			rows: [{ id: 'a', title: 'Alpha', status: 'Done', tags: '["Home","Loose"]' }],
			properties: [
				{ col: 'title', label: 'Record' },
				{ col: 'status', type: 'select', options: [{ v: 'Done', color: 'green' }] },
				{ col: 'tags', type: 'multi_select', options: [{ v: 'Home', color: 'blue' }] }
			],
			widths: {},
			busy: false,
			canCreate: false,
			format: (_p, value) => String(value ?? ''),
			canEdit: () => true,
			onbegin: async () => false as const,
			oncommit: async () => ({}),
			onopen: async () => false,
			onnew: async () => false,
			onduplicate: async () => false
		}
	}).body;
	const chips = (column: string) =>
		[...window.document.querySelectorAll(`[data-column="${column}"] .option-chip`)].map((chip) => [
			chip.textContent,
			chip.getAttribute('data-color')
		]);
	expect(chips('status')).toEqual([['Done', 'green']]);
	expect(chips('tags')).toEqual([
		['Home', 'blue'],
		['Loose', null]
	]);
	expect(chips('title')).toEqual([]);
	window.close();
});
