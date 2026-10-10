import type { SqlDriver, Hub } from './driver.ts';
import type { SyncSettings, SyncResult } from './contract.generated.ts';
export type { SyncResult } from './contract.generated.ts';
export type SyncOptions = SyncSettings & {
    now?: () => Date;
    maxClockSkewMs?: number;
};
/** The size rule: without a host's maxRows, a round skips tables holding more rows than this. */
export declare const SIZE_RULE_ROWS = 50000;
export declare function initCore(db: SqlDriver): Promise<void>;
export declare function sync(db: SqlDriver, hub: Hub, options?: SyncOptions): Promise<SyncResult>;
export declare function upsertSql(table: string, columns: string[]): string;
