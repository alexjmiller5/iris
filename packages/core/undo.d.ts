import type { UndoArgs, WriteArgs } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
import type { Row } from './validate.ts';
/** Private to createCoreHandlers. A new instance owns an empty volatile slot.
 * Hosts still serialize all database use; this queue additionally orders direct
 * session mutations and status reads through COMMIT and receipt publication. */
export declare function createWriteSession(db: SqlDriver, origin: string): {
    write: (args: WriteArgs) => Row | Promise<Row>;
    undo: (args: UndoArgs) => Row | Promise<Row>;
    undoStatus: (args: import("./contract.generated.ts").EmptyArgs) => import("./contract.generated.ts").UndoStatus | Promise<import("./contract.generated.ts").UndoStatus>;
    otherMutation: <A, T>(input: A, operation: (args: A) => Promise<T>) => Promise<T>;
};
