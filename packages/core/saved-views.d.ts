import type { DeleteViewArgs, ListViewsArgs, SaveViewArgs, SavedViewList, SavedViewRecord } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
/** Lists shared definitions only. Returned view.columns is SQL projection and
 * may omit id, updated_at and hidden fields. For editing, query without columns
 * or fetch a full row by id; never treat a projected row as a complete record. */
export declare function listViews(db: SqlDriver, args: ListViewsArgs): Promise<SavedViewList>;
export declare function saveView(db: SqlDriver, args: SaveViewArgs, options?: {
    origin?: string;
}): Promise<SavedViewRecord>;
/** Tombstone through writeRow without requiring a readable definition. */
export declare function deleteView(db: SqlDriver, args: DeleteViewArgs, options?: {
    origin?: string;
}): Promise<SavedViewRecord>;
