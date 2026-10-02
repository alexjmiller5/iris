import { CORE_CONTRACT_HASH, createCoreHandlers, validateRow } from '../packages/core/client.js';
import type { CoreArgs, CoreMethod, CoreResult, Row, SqlDriver, Value, ServiceHub } from '../packages/core/index.d.ts';
import { createSample } from './native-sample';

declare const LifeSql: {
  all(sql: string, params: Value[]): Row[];
  run(sql: string, params: Value[]): number;
  begin(): void;
  commit(): void;
  rollback(): void;
};
declare function __lifeYield(callback: () => void): void;
declare function __lifePost(route: string, body: string, callback: (json: string) => void): void;
declare function __lifeGet(route: string, callback: (json: string) => void): void;
declare function __lifeFinish(id: number, json: string): void;

// The Swift facade queues whole requests, including every awaited callback.
// JSC has no browser event loop: the host schedules a real main-actor turn.
const turn = () => new Promise<void>((resolve) => __lifeYield(resolve));
const db: SqlDriver = {
  async all(sql, params = []) { await turn(); return LifeSql.all(sql, params); },
  async run(sql, params = []) { await turn(); return LifeSql.run(sql, params); },
  async transaction(body) {
    LifeSql.begin();
    try {
      const result = await body();
      LifeSql.commit();
      return result;
    } catch (error) {
      LifeSql.rollback();
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
    get: (route) => new Promise((resolve, reject) => __lifeGet(route, reply(resolve, reject))),
    post: (route, body) => new Promise((resolve, reject) => __lifePost(route, JSON.stringify(body), reply(resolve, reject))),
  };
}

const handlers = createCoreHandlers(db, hub, 'life-ui');

function invoke<M extends CoreMethod>(method: M, args: CoreArgs<M>): CoreResult<M> | Promise<CoreResult<M>> {
  return handlers[method](args);
}

async function dispatch(method: string, args: unknown) {
  if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error('Invalid workspace arguments.');
  if (method === 'sample') { await createSample(db); return null; }
  if (!Object.hasOwn(handlers, method)) throw new Error('Unknown workspace operation.');
  // The sole untyped JSON boundary. Core functions retain runtime validation.
  return invoke(method as CoreMethod, args as CoreArgs<CoreMethod>);
}

Object.assign(globalThis, {
  LifeCore: { validateRow },
  LifeNative: {
    contractHash: CORE_CONTRACT_HASH,
    async request(id: number, method: string, json: string) {
      try { __lifeFinish(id, JSON.stringify({ value: await dispatch(method, JSON.parse(json)) })); }
      catch (error) {
        __lifeFinish(id, JSON.stringify({
          error: error instanceof Error ? error.message : 'Workspace operation failed.',
          violations: error && typeof error === 'object' && 'violations' in error ? error.violations : [],
        }));
      }
    },
  },
});
