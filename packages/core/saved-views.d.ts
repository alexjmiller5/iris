import type { DeleteViewArgs, ListViewsArgs, SaveViewArgs, SavedViewList, SavedViewRecord } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
import { type Row } from './validate.ts';
import { type WriteCapture } from './write.ts';
/** Internal action lookup; the caller holds the writer transaction. */
export declare function loadSavedView(db: SqlDriver, id: string): Promise<SavedViewRecord>;
/** Lists shared definitions only. Returned view.columns is SQL projection and
 * may omit id, updated_at and hidden fields. For editing, query without columns
 * or fetch a full row by id; never treat a projected row as a complete record. */
export declare function listViews(db: SqlDriver, args: ListViewsArgs): Promise<SavedViewList>;
export declare function saveView(db: SqlDriver, args: SaveViewArgs, options?: {
    origin?: string;
}, capture?: (value: WriteCapture) => void): Promise<SavedViewRecord>;
/** Tombstone through writeRow without requiring a readable definition. */
export declare function deleteView(db: SqlDriver, args: DeleteViewArgs, options?: {
    origin?: string;
}, capture?: (value: WriteCapture) => void): Promise<SavedViewRecord>;
/** Revalidate a saved-view inverse inside the same transaction as its write. */
export declare function validateViewUndo(db: SqlDriver, before: Row, patch: Row): Promise<void>;
