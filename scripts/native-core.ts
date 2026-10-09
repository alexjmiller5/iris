import { prepareLocalCatalog } from './local-catalog';
import { CORE_CONTRACT_HASH, createCoreHandlers, validateRow } from '../packages/core/client.js';
import type { BackupFiles, CoreArgs, CoreMethod, CoreResult, Row, SqlDriver, Value, ServiceHub, SqlReadStatement, SqlReadContext } from '../packages/core/index.d.ts';
import { createSample } from './native-sample';
import { prepareLocalViews, prepareLocalPins } from './local-views';

declare const IrisSql: {
  all(sql: string, params: Value[]): Row[];
  run(sql: string, params: Value[]): number;
  begin(): void;
  commit(): void;
  rollback(): void;
  readDependencies?(statements: readonly SqlReadStatement[], context: SqlReadContext): { tables: string[] } | null;
};
declare function __irisYield(callback: () => void): void;
declare function __irisPost(route: string, body: string, callback: (json: string) => void): void;
declare function __irisGet(route: string, callback: (json: string) => void): void;
// Optional: hosts from before sync progress lack it.
declare const __irisSyncProgress: ((json: string) => void) | undefined;
declare function __irisFinish(id: number, json: string): void;
// Backup files: the host opens paths it supplied, inflates gzip and decodes UTF-8.
declare function __irisDumpOpen(file: string): number;
declare function __irisDumpRead(id: number): string | null;
declare function __irisDumpCreate(file: string): number;
declare function __irisDumpWrite(id: number, text: string): void;
declare function __irisDumpClose(id: number): void;

// The Swift facade owns whole database operations. HTTP awaits yield ownership
// only outside transactions; their callbacks resume after foreground work.
// JSC has no browser event loop: the host schedules a real main-actor turn.
const turn = () => new Promise<void>((resolve) => __irisYield(resolve));
const db: SqlDriver = {
  // The Swift bridge is installed after this bundle evaluates. Discover the
  // optional capability at use time; older hosts retain core's global fallback.
  get readDependencies() {
    if (typeof IrisSql === 'undefined' || typeof IrisSql.readDependencies !== 'function') return undefined;
    return async (statements: readonly SqlReadStatement[], context: SqlReadContext) => {
      await turn();
      return IrisSql.readDependencies!(statements, context);
    };
  },
  async all(sql, params = []) { await turn(); return IrisSql.all(sql, params); },
  async run(sql, params = []) { await turn(); return IrisSql.run(sql, params); },
  async transaction(body) {
    IrisSql.begin();
    try {
      const result = await body();
      IrisSql.commit();
      return result;
    } catch (error) {
      IrisSql.rollback();
      throw error;
    }
  },
};

function hub(endpoint: unknown): ServiceHub {
  const reply = (resolve: (value: { data: unknown; date?: string }) => void, reject: (error: Error) => void) => (json: string) => {
    try {
      const value = JSON.parse(json);
      if (value.error) reject(new Error(value.error));
      else resolve(value);
    } catch { reject(new Error('Invalid native transport response.')); }
  };
  return {
    endpoint: String(endpoint),
    get: (route) => new Promise((resolve, reject) => __irisGet(route, reply(resolve, reject))),
    post: (route, body) => new Promise((resolve, reject) => __irisPost(route, JSON.stringify(body), reply(resolve, reject))),
    progress: (state) => { if (typeof __irisSyncProgress === 'function') __irisSyncProgress(JSON.stringify(state)); },
  };
}

const files: BackupFiles = {
  open(file) {
    let id: number | undefined;
    return {
      async read() {
        await turn();
        id ??= __irisDumpOpen(file);
        return __irisDumpRead(id);
      },
    };
  },
  create(file) {
    let id: number | undefined;
    return {
      async write(text) {
        await turn();
        id ??= __irisDumpCreate(file);
        __irisDumpWrite(id, text);
      },
      async close() {
        id ??= __irisDumpCreate(file);
        __irisDumpClose(id);
      },
    };
  },
};

const handlers = createCoreHandlers(db, hub, 'iris', null, files);

function invoke<M extends CoreMethod>(method: M, args: CoreArgs<M>): CoreResult<M> | Promise<CoreResult<M>> {
  return handlers[method](args);
}

async function dispatch(method: string, args: unknown) {
  if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error('Invalid workspace arguments.');
  if (method === 'prepareLocalPins') return prepareLocalPins(db);
  if (method === 'prepareLocalCatalog') return prepareLocalCatalog(db);
  if (method === 'prepareLocalViews') return prepareLocalViews(db);
  if (method === 'sample') { await createSample(db); return null; }
  if (!Object.hasOwn(handlers, method)) throw new Error('Unknown workspace operation.');
  // The sole untyped JSON boundary. Core functions retain runtime validation.
  return invoke(method as CoreMethod, args as CoreArgs<CoreMethod>);
}

Object.assign(globalThis, {
  IrisCore: { validateRow },
  IrisNative: {
    contractHash: CORE_CONTRACT_HASH,
    async request(id: number, method: string, json: string) {
      try { __irisFinish(id, JSON.stringify({ value: await dispatch(method, JSON.parse(json)) })); }
      catch (error) {
        __irisFinish(id, JSON.stringify({
          error: error instanceof Error ? error.message : 'Workspace operation failed.',
          violations: error && typeof error === 'object' && 'violations' in error ? error.violations : [],
        }));
      }
    },
  },
});
