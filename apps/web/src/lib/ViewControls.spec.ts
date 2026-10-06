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

test('action fields receive dynamic choices without depending on record editor state', () => {
	const html = render(ViewControls, {
		props: {
			properties: [
				{ tbl: 'items', col: 'status', type: 'select', options_sql: "SELECT 'Dynamic'" }
			],
			sorts: [],
			groups: [],
			actions: [{ id: 'finish', label: 'Finish', values: { status: null } }],
			columns: ['status'],
			timeZone: 'UTC',
			actionOptions: { status: ['Dynamic'] },
			onchange: () => {}
		}
	}).body;
	expect(html).toContain('value="Dynamic"');
});
