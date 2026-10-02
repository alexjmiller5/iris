import { type Property, type Row } from "./validate.ts";
import type { View } from './contract.generated.ts';
export type { Filter, View } from './contract.generated.ts';
/** Compile a catalog-scoped view. Equality is null-safe; contains is literal
 * (ASCII case-insensitive text, exact JSON array membership). Empty includes
 * NULL, empty strings and, for multi-value properties, empty JSON arrays.
 */
export declare function compileView(view: View, properties: Property[]): {
    sql: string;
    params: (string | number | null)[];
};
/** Use only the configured scalar label, then id; never infer a schema. */
export declare function displayName(row: Row, displayColumn?: string | null): string;
