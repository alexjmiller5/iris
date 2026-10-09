import type { CalendarContext } from 'iris-core/client';

/** Calendar policy stays in the host. The shared core also runs without Intl. */
export function calendarContext(
	timeZone: string,
	now: Date = new Date(),
	dayStartMinutes = 0
): CalendarContext {
	if (!Number.isFinite(now.getTime())) throw new Error('Invalid calendar clock.');
	if (!Number.isInteger(dayStartMinutes) || dayStartMinutes < 0 || dayStartMinutes >= 1440)
		throw new Error('Day start must be a whole minute from 00:00 through 23:59.');
	const formatter = new Intl.DateTimeFormat('en-US', {
		timeZone,
		calendar: 'gregory',
		numberingSystem: 'latn',
		year: 'numeric',
		month: '2-digit',
		day: '2-digit',
		hour: '2-digit',
		minute: '2-digit',
		second: '2-digit',
		hourCycle: 'h23'
	});
	const civil = (instant: number) => {
		const parts = formatter.formatToParts(new Date(instant));
		const part = (type: string) => parts.find((p) => p.type === type)!.value;
		return `${part('year').padStart(4, '0')}-${part('month')}-${part('day')}T${part('hour')}:${part('minute')}:${part('second')}`;
	};
	const day = (instant: number) => civil(instant).slice(0, 10);
	const wall = (instant: number) => Date.parse(`${civil(instant)}Z`);
	const nextDate = (label: string) => {
		const date = new Date(`${label}T12:00:00Z`);
		date.setUTCDate(date.getUTCDate() + 1);
		return date.toISOString().slice(0, 10);
	};
	const midnight = (label: string) => {
		const nominal = Date.parse(`${label}T00:00:00Z`);
		// The wall date itself can reverse after midnight. Resolve both sides
		// of the offset transition before searching for a skipped midnight.
		const exact = [nominal - 129600000, nominal + 129600000]
			.map((instant) => nominal - (wall(instant) - instant))
			.filter((instant) => wall(instant) === nominal);
		if (exact.length) return Math.min(...exact);
		let lo = nominal - 172800000,
			hi = nominal + 172800000;
		while (lo < hi) {
			const mid = Math.floor((lo + hi) / 2);
			if (day(mid) < label) lo = mid + 1;
			else hi = mid;
		}
		return lo;
	};
	const boundary = (label: string) => {
		let lo = midnight(label);
		if (dayStartMinutes === 0) return lo;
		// A timezone can skip a whole civil date. Use the next existing date's
		// configured boundary rather than ending the interval at its midnight.
		label = day(lo);
		let hi = midnight(nextDate(label));
		const target = Date.parse(`${label}T00:00:00Z`) + dayStartMinutes * 60000;
		// Try both offsets of a transition day. When the clock repeats, retain
		// its first occurrence even if now is inside the second occurrence.
		const candidates = [lo, hi - 1000]
			.map((instant) => target - (wall(instant) - instant))
			.filter((instant) => instant >= lo && instant < hi && wall(instant) === target);
		if (candidates.length) return Math.min(...candidates);
		// A nonexistent wall time resolves to the first valid instant after the
		// gap, not the requested minute shifted by the size of the gap.
		while (lo < hi) {
			const mid = Math.floor((lo + hi) / 2);
			if (wall(mid) < target) lo = mid + 1;
			else hi = mid;
		}
		return lo;
	};
	let today = day(now.getTime());
	if (now.getTime() < boundary(today)) today = day(midnight(today) - 1);
	// A midnight fold can return the clock to yesterday after today's first
	// boundary has already passed. Keep the interval label monotonic.
	while (now.getTime() >= boundary(nextDate(today))) today = day(midnight(nextDate(today)));
	return {
		today,
		start: new Date(boundary(today)).toISOString(),
		end: new Date(boundary(nextDate(today))).toISOString()
	};
}
