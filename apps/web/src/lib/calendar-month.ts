import type { CalendarContext } from 'life-ui-core/client';
import { calendarContext } from './calendar-context';

export function calendarMonth(
	month: string,
	timeZone: string,
	dayStartMinutes = 0
): CalendarContext[] {
	if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(month)) throw new Error('Choose a valid month.');
	const first = `${month}-01`;
	let day = calendarContext(
		timeZone,
		new Date(Date.parse(first + 'T00:00:00Z') - 48 * 3600000),
		dayStartMinutes
	);
	const days: CalendarContext[] = [];
	for (let i = 0; i < 36; i++) {
		if (day.today >= first) {
			if (!day.today.startsWith(month + '-')) break;
			days.push(day);
		}
		day = calendarContext(timeZone, new Date(day.end), dayStartMinutes);
	}
	return days;
}
