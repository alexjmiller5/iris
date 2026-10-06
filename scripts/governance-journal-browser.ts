// Synthetic browser fixture only. No service adapter or product approval button.
import { openApprovalJournal } from '../apps/web/src/lib/governance/approval-journal';
import type { PendingApproval, ApprovalScope } from '../apps/web/src/lib/governance/api';
const scope = { deploymentId: 'test-deployment', sessionId: 'test-session', principalId: 'test-user' };
const entry: PendingApproval = {
  version: 1, scope, target: { table: 'items', rowId: 'synthetic-row' },
  intent: { kind: 'selected_inverse', eventIds: ['event-1'] },
  revision: { updated_at: '2025-01-01T00:00:00.000Z', hub_at: null },
  changes: [{ column: 'quantity', before: { type: 'integer', value: '9223372036854775807' }, after: { type: 'null' } }],
  selectedEventIds: ['event-1'], request: { proposalId: 'proposal-1', expectedVersion: 'v1', previewToken: 'synthetic-preview', idempotencyKey: 'key-1' },
};
const databaseName = new URL(location.href).searchParams.get('database');
if (!databaseName?.startsWith('life-ui-governance-test-')) throw new Error('Synthetic database required');
const connections = new Map<string, Awaited<ReturnType<typeof openApprovalJournal>>>();
const harness = {
  entry,
  async open(id = 'default', boundScope: ApprovalScope = scope) {
    connections.set(id, await openApprovalJournal(boundScope, { databaseName }));
  },
  async load(id = 'default') { return connections.get(id)!.load(); },
  async retain(value: PendingApproval = entry, id = 'default') { await connections.get(id)!.retain(value); return 'retained'; },
  async resolve(value: PendingApproval = entry, id = 'default') { await connections.get(id)!.resolve(value); return 'resolved'; },
  close() { for (const journal of connections.values()) journal.close(); connections.clear(); },
  async corrupt(value: unknown) {
    const db = await new Promise<IDBDatabase>((resolve, reject) => { const r = indexedDB.open(databaseName!); r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
    try { await new Promise<void>((resolve, reject) => { const tx = db.transaction('pending', 'readwrite', { durability: 'strict' }); tx.objectStore('pending').put(value, JSON.stringify(Object.values(scope))); tx.oncomplete = () => resolve(); tx.onabort = () => reject(tx.error); }); } finally { db.close(); }
  },
  async remove() {
    harness.close();
    await new Promise<void>((resolve, reject) => { const r = indexedDB.deleteDatabase(databaseName!); r.onsuccess = () => resolve(); r.onerror = () => reject(r.error); r.onblocked = () => reject(new Error('Test database blocked')); });
  },
  async fault(kind: 'quota' | 'durability') {
    const transaction = IDBDatabase.prototype.transaction;
    const add = IDBObjectStore.prototype.add;
    try {
      if (kind === 'quota') IDBObjectStore.prototype.add = function () { throw new DOMException('Synthetic quota exhaustion', 'QuotaExceededError'); };
      else IDBDatabase.prototype.transaction = function (...args: Parameters<typeof transaction>) { const tx = transaction.apply(this, args); Object.defineProperty(tx, 'durability', { value: 'relaxed' }); return tx; };
      if (kind === 'durability') await openApprovalJournal(scope, { databaseName });
      else await harness.retain();
    } finally { IDBDatabase.prototype.transaction = transaction; IDBObjectStore.prototype.add = add; }
  },
  async retentionOrder() {
    const transaction = IDBDatabase.prototype.transaction;
    const events: string[] = [];
    try {
      IDBDatabase.prototype.transaction = function (...args: Parameters<typeof transaction>) { const tx = transaction.apply(this, args); tx.addEventListener('complete', () => events.push('complete')); return tx; };
      await harness.retain(); events.push('retained'); return events;
    } finally { IDBDatabase.prototype.transaction = transaction; }
  },
};
Object.assign(window, { journalHarness: harness });
