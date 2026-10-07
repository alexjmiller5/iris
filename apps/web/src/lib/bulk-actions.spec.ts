import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import BulkActions from './BulkActions.svelte';

test('bulk controls require a selection and show partial success semantics before applying', () => {
	const window = new Window();
	window.document.body.innerHTML = render(BulkActions, {
		props: {
			selectedIds: [],
			properties: [],
			onrun: async () => []
		}
	}).body;
	expect(window.document.querySelector('button[data-bulk-apply]')?.hasAttribute('disabled')).toBe(
		true
	);
	expect(window.document.body.textContent).toContain('Each row is saved separately');
	expect(window.document.body.textContent).toContain('0 selected');
	window.happyDOM.abort();
});
