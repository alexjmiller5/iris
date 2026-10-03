import type { Hub, SqlDriver } from './driver.ts';
import type { RemoteRowArgs, RemoteRowResult, RemoteRowsArgs, RemoteRowsPage } from './contract.generated.ts';
type PageArgs = Omit<RemoteRowsArgs, 'endpoint'>;
type RowArgs = Omit<RemoteRowArgs, 'endpoint'>;
/** One online page. Never merges records into the replica or grants coverage.
 * Clients deduplicate repeated IDs across pages on a changing hub before keyed
 * rendering; replacing earlier displayed rows does not establish a snapshot. */
export declare function readRemoteRows(db: SqlDriver, hub: Hub, args: PageArgs): Promise<RemoteRowsPage>;
/** One ID lookup under SQLite column equality. The returned identity may differ
 * in spelling under NOCASE/RTRIM; tombstones remain explicit and read-only. */
export declare function readRemoteRow(db: SqlDriver, hub: Hub, args: RowArgs): Promise<RemoteRowResult>;
export {};
