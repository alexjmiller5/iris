// Generated from life-core/src/validate.ts. SHA-256: 935c3c8b8e272959a51c548522dc97aa1a27f6ea0d31b023fd8424e942040f6f
import type { Row, Property, Violation } from './contract.generated.ts';
export type { Row, OptionDef, Property, Violation } from './contract.generated.ts';
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
