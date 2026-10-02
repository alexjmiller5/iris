import type { SqlDriver } from './driver.ts';
export type SyncStatus = {
    lastSuccessfulSync: string | null;
    /** Distinct UI-written rows awaiting this core's accepted receipt, not the CLI queue. */
    pendingUiEdits: number;
    /** Distinct rows in the durable rejection inbox, regardless of writer. */
    rejected: number;
};
export declare function syncStatus(db: SqlDriver): Promise<SyncStatus>;
