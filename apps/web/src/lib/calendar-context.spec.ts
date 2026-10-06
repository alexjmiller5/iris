import { expect, test } from 'vitest';
import { calendarContext } from './calendar-context';

test.each([
	['2026-03-08T16:00:00Z', '2026-03-08', '2026-03-08T05:00:00.000Z', '2026-03-09T04:00:00.000Z'],
	['2026-11-01T16:00:00Z', '2026-11-01', '2026-11-01T04:00:00.000Z', '2026-11-02T05:00:00.000Z'],
	[
		'2026-03-09T03:59:59.999Z',
		'2026-03-08',
		'2026-03-08T05:00:00.000Z',
		'2026-03-09T04:00:00.000Z'
	],
	['2026-03-09T04:00:00Z', '2026-03-09', '2026-03-09T04:00:00.000Z', '2026-03-10T04:00:00.000Z']
])('calendar boundaries at %s use local days including DST', (now, today, start, end) => {
	expect(calendarContext('America/New_York', new Date(now))).toEqual({ today, start, end });
});
test('calendar validates its clock and zone, and supports non-hour offsets', () => {
	expect(() => calendarContext('Invalid/Zone', new Date())).toThrow();
	expect(() => calendarContext('UTC', new Date(NaN))).toThrow();
	expect(calendarContext('Asia/Kathmandu', new Date('2026-06-01T12:00:00Z'))).toEqual({
		today: '2026-06-01',
		start: '2026-05-31T18:15:00.000Z',
		end: '2026-06-01T18:15:00.000Z'
	});
});
