import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import ColumnSettings from './ColumnSettings.svelte';

test.each([true, false])('Wrap all columns reflects whether every column wraps (%s)', (all) => {
	const window = new Window();
	window.document.body.innerHTML = render(ColumnSettings, {
		props: {
			properties: [{ col: 'note', label: 'Note' }],
			columns: ['note'],
			widths: {},
			onChange: () => {},
			wrapAll: all,
			onWrapAll: () => {}
		} as never
	}).body;
	const box = window.document.querySelector('input[aria-label="Wrap all columns"]');
	expect(box).not.toBeNull();
	expect(box?.hasAttribute('checked')).toBe(all);
	window.close();
});

test('without a saved view there is no wrap control to change', () => {
	const window = new Window();
	window.document.body.innerHTML = render(ColumnSettings, {
		props: { properties: [], columns: [], widths: {}, onChange: () => {} } as never
	}).body;
	expect(window.document.querySelector('input[aria-label="Wrap all columns"]')).toBeNull();
	window.close();
});
