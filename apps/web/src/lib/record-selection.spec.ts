import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import RecordGrid from './RecordGrid.svelte';

test('the grid exposes separate exact row selections and a loaded-page selector', () => {
	const window = new Window();
	window.document.body.innerHTML = render(RecordGrid, { props: {
		rows: [{ id: 'é', title: 'First' }, { id: 'e\u0301', title: 'Second' }],
		properties: [{ tbl: 'items', col: 'title', type: 'text' }], widths: {},
		busy: false, canCreate: false, format: (_p, value) => String(value), canEdit: () => false,
		onbegin: async () => false, oncommit: async () => ({}), onopen: async () => true,
		onnew: async () => true, onduplicate: async () => true,
		selectedIds: ['é']
	} }).body;
	const checks = [...window.document.querySelectorAll<HTMLInputElement>('input[type="checkbox"]')];
	expect(checks).toHaveLength(3);
	expect(checks[0]?.getAttribute('aria-label')).toBe('Select loaded rows');
	expect(checks.slice(1).map((box) => box.checked)).toEqual([true, false]);
	window.happyDOM.abort();
});
