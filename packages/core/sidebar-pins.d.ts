import type { EmptyArgs, MoveTablePinArgs, PinTableArgs, SidebarPinList, UnpinTableArgs } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
/** Catalog keys use the core's ASCII identifier grammar; no host TextEncoder required. */
export declare function sidebarPinID(table: string): string;
export declare function listSidebarPins(db: SqlDriver, args: EmptyArgs): Promise<SidebarPinList>;
export declare function pinTable(db: SqlDriver, input: PinTableArgs, options?: {
    origin?: string;
}): Promise<SidebarPinList>;
export declare function unpinTable(db: SqlDriver, input: UnpinTableArgs, options?: {
    origin?: string;
}): Promise<SidebarPinList>;
export declare function moveTablePin(db: SqlDriver, input: MoveTablePinArgs, options?: {
    origin?: string;
}): Promise<SidebarPinList>;
