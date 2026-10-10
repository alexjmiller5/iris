import type { SaveCatalogPropertyArgs, SaveCatalogRuleArgs } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
import { type Row, type Property } from './validate.ts';
/** Option chip colors: the Notion palette names, stored lowercase. */
export declare const OPTION_COLORS: readonly ["default", "gray", "brown", "orange", "yellow", "green", "blue", "purple", "pink", "red"];
type CatalogPropertyEdit = SaveCatalogPropertyArgs;
type CatalogRuleEdit = SaveCatalogRuleArgs;
/** Catalog changes use their own logged transaction; ordinary record writers
 * remain unable to edit metadata. Existing records are not silently rewritten. */
export declare function saveCatalogProperty(db: SqlDriver, value: CatalogPropertyEdit): Promise<Property>;
export declare function saveCatalogRule(db: SqlDriver, value: CatalogRuleEdit): Promise<Row>;
export {};
