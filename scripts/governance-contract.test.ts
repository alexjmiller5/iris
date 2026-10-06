import { afterEach, expect, test } from 'bun:test';
import { fresh, T0, T1 } from './governance-fixture';

const fixtures: Awaited<ReturnType<typeof fresh>>[] = [];
afterEach(() => { for (const fixture of fixtures.splice(0)) fixture.close(); });
async function setup() { const fixture = await fresh(); fixtures.push(fixture); return fixture; }

for (const field of ['updated_at', 'hub_at'] as const) {
  test(`a reviewed patch conflicts when only ${field} advanced`, async () => {
    const f = await setup();
    f.db.db.query(`UPDATE items SET ${field}=? WHERE id='a'`).run(T1);
    const before = f.state();
    const response = await f.patch();
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: 'revision_conflict' });
    expect(f.state()).toEqual(before);
  });
}

test('a selected-change inverse preserves unrelated edits and retained history', async () => {
  const f = await setup();
  // A hand-authored candidate, not a historical reconstruction algorithm.
  expect((await f.patch()).status).toBe(200);
  const retainedHistory = f.db.db.query('SELECT * FROM history ORDER BY id').all();
  expect(retainedHistory).toHaveLength(1);
  const next = new Date(Date.parse(f.row().updated_at) + 1).toISOString();
  f.db.db.query("UPDATE items SET name='Later title',updated_at=? WHERE id='a'").run(next);
  const eventsBefore = f.events();
  const response = await f.patch({ values: { status: 'open' }, expected_revision: { updated_at: next, hub_at: f.row().hub_at } });
  expect(response.status).toBe(200);
  const receipt = await response.json();
  expect(f.row()).toMatchObject({ name: 'Later title', status: 'open', qty: 1 });
  expect(receipt).toEqual({ id: 'a', revision: { updated_at: f.row().updated_at, hub_at: f.row().hub_at } });
  expect(f.db.db.query('SELECT * FROM history WHERE id=?').all(retainedHistory[0].id)).toEqual(retainedHistory);
  expect(f.db.db.query('SELECT col,old,new FROM history WHERE id<>?').all(retainedHistory[0].id)).toEqual([{ col: 'status', old: 'closed', new: 'open' }]);
  expect(f.events().slice(0, eventsBefore.length)).toEqual(eventsBefore);
  expect(f.events()).toHaveLength(eventsBefore.length + 1);
});

test('a successful retry is currently a conflict, never an idempotent approval receipt', async () => {
  const f = await setup();
  expect((await f.patch()).status).toBe(200);
  const committed = f.state();
  expect(f.history()).toEqual([{ col: 'status', old: 'open', new: 'closed' }]);
  expect(f.events()).toHaveLength(1);
  const retry = await f.patch();
  expect(retry.status).toBe(409);
  expect(await retry.json()).toEqual({ error: 'revision_conflict' });
  expect(f.state()).toEqual(committed);
});

test('an inverse invalid under the current catalog changes no row, history or event', async () => {
  const f = await setup();
  expect((await f.patch()).status).toBe(200);
  f.db.db.exec(`UPDATE catalog_properties SET options='[{"v":"closed"}]' WHERE col='status'`);
  const before = f.state();
  const response = await f.patch({ values: { status: 'open' }, expected_revision: { updated_at: f.row().updated_at, hub_at: f.row().hub_at } });
  expect(response.status).toBe(422);
  expect(await response.json()).toEqual({ error: 'validation_failed' });
  expect(f.state()).toEqual(before);
});

test('an enforced invariant rolls back the entire multi-field candidate', async () => {
  const f = await setup();
  f.db.db.exec("INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES ('positive','items','invariant',1,'SELECT id FROM changed WHERE qty < 0','positive quantity')");
  const before = f.state();
  const response = await f.patch({ values: { status: 'closed', qty: -1 } });
  expect(response.status).toBe(422);
  expect(f.state()).toEqual(before);
});

for (const field of ['updated_at', 'hub_at'] as const) {
  test(`a ${field} race after validation preserves the winning edit without patch side effects`, async () => {
    const f = await setup();
    const batch = f.db.batch.bind(f.db);
    let winner: ReturnType<typeof f.state> | undefined;
    f.db.batch = async (statements: unknown[]) => {
      if (!winner) {
        f.db.db.query(`UPDATE items SET name='Concurrent',${field}=? WHERE id='a'`).run(T1);
        winner = f.state();
      }
      return batch(statements);
    };
    expect((await f.patch()).status).toBe(409);
    if (!winner) throw new Error('Fixture never reached the committing batch');
    expect(f.state()).toEqual(winner);
  });
}

for (const unavailable of ['missing', 'tombstone'] as const) {
  test(`${unavailable} row cannot be restored through conditional field patch`, async () => {
    const f = await setup();
    f.db.db.exec(unavailable === 'missing' ? "DELETE FROM items WHERE id='a'" : `UPDATE items SET deleted_at='${T0}' WHERE id='a'`);
    const before = f.state();
    expect((await f.patch()).status).toBe(409);
    expect(f.state()).toEqual(before);
  });
}

test('claimed actor, origin and preview flags are not accepted patch capabilities', async () => {
  const f = await setup();
  const before = f.state();
  for (const extra of [{ actor: 'principal-other' }, { origin: 'agent' }, { pretend: true }]) {
    expect((await f.patch(extra)).status).toBe(400);
    expect(f.state()).toEqual(before);
  }
});

test('a read-only principal cannot commit', async () => {
  const f = await setup();
  const token = await f.token('tables:read:items');
  const before = f.state();
  expect((await f.patch({}, token)).status).toBe(403);
  expect(f.state()).toEqual(before);
});

test('an exact table writer gets only a revision receipt and revocation prevents another commit', async () => {
  const f = await setup();
  const token = await f.token('tables:write:items');
  const before = f.state();
  expect((await f.patch({ table: 'private_rows' }, token)).status).toBe(403);
  expect(f.state()).toEqual(before);
  const response = await f.patch({}, token);
  expect(response.status).toBe(200);
  const receipt = await response.json();
  expect(receipt).toEqual({ id: 'a', revision: { updated_at: f.row().updated_at, hub_at: f.row().hub_at } });
  f.auth.db.exec("UPDATE _tokens SET revoked_at='revoked'");
  const committed = f.state();
  expect((await f.patch({ values: { status: 'open' }, expected_revision: receipt.revision }, token)).status).toBe(403);
  expect(f.state()).toEqual(committed);
});
