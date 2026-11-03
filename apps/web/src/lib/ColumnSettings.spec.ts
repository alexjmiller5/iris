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

test('column settings use column vocabulary', () => {
	const body = render(ColumnSettings, {
		props: { properties: [], columns: [], widths: {}, onChange: () => {} } as never
	}).body;
	expect(body).toContain('Show columns');
	expect(body).toContain('No additional columns.');
	expect(body).not.toContain('properties');
});

test('deprecated columns are absent from layout choices without mutating saved layout', () => {
	const columns = ['old', 'active'];
	const props = {
		properties: [
			{ col: 'old', label: 'Historical', deprecated: 1 },
			{ col: 'active', label: 'Active' }
		],
		columns,
		widths: {},
		onChange: () => {}
	};
	const body = render(ColumnSettings, { props: props as never }).body;
	expect(body).not.toContain('Show Historical');
	expect(body).toContain('Show Active');
	expect(columns).toEqual(['old', 'active']);
});
