import type { Catalog, RunRowActionArgs, WriteArgs } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
import { type Row } from './validate.ts';
/** Validate saved literal edits and presentation references. Dynamic options,
 * references, invariants and coverage are checked by the ordinary writer. */
export declare function validateRowActions(value: Row, catalog: Catalog, table: string): string[];
/** Called within the mutation session's writer transaction. Both the saved
 * definition and the complete row are resolved under the same reservation. */
export declare function resolveRowAction(db: SqlDriver, args: RunRowActionArgs): Promise<WriteArgs>;
