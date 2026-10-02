// Generated from life-core/src/validate.ts. SHA-256: ecf9606f8e87d199dc85bdc6c0324ebfc68a9a7adc4c0b371db1df41b759d486
export type Row = Record<string, unknown>;
export type OptionDef = {
    v: string;
    d?: string;
    sort?: number;
};
export type Property = {
    tbl?: string;
    col: string;
    label?: string | null;
    sort?: number | null;
    type?: string | null;
    required?: number | boolean | null;
    default_value?: string | null;
    options?: OptionDef[] | null;
    options_sql?: string | null;
    min_items?: number | null;
    max_items?: number | null;
    pattern?: string | null;
    ref_table?: string | null;
    derived_by?: string | null;
    inputs?: string[] | null;
    immutable?: number | boolean | null;
    deprecated?: number | boolean | null;
    description?: string | null;
};
export type Violation = {
    col: string;
    rule: string;
    message: string;
};
export type ValidateOptions = {
    /** Derived columns the hub is filling in this write (derivation runs only). */
    inDerive?: Set<string>;
    /** Does `table` have a live row with this id? null = do not check refs. */
    refOk?: ((table: string, id: unknown) => boolean) | null;
    /** Values an `options_sql` property allows beyond its static options. */
    extraOptions?: ((p: Property) => string[]) | null;
    /** Columns a partial write carries; null = every column. */
    touched?: Set<string> | null;
};
/** An `updated_at` the sync protocol accepts: exact UTC millisecond ISO-8601. */
export declare function validEditTimestamp(value: unknown): boolean;
export declare const empty: (v: unknown) => boolean;
export declare function asList(v: unknown): unknown[] | null;
export declare function same(a: unknown, b: unknown): boolean;
/** The values a select / multi_select property allows. */
export declare function allowed(p: Property, extraOptions?: ((p: Property) => string[]) | null): string[];
export declare function validateRow(props: Property[], before: Row | null, after: Row, { inDerive, refOk, extraOptions, touched }?: ValidateOptions): Violation[];
export declare function ident(name: string): string;
export declare function qident(name: string): string;
