import type { SqlDriver } from './driver.ts';
import { type Row } from './validate.ts';
import type { WriteViolation } from './contract.generated.ts';
export type { WriteViolation } from './contract.generated.ts';
export declare class ValidationError extends Error {
    readonly violations: WriteViolation[];
    constructor(violations: WriteViolation[]);
}
/** UI and write boundary share this contract: service-owned tables carry
 * catalog_tables.kind='system'. Free-form owner text is not a permission. */
export declare function isReadOnlyTable(table: string, catalogEntry?: Row): boolean;
/** Missing id creates; supplied id edits an existing row (never upserts).
 * deleted_at:true requests deletion at the new revision; null restores.
 * now/id are host/test seams; id generates row IDs only. History IDs always
 * come from SQLite. No caller may supply created_at, updated_at or hub_at.
 * Enforced invariants require the CLI's estate-wide snapshot write path.
 * Custom triggers anywhere in main/temp block writes. Only the exact main
 * timestamp trigger shipped by Python is supported; this writer keeps it idle.
 * Forms should pass expectedUpdatedAt from their selected row. A stale edit
 * fails with rule='conflict'; omit it for unconditional merges into current data.
 */
export declare function writeRow(db: SqlDriver, table: string, patch: Row, options?: {
    now?: () => Date;
    id?: () => string;
    origin?: string;
    expectedUpdatedAt?: string;
}): Promise<Row>;
