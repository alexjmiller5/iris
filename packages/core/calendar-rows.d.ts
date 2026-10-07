import type { CalendarRowsArgs, CalendarRowsResult } from './contract.generated.ts';
/** Rendering only. Hosts supply timezone-aware bounds and keep ordinary query
 * pagination visible. This never rewrites source dates or compiles SQL. */
export declare function calendarRows(args: CalendarRowsArgs): CalendarRowsResult;
