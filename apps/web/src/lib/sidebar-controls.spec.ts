import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import SidebarTables from './SidebarTables.svelte';
import SidebarRecents from './SidebarRecents.svelte';
import type { RecentEntry } from './sidebar-recents';

function documentFor(body: string) {
	const window = new Window();
	window.document.body.innerHTML = body;
	return window;
}
test('only the catalog boolean separates system tables; current system table expands its group', () => {
	const window = documentFor(
		render(SidebarTables, {
			props: {
				tables: [
					{ id: '_ordinary', readOnly: false },
					{ id: 'unsupported_view', readOnly: false },
					{ id: 'service_owned', readOnly: true }
				],
				current: 'service_owned',
				disabled: false,
				onchoose: () => {}
			}
		}).body
	);
	const doc = window.document;
	expect(doc.querySelector('nav[aria-label="Tables"]')?.textContent).toContain('_ordinary');
	expect(doc.querySelector('nav[aria-label="Tables"]')?.textContent).toContain('unsupported_view');
	expect(doc.querySelector('nav[aria-label="Tables"]')?.textContent).not.toContain('service_owned');
	expect(doc.querySelector('details summary')?.textContent).toBe('System tables');
	expect(doc.querySelector('details')?.hasAttribute('open')).toBe(true);
	expect(doc.querySelector('nav[aria-label="System tables"] button')?.textContent).toContain(
		'service_owned'
	);
	expect(
		doc.querySelector('nav[aria-label="System tables"] button')?.hasAttribute('disabled')
	).toBe(false);
	window.close();
});
test('no empty system section; pending operations disable table navigation', () => {
	const window = documentFor(
		render(SidebarTables, {
			props: {
				tables: [{ id: 'notes', readOnly: false }],
				current: 'notes',
				disabled: true,
				onchoose: () => {}
			}
		}).body
	);
	expect(window.document.querySelector('details')).toBeNull();
	expect(window.document.querySelector('button')?.hasAttribute('disabled')).toBe(true);
	window.close();
});
test('unavailable/loading recent entries remain visible with a reason and independent Remove actions', () => {
	const entries: RecentEntry[] = [
		{
			destination: { table: 'notes', view: null, row: 'gone' },
			label: 'gone',
			context: 'Record · notes',
			trash: false,
			loading: false,
			unavailable: 'Not available in this replica'
		},
		{
			destination: { table: 'notes', view: null, row: 'trash' },
			label: 'Old title',
			context: 'Record · notes',
			trash: true,
			loading: false,
			unavailable: null
		},
		{
			destination: { table: 'notes', view: 'view', row: null },
			label: 'view',
			context: 'View · notes',
			trash: false,
			loading: true,
			unavailable: null
		}
	];
	const window = documentFor(
		render(SidebarRecents, {
			props: {
				entries,
				current: entries[1].destination,
				busy: false,
				storageError: 'Recents could not be saved on this device.',
				onchoose: () => {},
				onremove: () => {}
			}
		}).body
	);
	const doc = window.document;
	expect(doc.querySelector('nav[aria-label="Recent destinations"]')).not.toBeNull();
	// Each destination is named by its visible title and context, never a hidden label.
	const recent = (label: string) =>
		[...doc.querySelectorAll('.destination')].find(
			(button) => button.querySelector('strong')?.textContent === label
		);
	expect(doc.querySelectorAll('.destination[aria-label]')).toHaveLength(0);
	expect(recent('gone')?.hasAttribute('disabled')).toBe(true);
	expect(
		doc.querySelector('[aria-label="Remove gone from recents"]')?.hasAttribute('disabled')
	).toBe(false);
	expect(doc.body.textContent).toContain('Not available in this replica');
	expect(recent('Old title')?.hasAttribute('disabled')).toBe(false);
	expect(recent('Old title')?.textContent).toContain('Trash');
	expect(recent('Old title')?.getAttribute('aria-current')).toBe('page');
	expect(recent('view')?.hasAttribute('disabled')).toBe(true);
	expect(doc.querySelector('[role="status"]')?.textContent).toContain('Recents could not be saved');
	window.close();
});
