import type { RejectionsArgs, RejectionsPage } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
/** Read the durable inbox only. A saved correction is still rejected until sync
 * accepts it. Hosts re-read a full local row before editing its current revision. */
export declare function readRejections(db: SqlDriver, args?: RejectionsArgs): Promise<RejectionsPage>;
