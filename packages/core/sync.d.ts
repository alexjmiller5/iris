import type { SqlDriver, Hub } from './driver.ts';
import { type Row } from './validate.ts';
export type SyncOptions = {
    maxRows?: number;
    tables?: Record<string, boolean>;
    now?: () => Date;
    maxClockSkewMs?: number;
};
export type SyncResult = {
    pulled: number;
    pushed: number;
    skipped: string[];
    rejected: Row[];
};
export declare function initCore(db: SqlDriver): Promise<void>;
export declare function sync(db: SqlDriver, hub: Hub, options?: SyncOptions): Promise<SyncResult>;
export declare function upsertSql(table: string, columns: string[]): string;
