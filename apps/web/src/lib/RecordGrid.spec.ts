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
		const actionLabel = trash ? 'Restore selected record' : 'Trash selected record';
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
		expect(
			window.document.querySelector(`[aria-label="${actionLabel}"]`)?.textContent?.trim()
		).toBe(trash ? 'Restore record' : 'Move to trash');
		// No row selected yet. In Trash, creation can stay unavailable while Restore exists.
		expect(
			window.document.querySelector(`[aria-label="${actionLabel}"]`)?.hasAttribute('disabled')
		).toBe(true);
		window.close();
	}
);
