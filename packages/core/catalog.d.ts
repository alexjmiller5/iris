import type { SqlDriver } from './driver.ts';
import { type Property, type Row } from './validate.ts';
export declare function decodeProperty(row: Row): Property;
export declare function readCatalog(db: SqlDriver): Promise<{
    tables: Row[];
    properties: Property[];
    rules: Row[];
}>;
