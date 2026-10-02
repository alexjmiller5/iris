import { type Property, type Row } from "./validate.ts";
export type Filter = {
    column: string;
    op: "eq" | "ne" | "contains" | "gt" | "gte" | "lt" | "lte" | "empty" | "not_empty";
    value?: string | number | boolean | null;
};
export type View = {
    table: string;
    columns?: string[];
    filters?: Filter[];
    sort?: {
        column: string;
        direction: "asc" | "desc";
    }[];
    limit?: number;
    offset?: number;
    trash?: boolean;
    search?: string;
};
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
