import type { PrepareReadPlanArgs, ReadPlan } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
/** Read-only preparation. The host serializes this transaction with its backup;
 * a reader must recheck every guard on that backup before executing the plan.
 * Exact ordered rows are the fingerprints: no second platform hash algorithm,
 * lossy digest or SQL/value matching is needed to recognize schema/catalog drift. */
export declare function prepareReadPlan(db: SqlDriver, value: PrepareReadPlanArgs): Promise<ReadPlan>;
