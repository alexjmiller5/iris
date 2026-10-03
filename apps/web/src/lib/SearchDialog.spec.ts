import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import SearchDialog from './SearchDialog.svelte';

test('the real dialog exposes grouped destinations, keeping invalid views visibly disabled', () => {
	const window = new Window();
	const { body } = render(SearchDialog, {
		props: {
			search: async () => [],
			onchoose: () => {},
			onclose: () => {},
			incomplete: false,
			destinations: [
				{ kind: 'table', table: 'notes', label: 'notes' },
				{
					kind: 'view',
					table: 'notes',
					id: 'future',
					label: 'Future view',
					unavailable: 'Unsupported version'
				}
			],
			onnavigate: async () => false
		}
	});
	window.document.body.innerHTML = body;
	const tables = window.document.querySelector('[role="group"][aria-label="Tables"]');
	expect(tables?.querySelector('[role="option"]')?.textContent).toContain('notes');
	const invalid = window.document.querySelector(
		'[role="group"][aria-label="Saved views"] [role="option"]'
	);
	expect(invalid?.textContent).toContain('Unsupported version');
	expect(invalid?.hasAttribute('disabled')).toBe(true);
	expect(window.document.querySelector('[role="combobox"]')?.getAttribute('aria-expanded')).toBe(
		'true'
	);
	window.close();
});
