import type { CalendarContext } from 'life-ui-core/client';

/** Calendar policy stays in the host. The shared core also runs without Intl. */
export function calendarContext(timeZone: string, now: Date = new Date()): CalendarContext {
	if (!Number.isFinite(now.getTime())) throw new Error('Invalid calendar clock.');
	const formatter = new Intl.DateTimeFormat('en-US', {
		timeZone,
		year: 'numeric',
		month: '2-digit',
		day: '2-digit'
	});
	const day = (instant: number) => {
		const parts = formatter.formatToParts(new Date(instant));
		const part = (type: string) => parts.find((p) => p.type === type)!.value;
		return `${part('year').padStart(4, '0')}-${part('month')}-${part('day')}`;
	};
	const today = day(now.getTime());
	const tomorrow = new Date(`${today}T12:00:00Z`);
	tomorrow.setUTCDate(tomorrow.getUTCDate() + 1);
	const boundary = (label: string) => {
		let lo = now.getTime() - 172800000,
			hi = now.getTime() + 172800000;
		// Find the first instant on this calendar date, including zones whose
		// offset changes at midnight. Never assume a day is 24 hours.
		while (lo < hi) {
			const mid = Math.floor((lo + hi) / 2);
			if (day(mid) < label) lo = mid + 1;
			else hi = mid;
		}
		return new Date(lo).toISOString();
	};
	return { today, start: boundary(today), end: boundary(tomorrow.toISOString().slice(0, 10)) };
}
