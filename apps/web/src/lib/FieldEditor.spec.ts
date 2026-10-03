import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import FieldEditor from './FieldEditor.svelte';

function field(props: Record<string, unknown>) {
	const window = new Window();
	window.document.body.innerHTML = render(FieldEditor, {
		props: {
			id: 'test-field',
			property: { col: 'value', label: 'Value' },
			value: '',
			...props
		} as never
	}).body;
	return window;
}
test('multi-select keeps unknown selections alongside described options', () => {
	const window = field({
		property: { col: 'tags', type: 'multi_select', options: [{ v: 'new', d: 'A new tag' }] },
		value: '["retired"]'
	});
	expect(
		[...window.document.querySelectorAll('option')].map((o) => [o.value, o.selected, o.textContent])
	).toEqual([
		['new', false, 'new - A new tag'],
		['retired', true, 'retired']
	]);
	window.close();
});
test('false stays an unchecked checkbox with an explicit clear control', () => {
	const window = field({ property: { col: 'active', type: 'bool', label: 'Active' }, value: '0' });
	expect(window.document.querySelector('input')?.type).toBe('checkbox');
	expect(window.document.querySelector('input')?.checked).toBe(false);
	expect(window.document.querySelector('[aria-label="Clear Active"]')).not.toBeNull();
	window.close();
});
test('unknown reference remains selected and unavailable instead of being silently cleared', () => {
	const window = field({
		property: { col: 'project', type: 'ref' },
		value: 'missing',
		references: [{ id: 'live', label: 'Live project' }]
	});
	expect(window.document.querySelectorAll('option')[1]?.selected).toBe(true);
	expect(window.document.querySelector('option[value="missing"]')?.textContent).toContain(
		'not available locally'
	);
	window.close();
});
test('duplicate stored references render one chip per identity', () => {
	const window = field({
		property: { col: 'links', type: 'multi_ref' },
		value: '["r1","r1"]',
		references: [{ id: 'r1', label: 'First record' }]
	});
	expect(window.document.querySelectorAll('.chip')).toHaveLength(1);
	window.close();
});
test.each(['text', 'number', 'int', 'date', 'datetime', 'email', 'phone', 'url', 'json'])(
	'a disabled %s editor cannot mutate read-only fields',
	(type) => {
		const window = field({
			property: { col: 'value', type },
			disabled: true,
			value: type === 'date' ? '2026-01-01' : 'sample'
		});
		expect(window.document.querySelector('input,textarea,select')?.hasAttribute('disabled')).toBe(
			true
		);
		window.close();
	}
);
