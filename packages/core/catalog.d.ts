import type { Catalog } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
import { type Property, type Row } from './validate.ts';
export declare function decodeProperty(row: Row): Property;
export declare function readCatalog(db: SqlDriver): Promise<Catalog>;
