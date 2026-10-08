import type { UndoArgs, WriteArgs } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
import { type WriteCapture } from './write.ts';
import type { Row } from './validate.ts';
/** Private to createCoreHandlers. A new instance owns an empty volatile undo stack.
 * Hosts still serialize all database use; this queue additionally orders direct
 * session mutations and status reads through COMMIT and receipt publication. */
export declare function createWriteSession(db: SqlDriver, origin: string): {
    write: (args: WriteArgs) => Row | Promise<Row>;
    runRowAction: (args: import("./contract.generated.ts").RunRowActionArgs) => Row | Promise<Row>;
    undo: (args: UndoArgs) => Row | Promise<Row>;
    undoStatus: (args: import("./contract.generated.ts").EmptyArgs) => import("./contract.generated.ts").UndoStatus | Promise<import("./contract.generated.ts").UndoStatus>;
    capturedMutation: <A, T>(table: string, input: A, operation: (args: A, capture: (value: WriteCapture) => void) => Promise<T>) => Promise<T>;
    uncapturedMutation: <A, T>(input: A, operation: (args: A) => Promise<T>) => Promise<T>;
    replaceAll: <T>(operation: () => Promise<T>) => Promise<T>;
};
