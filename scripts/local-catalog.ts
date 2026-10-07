import type { SqlDriver } from '../packages/core/index.d.ts';
import storage from '../packages/core/schema/catalog-log.json';
import { prepareLocalTable } from './local-views';

/** Explicit app-owned local/demo setup only; imported replicas sync operator DDL. */
export const prepareLocalCatalog = (db: SqlDriver) => prepareLocalTable(db, storage);
