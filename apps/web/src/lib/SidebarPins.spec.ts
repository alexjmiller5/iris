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
function rendered(mutationDisabled = false) {
	const win = new Window();
	win.document.body.innerHTML = render(SidebarPins, {
		props: {
			pins,
			current: 'zeta',
			disabled: false,
			mutationDisabled,
			error: null,
			onchoose: () => {},
			onunpin: () => {},
			onreorder: async () => true,
			onretry: () => {}
		}
	}).body;
	return win;
}
test('each pin has a drag handle and a context menu, not arrow or unpin buttons', () => {
	const win = rendered();
	const doc = win.document;
	expect(
		[...doc.querySelectorAll('[data-pin-table]')].map((el) => el.getAttribute('data-pin-table'))
	).toEqual(['zeta', 'alpha']);
	for (const table of ['zeta', 'alpha']) {
		const handle = doc.querySelector(`[aria-label="Reorder ${table}"]`);
		expect(handle?.tagName).toBe('BUTTON');
		expect(handle?.getAttribute('aria-disabled')).toBe('false');
		expect(handle?.getAttribute('aria-keyshortcuts')).toBe('Alt+ArrowUp Alt+ArrowDown');
	}
	expect(doc.querySelector('[aria-label="Reorder zeta"] svg.tabler-icon-menu-2')).not.toBeNull();
	expect(doc.querySelectorAll('[aria-label^="Move "], [aria-label^="Unpin "]')).toHaveLength(0);
	const menu = doc.querySelector('[role="menu"]');
	expect(menu?.getAttribute('popover')).toBe('manual');
	expect(menu?.querySelector('[role="menuitem"]')?.textContent?.trim()).toBe('Unpin');
	expect(doc.querySelector('[aria-label="Open pinned alpha"]')?.hasAttribute('disabled')).toBe(
		true
	);
	expect(doc.querySelector('[aria-label="Open pinned zeta"]')?.getAttribute('aria-current')).toBe(
		'page'
	);
	expect(doc.querySelector('[aria-live="polite"]')).not.toBeNull();
	win.close();
});
test('pending pin storage disables reordering and Unpin but not navigation', () => {
	const win = rendered(true);
	const doc = win.document;
	// Still focusable, so a brief reload never drops keyboard focus.
	expect(doc.querySelector('[aria-label="Reorder zeta"]')?.getAttribute('aria-disabled')).toBe(
		'true'
	);
	expect(doc.querySelector('[role="menuitem"]')?.getAttribute('aria-disabled')).toBe('true');
	expect(
		doc.querySelectorAll('[aria-label="Reorder zeta"][disabled], [role="menuitem"][disabled]')
	).toHaveLength(0);
	expect(doc.querySelector('[aria-label="Open pinned zeta"]')?.hasAttribute('disabled')).toBe(
		false
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
