import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import ViewControls from './ViewControls.svelte';

test.each([0, 180, 1439])(
	'view options expose the configured minute %s as a time control',
	(minutes) => {
		const window = new Window();
		try {
			window.document.body.innerHTML = render(ViewControls, {
				props: {
					properties: [],
					sorts: [],
					groups: [],
					actions: [],
					columns: [],
					timeZone: 'UTC',
					dayStartMinutes: minutes,
					onchange: () => {}
				}
			}).body;
			const input = window.document.querySelector('[aria-label="Day starts at"]');
			expect(input?.getAttribute('type')).toBe('time');
			expect(input?.getAttribute('value')).toBe(
				({ 0: '00:00', 180: '03:00', 1439: '23:59' } as Record<number, string>)[minutes]
			);
		} finally {
			window.close();
		}
	}
);
