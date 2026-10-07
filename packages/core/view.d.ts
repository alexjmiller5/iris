import { type Property, type Row } from "./validate.ts";
import type { View, CalendarContext, ReadPlanKind, ReadPlanParameter } from './contract.generated.ts';
export type { Filter, View } from './contract.generated.ts';
/** Compile a catalog-scoped view. Equality is null-safe; contains is literal
 * (ASCII case-insensitive text, exact JSON array membership). Empty includes
 * NULL, empty strings and, for multi-value properties, empty JSON arrays.
 * Nonempty search requires the prepared local FTS index. Prefer readRows(),
 * which drains its queue and queries in the same transaction.
 */
export declare function compileView(view: View, properties: Property[]): {
    sql: string;
    params: (string | number | null)[];
};
type IncomingReference = {
    table: string;
    rowId: string;
    column: string;
    type: 'ref' | 'multi_ref';
};
/** The same view compiler with a catalog-checked incoming relation predicate. */
export declare function compileReferenceView(view: View, properties: Property[], reference: IncomingReference): {
    sql: string;
    params: import("./contract.generated.ts").SQLScalar[];
};
/** Same compiler, tagged at binding sites. The caller supplies explicit title/id
 * projection and validates the saved definition before count drops its ordering. */
export declare function compileReadQuery(view: View, properties: Property[], kind: ReadPlanKind): {
    sql: string;
    parameters: ReadPlanParameter[];
};
/** Saved definitions validate without a host clock; executing a relative query requires one. */
export declare function validateView(view: View, properties: Property[]): void;
export declare function validateCalendarContext(value: CalendarContext | undefined): CalendarContext | undefined;
/** Use only the configured scalar label, then id; never infer a schema. */
export declare function displayName(row: Row, displayColumn?: string | null): string;
