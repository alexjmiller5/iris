import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import HubEnrollment from './HubEnrollment.svelte';

test('enrollment offers explicit approval and a separate manual token alternative without persistence', () => {
	const window = new Window();
	const { body } = render(HubEnrollment, {
		props: { core: {} as never, onconnect: async () => {}, endpoint: '', token: '' }
	});
	window.document.body.innerHTML = body;
	expect(window.document.querySelector('button')?.textContent).toContain('Approve this browser');
	expect(window.document.querySelector('label[for="device-name"]')?.textContent).toBe(
		'Device name'
	);
	const manual = window.document.querySelector('details');
	expect(manual?.querySelector('summary')?.textContent).toBe('Use a device token');
	expect(manual?.hasAttribute('open')).toBe(false);
	expect(manual?.querySelector('input')?.type).toBe('password');
	expect(manual?.querySelector('input')?.autocomplete).toBe('off');
	expect(window.document.body.textContent).toContain('memory');
	window.close();
});
