import { compileView, displayName, isReadOnlyTable, readCatalog, sync, syncStatus, validateRow, writeRow, readUsage, readNotifications, markNotificationsRead, notificationPresentation } from '../packages/core/client.js';
import type { Row, SqlDriver, Value, View, ServiceHub, NotificationFeed } from '../packages/core/index.d.ts';
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

async function dispatch(method: string, args: Record<string, unknown>) {
  switch (method) {
    case 'catalog': {
      const catalog = await readCatalog(db);
      return { ...catalog, tables: catalog.tables.map((table) => ({ ...table, readOnly: isReadOnlyTable(String(table.id), table) })) };
    }
    case 'rows': {
      const catalog = await readCatalog(db);
      const table = catalog.tables.find((t) => t.id === args.table);
      if (!table) throw new Error('Table is not in the catalog.');
      const view = compileView(args as View, catalog.properties);
      return (await db.all(view.sql, view.params)).map((record) => ({
        record, label: displayName(record, typeof table.display === 'string' ? table.display : null),
      }));
    }
    case 'write': return writeRow(db, args.table as string, args.patch as Row, {
      origin: 'life-ui',
      ...(typeof args.expectedUpdatedAt === 'string' ? { expectedUpdatedAt: args.expectedUpdatedAt } : {}),
    });
    case 'status': return syncStatus(db);
    case 'sync': return sync(db, hub(args.endpoint));
    case 'serviceUsage': return readUsage(hub(args.endpoint));
    case 'serviceNotifications': return readNotifications(hub(args.endpoint));
    case 'markNotificationsRead': return markNotificationsRead(hub(args.endpoint), args.selector as { ids?: string[]; through?: number });
    case 'notificationPresentation': return notificationPresentation(args.feed as unknown as NotificationFeed, args.baseline as number | null);
    case 'sample': await createSample(db); return null;
    default: throw new Error('Unknown workspace operation.');
  }
}

Object.assign(globalThis, {
  LifeCore: { validateRow },
  LifeNative: {
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
