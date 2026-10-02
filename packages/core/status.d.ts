import type { SqlDriver } from './driver.ts';
import type { SyncStatus } from './contract.generated.ts';
export type { SyncStatus } from './contract.generated.ts';
export declare function syncStatus(db: SqlDriver): Promise<SyncStatus>;
