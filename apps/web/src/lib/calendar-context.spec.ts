import { expect, test } from 'vitest';
import { calendarContext, localTimeInstant } from './calendar-context';

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
	expect(calendarContext('America/New_York', new Date(now))).toMatchObject({ today, start, end });
});
test('calendar validates its clock and zone, and supports non-hour offsets', () => {
	expect(() => calendarContext('Invalid/Zone', new Date())).toThrow();
	expect(() => calendarContext('UTC', new Date(NaN))).toThrow();
	expect(calendarContext('Asia/Kathmandu', new Date('2026-06-01T12:00:00Z'))).toMatchObject({
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
		expect(calendarContext('America/New_York', new Date(now), 180)).toMatchObject({
			today,
			start,
			end
		});
	}
);

test('changing timezone or boundary immediately recalculates the active day', () => {
	const now = new Date('2026-06-02T06:59:59.999Z');
	expect(calendarContext('UTC', now, 180)).toMatchObject({
		today: '2026-06-02',
		start: '2026-06-02T03:00:00.000Z',
		end: '2026-06-03T03:00:00.000Z'
	});
	expect(calendarContext('America/New_York', now).today).toBe('2026-06-02');
	expect(calendarContext('Asia/Kathmandu', now, 180)).toMatchObject({
		today: '2026-06-02',
		start: '2026-06-01T21:15:00.000Z',
		end: '2026-06-02T21:15:00.000Z'
	});
});

test('a skipped boundary uses the next valid time, and a repeated boundary uses its first occurrence', () => {
	expect(calendarContext('America/New_York', new Date('2026-03-08T07:00:00Z'), 150)).toMatchObject({
		today: '2026-03-08',
		start: '2026-03-08T07:00:00.000Z',
		end: '2026-03-09T06:30:00.000Z'
	});
	expect(calendarContext('America/New_York', new Date('2026-11-01T06:15:00Z'), 90)).toMatchObject({
		today: '2026-11-01',
		start: '2026-11-01T05:30:00.000Z',
		end: '2026-11-02T06:30:00.000Z'
	});
});

test.each([-1, 1440, 1.5, NaN, Infinity])('rejects invalid day-start minutes %s', (minutes) => {
	expect(() => calendarContext('UTC', new Date('2026-06-02T12:00:00Z'), minutes)).toThrow();
});

test('a skipped civil date does not end the previous task day before the next rollover', () => {
	expect(calendarContext('Pacific/Apia', new Date('2011-12-30T12:00:00Z'), 180)).toMatchObject({
		today: '2011-12-29',
		start: '2011-12-29T13:00:00.000Z',
		end: '2011-12-30T13:00:00.000Z'
	});
});

test('crossing the first midnight keeps its day label when a fold returns to the previous wall date', () => {
	expect(calendarContext('America/Goose_Bay', new Date('2009-11-01T03:05:00Z'))).toMatchObject({
		today: '2009-11-01',
		start: '2009-11-01T03:00:00.000Z',
		end: '2009-11-02T04:00:00.000Z'
	});
});

test('a boundary inside a skipped midnight resolves to the first valid civil instant', () => {
	expect(calendarContext('America/Sao_Paulo', new Date('2018-11-04T03:00:00Z'), 30)).toMatchObject({
		today: '2018-11-04',
		start: '2018-11-04T03:00:00.000Z',
		end: '2018-11-05T02:30:00.000Z'
	});
});

test('an empty or missing timezone follows this device', () => {
	const now = new Date('2026-06-02T06:30:00Z');
	const device = calendarContext(Intl.DateTimeFormat().resolvedOptions().timeZone, now, 180);
	expect(calendarContext('', now, 180)).toEqual(device);
	expect(calendarContext(undefined, now, 180)).toEqual(device);
});

test('the context carries the clock reading and its local bounds as floating local times', () => {
	expect(calendarContext('America/New_York', new Date('2032-10-13T16:30:45.120Z'), 180)).toEqual({
		today: '2032-10-13',
		start: '2032-10-13T07:00:00.000Z',
		end: '2032-10-14T07:00:00.000Z',
		now: '2032-10-13T16:30:45.120Z',
		localNow: '2032-10-13T12:30',
		localStart: '2032-10-13T03:00',
		localEnd: '2032-10-14T03:00'
	});
	// Before the day start the reading still belongs to the previous policy day.
	expect(calendarContext('America/New_York', new Date('2032-10-14T05:00:00Z'), 180)).toMatchObject({
		today: '2032-10-13',
		localNow: '2032-10-14T01:00'
	});
});

test.each([
	['2032-10-13T12:00', 'America/New_York', '2032-10-13T16:00:00.000Z'],
	['2032-10-13T12:00', 'Asia/Kathmandu', '2032-10-13T06:15:00.000Z'],
	// A wall time skipped by daylight saving advances to the first valid instant.
	['2026-03-08T02:30', 'America/New_York', '2026-03-08T07:00:00.000Z'],
	// A repeated wall time uses its first occurrence.
	['2026-11-01T01:30', 'America/New_York', '2026-11-01T05:30:00.000Z']
])('local time %s in %s is the instant %s', (value, zone, instant) => {
	expect(new Date(localTimeInstant(value, zone)!).toISOString()).toBe(instant);
});

test.each(['2032-10-13', '2032-02-30T12:00', '2032-10-13T24:00', '2032-10-13T12:00:00.000Z', ''])(
	'%s is not a floating local time',
	(value) => {
		expect(localTimeInstant(value, 'UTC')).toBeNull();
	}
);
