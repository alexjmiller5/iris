import type { SqlDriver } from './driver.ts';
import type { Row } from './validate.ts';
export declare const COVERAGE_VERSION = 1;
export declare function initCoverage(db: SqlDriver): Promise<void>;
export declare function coverageSchema(db: SqlDriver): Promise<{
    tables: string[];
    signature: string;
}>;
export declare function validCoverage(proof: Row | undefined, endpoint: string, signature: string, pull: unknown): boolean;
/** Read-only, transaction-scoped check. Missing metadata never grants trust. */
export declare function coverageProblem(db: SqlDriver, required?: readonly string[]): Promise<string | null>;
