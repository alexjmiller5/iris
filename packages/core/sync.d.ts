import type { SqlDriver, Hub } from './driver.ts';
import type { SyncSettings, SyncResult } from './contract.generated.ts';
export type { SyncResult } from './contract.generated.ts';
export type SyncOptions = SyncSettings & {
    now?: () => Date;
    maxClockSkewMs?: number;
};
export declare function initCore(db: SqlDriver): Promise<void>;
export declare function sync(db: SqlDriver, hub: Hub, options?: SyncOptions): Promise<SyncResult>;
export declare function upsertSql(table: string, columns: string[]): string;
