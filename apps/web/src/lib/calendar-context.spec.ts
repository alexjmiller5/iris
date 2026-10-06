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

// Literal civil-time examples catch midnight rollover and fixed UTC-hour shifts.
test.each([
	[
		'2026-06-02T06:59:59.999Z',
		'2026-06-01',
		'2026-06-01T07:00:00.000Z',
		'2026-06-02T07:00:00.000Z'
	],
	['2026-06-02T07:00:00Z', '2026-06-02', '2026-06-02T07:00:00.000Z', '2026-06-03T07:00:00.000Z'],
	[
		'2026-03-08T06:59:59.999Z',
		'2026-03-07',
		'2026-03-07T08:00:00.000Z',
		'2026-03-08T07:00:00.000Z'
	],
	['2026-03-08T07:00:00Z', '2026-03-08', '2026-03-08T07:00:00.000Z', '2026-03-09T07:00:00.000Z'],
	[
		'2026-11-01T07:59:59.999Z',
		'2026-10-31',
		'2026-10-31T07:00:00.000Z',
		'2026-11-01T08:00:00.000Z'
	],
	['2026-11-01T08:00:00Z', '2026-11-01', '2026-11-01T08:00:00.000Z', '2026-11-02T08:00:00.000Z']
])(
	'configured 03:00 day at %s has matching date label and instant bounds',
	(now, today, start, end) => {
		expect(calendarContext('America/New_York', new Date(now), 180)).toEqual({ today, start, end });
	}
);

test('changing timezone or boundary immediately recalculates the active day', () => {
	const now = new Date('2026-06-02T06:59:59.999Z');
	expect(calendarContext('UTC', now, 180)).toEqual({
		today: '2026-06-02',
		start: '2026-06-02T03:00:00.000Z',
		end: '2026-06-03T03:00:00.000Z'
	});
	expect(calendarContext('America/New_York', now).today).toBe('2026-06-02');
	expect(calendarContext('Asia/Kathmandu', now, 180)).toEqual({
		today: '2026-06-02',
		start: '2026-06-01T21:15:00.000Z',
		end: '2026-06-02T21:15:00.000Z'
	});
});

test('a skipped boundary uses the next valid time, and a repeated boundary uses its first occurrence', () => {
	expect(calendarContext('America/New_York', new Date('2026-03-08T07:00:00Z'), 150)).toEqual({
		today: '2026-03-08',
		start: '2026-03-08T07:00:00.000Z',
		end: '2026-03-09T06:30:00.000Z'
	});
	expect(calendarContext('America/New_York', new Date('2026-11-01T06:15:00Z'), 90)).toEqual({
		today: '2026-11-01',
		start: '2026-11-01T05:30:00.000Z',
		end: '2026-11-02T06:30:00.000Z'
	});
});

test.each([-1, 1440, 1.5, NaN, Infinity])('rejects invalid day-start minutes %s', (minutes) => {
	expect(() => calendarContext('UTC', new Date('2026-06-02T12:00:00Z'), minutes)).toThrow();
});

test('a skipped civil date does not end the previous task day before the next rollover', () => {
	expect(calendarContext('Pacific/Apia', new Date('2011-12-30T12:00:00Z'), 180)).toEqual({
		today: '2011-12-29',
		start: '2011-12-29T13:00:00.000Z',
		end: '2011-12-30T13:00:00.000Z'
	});
});

test('crossing the first midnight keeps its day label when a fold returns to the previous wall date', () => {
	expect(calendarContext('America/Goose_Bay', new Date('2009-11-01T03:05:00Z'))).toEqual({
		today: '2009-11-01',
		start: '2009-11-01T03:00:00.000Z',
		end: '2009-11-02T04:00:00.000Z'
	});
});
