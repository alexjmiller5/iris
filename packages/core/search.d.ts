import type { EmptyArgs, SearchArgs, SearchHit, SearchIndexStatus, SearchIndexStepArgs, SearchTableList, SetSearchTableArgs } from './contract.generated.ts';
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
/** Tables the sync size rule would leave out by default (more rows than this) stay out of the index too. */
export declare const SEARCH_MAX_ROWS = 50000;
/** `_core_state` key: a JSON object of table -> true (index it) or false (leave it out), overriding the defaults. */
export declare const SEARCH_TABLES_KEY = "search_tables";
/** The only operation that builds the search index. Hosts call it after each sync round,
 * after local writes and while idle, until `done`. Each call is one transaction: it
 * reconciles if the schema, catalog or settings moved, then indexes or removes chunks of
 * rows until `budgetMs` passes (always at least one chunk), so requests between calls
 * never wait long. Searches and backlinks read whatever it has built so far. */
export declare function searchIndexStep(db: SqlDriver, args?: SearchIndexStepArgs): Promise<SearchIndexStatus>;
/** For a host's settings: every table the index can hold, whether it does and why, its records
 * and an estimate of its text. It only reads; the index step applies any change. */
export declare function searchTables(db: SqlDriver, args?: EmptyArgs): Promise<SearchTableList>;
/** Stores this device's choice for one table: true indexes it whatever its default, false leaves it
 * out, null returns it to the default. The next index step backfills or purges it. */
export declare function setSearchTable(db: SqlDriver, args: SetSearchTableArgs): Promise<SearchTableList>;
/** Hosts may call at database open to fail early on incompatible SQLite.
 * No triggers, user rows or sync schema are changed by this capability probe. */
export declare function assertSearchSupport(db: SqlDriver): Promise<void>;
/** Reads that use the index call this inside their transaction. A replica the step has not
 * reached answers from an empty index instead of failing. Once the index is otherwise current,
 * a queue of at most one batch (a few local edits) is indexed here, so a read never misses an
 * edit that a host's next step would only catch after it; anything larger waits for the step. */
export declare function openSearchIndex(db: SqlDriver): Promise<void>;
/** Whether rows still wait for the index step, for reads that report it. */
export declare function searchIndexing(db: SqlDriver): Promise<boolean>;
/** Search only the local replica, as far as the index step has indexed it. Missing/skipped
 * remote tables are not queried; this never builds or drains the index. */
export declare function search(db: SqlDriver, args: SearchArgs): Promise<SearchHit[]>;
/** Ranked matches per search; more matches than this rank only the most recently indexed. */
export declare const SEARCH_RANKED_MATCHES = 2000;
