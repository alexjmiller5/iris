import type { CoreHandlers, OptionsArgs, View, WorkspaceRow } from './contract.generated.ts';
import { type GovernanceAPI } from './governance-service.ts';
import type { SqlDriver } from './driver.ts';
import type { ServiceHub } from './services.ts';
import { type BackupFiles } from './backup.ts';
/** Shared queries; hosts own serialization, read-only SQL enforcement and locks. */
export declare function readRows(db: SqlDriver, view: View): Promise<WorkspaceRow[]>;
export declare function readOptions(db: SqlDriver, { table, column }: OptionsArgs): Promise<string[]>;
/** Typed local dispatch, not a network protocol. Credentials stay in the host. */
export declare function createCoreHandlers(db: SqlDriver, hub: (endpoint: string) => ServiceHub, origin?: string, governance?: GovernanceAPI | null, files?: BackupFiles | null): CoreHandlers;
