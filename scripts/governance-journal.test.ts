import { expect, test } from 'bun:test';
const { decodePendingApproval, encodePendingApproval, openApprovalJournal } = await import(process.env.LIFE_UI_TEST_APPROVAL_JOURNAL || '../apps/web/src/lib/governance/approval-journal') as typeof import('../apps/web/src/lib/governance/approval-journal');
import type { PendingApproval } from '../apps/web/src/lib/governance/api';

const scope = { deploymentId: 'deployment-1', sessionId: 'session-1', principalId: 'user-1' };
const entry: PendingApproval = {
  version: 1, scope, target: { table: 'items', rowId: 'a' },
  intent: { kind: 'selected_inverse', eventIds: ['event-1'] },
  revision: { updated_at: '2025-01-01T00:00:00.000Z', hub_at: null },
  changes: [{ column: 'quantity', before: { type: 'integer', value: '9223372036854775807' }, after: { type: 'null' } }],
  selectedEventIds: ['event-1'], request: { proposalId: 'p', expectedVersion: 'v1', previewToken: 'opaque', idempotencyKey: 'key-1' },
};

test('journal bytes retain complete binding and lossless typed candidate', () => {
  const bytes = encodePendingApproval(entry, scope);
  expect(decodePendingApproval(bytes, scope)).toEqual(entry);
  expect(encodePendingApproval(decodePendingApproval(bytes, scope), scope)).toBe(bytes);
});

for (const field of ['deploymentId', 'sessionId', 'principalId'] as const) test(`a changed ${field} cannot adopt the old pending entry`, () => {
  expect(() => decodePendingApproval(JSON.stringify(entry), { ...scope, [field]: 'different' })).toThrow();
});

for (const change of [
  { version: 2 }, { unexpected: 'field' }, { changes: [] },
  { request: { ...entry.request, previewToken: null } },
  { request: { 'expectedVersion,idempotencyKey,previewToken,proposalId': 'not four fields' } },
  { changes: [{ column: 'quantity', before: { type: 'integer', value: 9223372036854775807 }, after: { type: 'null' } }] },
  { changes: [{ column: 'quantity', before: { type: 'future', value: 'x' }, after: { type: 'null' } }] },
  { intent: { kind: 'selected_inverse', eventIds: ['event-1', 'event-1'] } },
]) test('corrupt or unknown journal shape fails closed: ' + JSON.stringify(change), () => {
  expect(() => decodePendingApproval(JSON.stringify({ ...entry, ...change }), scope)).toThrow();
});

test('invalid JSON and unavailable IndexedDB never become an empty journal', async () => {
  expect(() => decodePendingApproval('{broken', scope)).toThrow();
  await expect(openApprovalJournal(scope, { indexedDB: undefined })).rejects.toThrow('unavailable');
});
