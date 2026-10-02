import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import * as core from '../packages/core/client.js';

const root = resolve(import.meta.dir, '..');
test('vendored contract generates the exact Swift and TypeScript consumed by both hosts', async () => {
  const { generateContract } = await import('../packages/core/contract/generate-core-contract.ts');
  const contract = JSON.parse(await readFile(resolve(root, 'packages/core/contract/core.json'), 'utf8'));
  const output = generateContract(contract);
  expect(core.CORE_CONTRACT_HASH).toBe(output.hash);
  expect(await readFile(resolve(root, 'packages/core/contract.generated.ts'), 'utf8')).toBe(output.typescript);
  expect(await readFile(resolve(root, 'packages/LifeKit/Sources/LifeKit/Generated/CoreContract.generated.swift'), 'utf8')).toBe(output.swift);
});

test('native JSON dispatch uses the same generated methods and row results', async () => {
  const { Database } = await import('bun:sqlite');
  const { runInNewContext } = await import('node:vm');
  const db = new Database(':memory:');
  try {
    let finish: (reply: { value?: unknown; error?: string }) => void = () => {};
    const context = {
      LifeSql: {
        all: (sql: string, params: (string | number | null)[]) => db.query(sql).all(...params),
        run: (sql: string, params: (string | number | null)[]) => db.query(sql).run(...params).changes,
        begin: () => db.exec('BEGIN IMMEDIATE'), commit: () => db.exec('COMMIT'), rollback: () => db.exec('ROLLBACK'),
      },
      __lifeYield: (callback: () => void) => queueMicrotask(callback),
      __lifeFinish: (_id: number, json: string) => finish(JSON.parse(json)),
    };
    const script = await readFile(resolve(root, 'packages/LifeKit/Sources/LifeKit/Resources/life-core.js'), 'utf8');
    runInNewContext(script, context);
    const native = (context as typeof context & { LifeNative: { contractHash: string; request(id: number, method: string, json: string): void } }).LifeNative;
    expect(native.contractHash).toBe(core.CORE_CONTRACT_HASH);
    const request = (method: string, args: object = {}) => new Promise<unknown>((resolve, reject) => {
      finish = reply => reply.error ? reject(new Error(reply.error)) : resolve(reply.value);
      native.request(1, method, JSON.stringify(args));
    });
    await request('sample');
    const rows = await request('rows', { table: 'notes', filters: [{ column: 'title', op: 'contains', value: 'place' }], sort: [{ column: 'title', direction: 'desc' }], limit: 1 }) as core.WorkspaceRow[];
    expect(rows.map(row => row.label)).toEqual(['A place to start']);
    expect(await request('rows', { table: 'notes', filters: [{ column: 'id', op: 'eq', value: rows[0].record.id }] })).toEqual(rows);
    expect(await request('options', { table: 'notes', column: 'status' })).toEqual(['Draft', 'Ready']);
    await expect(request('toString')).rejects.toThrow('Unknown workspace operation');
    await expect(request('rows', { table: 'notes', offset: -1 })).rejects.toThrow('nonnegative');
  } finally { db.close(); }
});
