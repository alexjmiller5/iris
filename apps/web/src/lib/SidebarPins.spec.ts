import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import SidebarPins from './SidebarPins.svelte';
import SidebarTables from './SidebarTables.svelte';
const pins = ['zeta', 'alpha'].map((tbl, position) => ({
	id: `pin:${tbl}`,
	tbl,
	position,
	updated_at: '2026-01-01T00:00:00.000Z',
	deleted_at: null,
	unavailable: position ? 'Missing table' : null
}));
test('ordered pins have accessible boundary actions and missing targets remain removable', () => {
	const win = new Window();
	win.document.body.innerHTML = render(SidebarPins, {
		props: {
			pins,
			current: 'zeta',
			disabled: false,
			mutationDisabled: false,
			error: null,
			onchoose: () => {},
			onunpin: () => {},
			onmove: () => {},
			onretry: () => {}
		}
	}).body;
	const doc = win.document;
	expect(
		[...doc.querySelectorAll('[data-pin-table]')].map((el) => el.getAttribute('data-pin-table'))
	).toEqual(['zeta', 'alpha']);
	expect(doc.querySelector('[aria-label="Move zeta up"]')?.hasAttribute('disabled')).toBe(true);
	expect(doc.querySelector('[aria-label="Move zeta down"]')?.hasAttribute('disabled')).toBe(false);
	expect(doc.querySelector('[aria-label="Move alpha down"]')?.hasAttribute('disabled')).toBe(true);
	expect(doc.querySelector('[aria-label="Open pinned alpha"]')?.hasAttribute('disabled')).toBe(
		true
	);
	expect(doc.querySelector('[aria-label="Unpin alpha"]')?.hasAttribute('disabled')).toBe(false);
	expect(doc.querySelector('[aria-label="Open pinned zeta"]')?.getAttribute('aria-current')).toBe(
		'page'
	);
	win.close();
});
test('pin controls are separate from navigation and missing storage disables only pinning', () => {
	const win = new Window();
	win.document.body.innerHTML = render(SidebarTables, {
		props: {
			tables: [{ id: 'alpha' }],
			current: 'alpha',
			disabled: false,
			pinDisabled: true,
			onchoose: () => {},
			onpin: () => {}
		}
	}).body;
	const doc = win.document;
	expect(doc.querySelector('[aria-label="Pin alpha"]')?.hasAttribute('disabled')).toBe(true);
	expect(doc.querySelector('[aria-current="page"]')?.hasAttribute('disabled')).toBe(false);
	expect(doc.querySelector('button button')).toBeNull();
	win.close();
});
