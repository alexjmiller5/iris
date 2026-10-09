import type { SqlDriver } from './driver.ts';
import type { ServiceHub } from './services.ts';
import type { BackupSummary, HubBackup, HubBackupList, RestorePreview, RestoreResult, RestoreArgs } from './contract.generated.ts';
export type { BackupSummary, BackupTableSummary, HubBackup, HubBackupList, RestorePreview, RestoreResult } from './contract.generated.ts';
/** Version of the SQL dump shape: `soma export`, hub backups and exportReplica.
 * A dump without the header line is the same version-1 shape. */
export declare const DUMP_VERSION = 1;
export declare const DUMP_HEADER = "-- soma-dump: 1";
/** Successive text chunks of one dump, gzip already removed and checked by the host. */
export interface DumpSource {
    read(): Promise<string | null>;
}
export interface DumpSink {
    write(text: string): Promise<void>;
    close(): Promise<void>;
}
/** Host-owned files named by opaque references. open() starts a fresh read each
 * call; create() replaces the destination and close() makes it durable. */
export interface BackupFiles {
    open(file: string): DumpSource;
    create(file: string): DumpSink;
}
export declare class BackupInvalid extends Error {
    name: string;
}
export declare function validateBackup(source: DumpSource): Promise<BackupSummary>;
/** Counts of the live replica, in the same shape as a backup summary. */
export declare function replicaSummary(db: SqlDriver): Promise<BackupSummary>;
export declare function previewRestore(db: SqlDriver, source: DumpSource): Promise<RestorePreview>;
/** The portable SQL dump of `soma export`: the replica's schema log and every
 * ordinary table with its rows, then indexes, triggers and views. Device sync
 * state, caches and other underscore plumbing stay out. */
export declare function exportReplica(db: SqlDriver, sink: DumpSink): Promise<BackupSummary>;
/** Replaces every ordinary table, its rows and the schema log with the backup's,
 * in one transaction, after writing a recovery dump of the current replica.
 * Device sync state resets, so the next sync pulls everything and pushes every
 * restored row: newer hub revisions still win, rows the hub lacks reach it. */
export declare function restoreReplica(db: SqlDriver, files: BackupFiles, args: RestoreArgs): Promise<RestoreResult>;
export declare const hubBackupRoute: (key: string) => string;
export declare function listHubBackups(hub: ServiceHub): Promise<HubBackupList>;
export declare function createHubBackup(hub: ServiceHub): Promise<HubBackup>;
