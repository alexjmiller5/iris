import type { SqlDriver } from './driver.ts';
import type { SyncStatus } from './contract.generated.ts';
export type { SyncStatus } from './contract.generated.ts';
/** The last completed round's exclusions, for readers that need only the names. */
export declare function skippedTableNames(db: SqlDriver): Promise<string[]>;
export declare function syncStatus(db: SqlDriver): Promise<SyncStatus>;
