import type { Catalog, SearchArgs, SearchHit } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
import { type Row } from './validate.ts';
export declare const SEARCH_TEXT_TYPES: Set<string>;
/** FTS syntax is never user syntax. All words are literal prefixes, ANDed.
 * Unicode letters/numbers/marks work in JSC without Intl or a platform parser. */
export declare function compileSearch(text: string): string | null;
/** Queue-only triggers deliberately require no FTS module in other writers.
 * UPSERT avoids an outer OR ABORT/IGNORE/REPLACE overriding conflict handling. */
export declare function searchTriggers(table: string, target?: string): {
    name: string;
    sql: string;
}[];
export declare function isSearchTrigger(trigger: Row): boolean;
/** Call only inside the same BEGIN IMMEDIATE transaction as the final query.
 * The durable queue catches core writes, pulls and Python writes while closed.
 * Fingerprints describe schemas/catalogs, never row timestamps or row contents. */
export declare function prepareSearch(db: SqlDriver, catalog: Catalog): Promise<void>;
/** Hosts may call at database open to fail early on incompatible SQLite.
 * No triggers, user rows or sync schema are changed by this capability probe. */
export declare function assertSearchSupport(db: SqlDriver): Promise<void>;
/** Search only the local replica. Missing/skipped remote tables are not queried. */
export declare function search(db: SqlDriver, args: SearchArgs): Promise<SearchHit[]>;
/** Ranked matches per search; more matches than this rank only the most recently indexed. */
export declare const SEARCH_RANKED_MATCHES = 2000;
