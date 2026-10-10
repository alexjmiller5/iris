import type { Catalog, CatalogRevision } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
import { type Property, type Row } from './validate.ts';
export declare function decodeProperty(row: Row): Property;
/** tables limits the read to those tables' entries, properties and rules, for operations
 * that involve only them; the whole catalog is about a megabyte on a large estate. */
export declare function readCatalog(db: SqlDriver, tables?: readonly string[]): Promise<Catalog>;
/** Changes whenever a catalog row is added, edited, retired, pulled or removed. Every soma
 * write moves updated_at (its timestamp trigger stamps raw edits too); the length of the whole
 * row also separates edits that keep it, such as two in one millisecond. Hosts compare it
 * before re-reading the whole catalog. */
export declare function catalogRevision(db: SqlDriver): Promise<CatalogRevision>;
/** The SQL expression behind catalogRevision, so callers can compare it inside SQLite. */
export declare function catalogRevisionSQL(db: SqlDriver): Promise<string>;
/** 64-bit FNV-1a style digest for cache keys; never a security boundary. */
export declare function fingerprint(text: string): string;
