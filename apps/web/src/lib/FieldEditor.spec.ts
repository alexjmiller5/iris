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
test.each([
	[
		'url',
		'https://example.test/path?x=1#part',
		'https://example.test/path?x=1#part',
		'Open website'
	],
	['email', 'note+tag@example.test', 'mailto:note%2Btag@example.test', 'Compose email'],
	['phone', '+00 (000) 000-0000', 'tel:+000000000000', 'Call']
])(
	'a %s field offers an explicit open action without changing its text',
	(type, value, href, action) => {
		const window = field({ property: { col: 'value', type }, value });
		const link = window.document.querySelector('a');
		expect(link?.getAttribute('href')).toBe(href);
		expect(link?.textContent).toContain(action);
		expect(window.document.querySelector('input')?.value).toBe(value);
		if (type === 'url') {
			expect(link?.target).toBe('_blank');
			expect(link?.rel.split(' ')).toEqual(expect.arrayContaining(['noopener', 'noreferrer']));
		}
		window.close();
	}
);

test('read-only fields retain their explicit open action', () => {
	const window = field({
		property: { col: 'value', type: 'url' },
		value: 'https://example.test',
		disabled: true
	});
	expect(window.document.querySelector('input')?.disabled).toBe(true);
	expect(window.document.querySelector('a')?.getAttribute('href')).toBe('https://example.test/');
	window.close();
});

test('email text cannot append headers or a fragment to its open action', () => {
	const window = field({
		property: { col: 'value', type: 'email' },
		value: 'note@example.test?bcc=other@example.test#fragment'
	});
	expect(window.document.querySelector('a')?.getAttribute('href')).toBe(
		'mailto:note@example.test%3Fbcc%3Dother@example.test%23fragment'
	);
	window.close();
});

test.each([
	['url', 'javascript:alert(1)'],
	['url', 'file:///tmp/example'],
	['url', 'file://example.test/private'],
	['url', 'ftp://example.test/file'],
	['url', 'data:text/html,test'],
	['url', 'https:///'],
	['url', 'https://example.test\n/secret'],
	['email', 'note@example.test\r\nbcc:other@example.test'],
	['email', '\ud800@example.test'],
	['phone', '*123#'],
	['phone', '+00;ext=123'],
	['text', 'https://example.test'],
	['url', '']
])('unsupported %s destination %s has no open action', (type, value) => {
	const window = field({ property: { col: 'value', type }, value });
	expect(window.document.querySelector('a')).toBeNull();
	window.close();
});

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
test('a stored reference reads as loading, not unavailable, until labels arrive', () => {
	const window = field({
		property: { col: 'project', type: 'ref' },
		value: 'stored',
		referencesLoading: true
	});
	expect(window.document.querySelector('option[value="stored"]')?.textContent).toBe('Loading…');
	window.close();
});
test.each(['text', 'number', 'select', 'json', 'date'])(
	'a refused %s value marks its control invalid and points at the message',
	(type) => {
		const window = field({
			property: { col: 'value', type, options: [{ v: 'A' }] },
			value: 'refused',
			invalid: 'field-value-error'
		});
		const control = window.document.querySelector('#test-field');
		expect(control?.getAttribute('aria-invalid')).toBe('true');
		expect(control?.getAttribute('aria-describedby')).toBe('field-value-error');
		window.close();
	}
);
test('a valid control carries no invalid marker', () => {
	const control = field({
		property: { col: 'value', type: 'text' },
		value: 'fine'
	}).document.querySelector('#test-field');
	expect(control?.hasAttribute('aria-invalid')).toBe(false);
	expect(control?.hasAttribute('aria-describedby')).toBe(false);
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

test('a text record identity offers guarded local navigation without changing the field', () => {
	const window = field({
		property: { col: 'value', type: 'text' },
		value: 'items/exact-id',
		onopenlink: async () => true
	});
	expect(window.document.querySelector('button.field-link')?.textContent).toContain('Open record');
	expect(window.document.querySelector('input')?.value).toBe('items/exact-id');
	expect(window.document.querySelector('a')).toBeNull();
	window.close();
});
test.each(['ordinary text', 'items/', '/items/id', 'https://example.test/path', 'items/id/extra'])(
	'text %s is not offered as a local record identity',
	(value) => {
		const window = field({
			property: { col: 'value', type: 'text' },
			value,
			onopenlink: async () => true
		});
		expect(window.document.querySelector('button.field-link')).toBeNull();
		window.close();
	}
);

test('file properties offer authenticated download even when read-only', () => {
	const window = field({
		property: { col: 'value', type: 'file' },
		value: '/v1/files/attachments/fixture',
		disabled: true,
		resolveFile: async () => {
			throw Error('not invoked during render');
		}
	});
	expect(
		[...window.document.querySelectorAll('button')].some(
			(button) => button.textContent?.trim() === 'Download file' && !button.disabled
		)
	).toBe(true);
	expect(window.document.querySelector('input')?.value).toBe('/v1/files/attachments/fixture');
	window.close();
});
test.each([
	'https://external.invalid/file',
	'/v1/files/../secret',
	'/v1/files/attachments/%2fsecret'
])('file property %s is never an unauthenticated external download', (value) => {
	const window = field({
		property: { col: 'value', type: 'file' },
		value,
		resolveFile: async () => {
			throw Error('not invoked during render');
		}
	});
	expect(window.document.body.textContent).not.toContain('Download file');
	window.close();
});
