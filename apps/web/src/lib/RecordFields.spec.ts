import type { Property } from 'iris-core/client';
import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { createRawSnippet } from 'svelte';
import { Window } from 'happy-dom';
import RecordFields from './RecordFields.svelte';

test('deprecated fields remain accessible in a collapsed historical section', () => {
	const window = new Window();
	const properties: Property[] = [{ col: 'active' }, { col: 'legacy', deprecated: 1 }];
	const field = createRawSnippet<[Property]>((property) => ({
		render: () => `<div data-col="${property().col}">Stored value</div>`
	}));
	window.document.body.innerHTML = render(RecordFields, { props: { properties, field } }).body;
	const details = window.document.querySelector('details');
	expect(details?.hasAttribute('open')).toBe(false);
	expect(details?.querySelector('summary')?.textContent).toContain('Deprecated columns');
	expect(details?.querySelector('[data-col="legacy"]')?.textContent).toBe('Stored value');
	expect(details?.querySelector('[data-col="active"]')).toBeNull();
	expect(window.document.querySelector('[data-col="active"]')).not.toBeNull();
	expect(properties).toEqual([{ col: 'active' }, { col: 'legacy', deprecated: 1 }]);
	window.close();
});
test('active fields alone do not offer an empty deprecated section', () => {
	const field = createRawSnippet<[never]>(() => ({ render: () => '<div>Active</div>' }));
	const body = render(RecordFields, {
		props: { properties: [{ col: 'active' }], field } as never
	}).body;
	expect(body).not.toContain('<details');
	expect(body).toContain('Active');
});
