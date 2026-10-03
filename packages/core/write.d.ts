import type { SqlDriver } from './driver.ts';
import { type Row } from './validate.ts';
import type { WriteViolation, Writeability, WriteabilityArgs } from './contract.generated.ts';
export type { WriteViolation } from './contract.generated.ts';
export declare class ValidationError extends Error {
    readonly violations: WriteViolation[];
    constructor(violations: WriteViolation[]);
}
/** UI and write boundary share this contract: service-owned tables carry
 * catalog_tables.kind='system'. Free-form owner text is not a permission. */
export declare function isReadOnlyTable(table: string, catalogEntry?: Row): boolean;
/** Advisory table guards only; writeRow rechecks in its own transaction and
 * still validates the actual patch, selected revision and stored values. */
export declare function writeability(db: SqlDriver, args: WriteabilityArgs): Promise<Writeability>;
/** Missing id creates; supplied id edits an existing row (never upserts).
 * deleted_at:true requests deletion at the new revision; null restores.
 * now/id are host/test seams; id generates row IDs only. History IDs always
 * come from SQLite. No caller may supply created_at, updated_at or hub_at.
 * Table invariants require verified dependency coverage (global without a
 * compiler metadata adapter). The one-row
 * before/changed contexts preserve SQLite values; custom effects stay closed.
 * Custom triggers anywhere in main/temp block writes. Exact main timestamp
 * triggers and queue-only search triggers are supported.
 * Forms should pass expectedUpdatedAt from their selected row. A stale edit
 * fails with rule='conflict'; omit it for unconditional merges into current data.
 */
export declare function writeRow(db: SqlDriver, table: string, patch: Row, options?: WriteOptions): Promise<Row>;
type WriteOptions = {
    now?: () => Date;
    id?: () => string;
    origin?: string;
    expectedUpdatedAt?: string;
};
/** Internal transaction result, never a client-supplied inverse or a wire DTO. */
export type WriteCapture = {
    before: Row | null;
    after: Row;
    columns: string[];
    shape: string;
    receiptId: string;
};
/** One write implementation. Capture is returned only after transaction commit;
 * the session publishes it afterwards, never via a callback inside the transaction. */
export declare function commitWrite(db: SqlDriver, table: string, patch: Row, options?: WriteOptions, capture?: boolean, expected?: Pick<WriteCapture, 'shape' | 'after'>): Promise<{
    row: Row;
    capture: WriteCapture | null;
}>;
