import type { ReferenceSource, ReferenceSourcesArgs, ReferencedByArgs, ReferencedByPage } from "./contract.generated.ts";
import type { SqlDriver } from "./driver.ts";
/** Metadata only. Hosts request each group's rows lazily. */
export declare function referenceSources(db: SqlDriver, args: ReferenceSourcesArgs): Promise<ReferenceSource[]>;
/** Incoming links use the target's own identity affinity/collation. A plain
 * source-column equality would lose valid links to case-insensitive IDs. */
export declare function referencedBy(db: SqlDriver, args: ReferencedByArgs): Promise<ReferencedByPage>;
