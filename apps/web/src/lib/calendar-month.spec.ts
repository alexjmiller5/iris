import { expect, it } from 'vitest';
import { calendarMonth } from './calendar-month';
it('uses real spring and fall civil boundaries', () => {
	const spring = calendarMonth('2026-03', 'America/New_York');
	expect(spring).toHaveLength(31);
	expect(spring[7]).toEqual({
		today: '2026-03-08',
		start: '2026-03-08T05:00:00.000Z',
		end: '2026-03-09T04:00:00.000Z'
	});
	const fall = calendarMonth('2026-11', 'America/New_York', 180);
	expect(fall[0]).toEqual({
		today: '2026-11-01',
		start: '2026-11-01T08:00:00.000Z',
		end: '2026-11-02T08:00:00.000Z'
	});
});
it('selects the requested month in extreme timezones, and skips nonexistent civil dates', () => {
	for (const zone of ['Pacific/Kiritimati', 'Pacific/Pago_Pago', 'UTC']) {
		const days = calendarMonth('2026-02', zone);
		expect(days).toHaveLength(28);
		expect(days[0].today).toBe('2026-02-01');
		expect(days.at(-1)?.today).toBe('2026-02-28');
	}
	const apia = calendarMonth('2011-12', 'Pacific/Apia');
	expect(apia).toHaveLength(30);
	expect(apia.some((d) => d.today === '2011-12-30')).toBe(false);
});
it('refuses malformed month values', () => {
	for (const value of ['2026-13', 'bad', '2026-00', '2026-2'])
		expect(() => calendarMonth(value, 'UTC')).toThrow();
});
