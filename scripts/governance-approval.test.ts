import { createRequire } from 'node:module';
const webDependency = createRequire(new URL('../apps/web/package.json', import.meta.url)).resolve;
import { expect, test } from 'bun:test';
const { get } = await import(webDependency('svelte/store')) as typeof import('svelte/store');
const { createProposalReview: createModel } = await import(process.env.IRIS_TEST_PROPOSAL_REVIEW || '../apps/web/src/lib/governance/proposal-review') as typeof import('../apps/web/src/lib/governance/proposal-review');
import type { Preview, Proposal, ApprovalReceipt, ApprovalResult } from '../apps/web/src/lib/governance/contract';

const scope = { deploymentId: 'deployment-1', sessionId: 'session-1', principalId: 'user-1' };
function memoryJournal() { let entry: import('../apps/web/src/lib/governance/api').PendingApproval | null = null; return { load: async () => entry, retain: async (value: NonNullable<typeof entry>) => { entry = structuredClone(value); }, resolve: async (value: NonNullable<typeof entry>) => { if (JSON.stringify(value) !== JSON.stringify(entry)) throw new Error("Journal comparison failed"); entry = null; } }; }
const createProposalReview = (api: Parameters<typeof createModel>[0]) => createModel(api, memoryJournal(), scope);
const read = (value: Preview) => ({ kind: 'success' as const, value });
const success = (value: ApprovalReceipt): ApprovalResult => ({ kind: 'success', value });
const target = { table: 'items', rowId: 'a' };
const revision = { updated_at: '2025-01-01T00:00:00.000Z', hub_at: null };
const proposal: Proposal = {
  id: 'p', version: 'v1', target, intent: { kind: 'selected_inverse', eventIds: ['e1'] },
  changes: [{ column: 'status', before: { type: 'text', value: 'closed' }, after: { type: 'text', value: 'open' } }],
  baseRevision: revision, state: 'pending', proposedBy: { principalId: 'agent-1', kind: 'agent' },
  claimedOrigin: 'user-claim', createdAt: revision.updated_at, updatedAt: revision.updated_at,
};
const preview: Preview = { target, revision, changes: proposal.changes, selectedEventIds: ['e1'], conflicts: [], previewToken: 'opaque-token', expiresAt: '2099-01-01T00:00:00.000Z' };
const receipt: ApprovalReceipt = { operationId: 'op', proposalId: 'p', proposalVersion: 'v1', target, revision, historyEventIds: ['e2'], approvedBy: { principalId: 'user-1', kind: 'user' }, committedAt: revision.updated_at };
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(yes => { resolve = yes; }); return { promise, resolve }; }

test('approve forwards only exact proposal version, preview token and a retained idempotency key', async () => {
  const requests: object[] = [];
  const model = createProposalReview({
    previewProposal: async () => read(preview),
    approveProposal: async args => { requests.push(args); return success(receipt); },
  });
  model.setOnline(true);
  await model.open(proposal);
  await model.approve();
  expect(requests).toEqual([{ proposalId: 'p', expectedVersion: 'v1', previewToken: 'opaque-token', idempotencyKey: expect.any(String) }]);
  expect(get(model).receipt).toEqual(receipt);
  expect(get(model).proposal?.proposedBy).toEqual({ principalId: 'agent-1', kind: 'agent' });
  expect(get(model).receipt?.approvedBy).toEqual({ principalId: 'user-1', kind: 'user' });
});

test('a lost response retries the identical approval request without a new preview', async () => {
  const requests: object[] = []; let previews = 0;
  const model = createProposalReview({ previewProposal: async () => { previews++; return read(preview); }, approveProposal: async args => {
    requests.push(args); if (requests.length === 1) throw new Error('Connection lost'); return success(receipt);
  } });
  model.setOnline(true); await model.open(proposal); await model.approve();
  expect(get(model).error).toContain('unknown');
  await model.approve();
  expect(requests).toHaveLength(2);
  expect(requests[1]).toEqual(requests[0]);
  expect(previews).toBe(1);
  expect(get(model).receipt).toEqual(receipt);
});

test('offline or missing advertised approval operation cannot send an approval', async () => {
  let commits = 0;
  const model = createProposalReview({ previewProposal: async () => read(preview), approveProposal: async () => { commits++; return success(receipt); } });
  await model.open(proposal); await model.approve();
  expect(commits).toBe(0);
  expect(get(model).error).toContain('online');
  const unavailable = createProposalReview(null);
  unavailable.setOnline(true); await unavailable.open(proposal); await unavailable.approve();
  expect(get(unavailable).preview).toBeNull();
  expect(get(unavailable).error).toContain('unavailable');
});

test('same-column or missing-history conflicts stay visible and block approval', async () => {
  for (const code of ['later_column_change', 'history_unavailable'] as const) {
    let commits = 0;
    const model = createProposalReview({ previewProposal: async () => read({ ...preview, previewToken: null, conflicts: [{ code, column: 'status', eventIds: ['e1'], message: 'Review unavailable' }] }), approveProposal: async () => { commits++; return success(receipt); } });
    model.setOnline(true); await model.open(proposal); await model.approve();
    expect(get(model).preview?.conflicts[0]?.code).toBe(code);
    expect(commits).toBe(0);
  }
});

test('replacing the proposal version discards the prior preview and ignores its late reply', async () => {
  const old = deferred<Preview>();
  const model = createProposalReview({ previewProposal: args => args.expectedVersion === 'v1' ? old.promise.then(read) : Promise.resolve(read({ ...preview, previewToken: 'v2-token' })), approveProposal: async () => success(receipt) });
  const loading = model.open(proposal);
  await model.open({ ...proposal, version: 'v2' });
  old.resolve(preview); await loading;
  expect(get(model).proposal?.version).toBe('v2');
  expect(get(model).preview?.previewToken).toBe('v2-token');
});

test('changing session clears the review and ignores late approval results', async () => {
  const pending = deferred<ApprovalResult>();
  const model = createProposalReview({ previewProposal: async () => read(preview), approveProposal: () => pending.promise });
  model.setOnline(true); await model.open(proposal);
  const applying = model.approve(); await new Promise(resolve => setTimeout(resolve, 0)); model.reset(); pending.resolve(success(receipt)); await applying;
  expect(get(model)).toMatchObject({ proposal: null, preview: null, receipt: null, busy: false, unresolved: false });
});

test('double approval clicks send one request; core actor authority failures remain errors', async () => {
  let commits = 0; const pending = deferred<ApprovalResult>();
  const model = createProposalReview({ previewProposal: async () => read(preview), approveProposal: async () => { commits++; return pending.promise; } });
  model.setOnline(true); await model.open(proposal);
  const applying = model.approve(); await model.approve(); pending.resolve(success(receipt)); await applying;
  expect(commits).toBe(1);
  const denied = createProposalReview({ previewProposal: async () => read(preview), approveProposal: async () => { return { kind: 'error', code: 'permission_denied', resolution: 'unresolved', conflicts: [] };  } });
  denied.setOnline(true); await denied.open(proposal); await denied.approve();
  expect(get(denied).error).toBe('permission denied');
  expect(get(denied).receipt).toBeNull();
});

test('navigation while the durable retain is pending cannot dispatch under an obsolete review', async () => {
  let commits = 0;
  const saved = deferred<void>();
  const journal = memoryJournal();
  const retain = journal.retain;
  journal.retain = async entry => { await saved.promise; await retain(entry); };
  const model = createModel({ previewProposal: async () => read(preview), approveProposal: async () => { commits++; return success(receipt); } }, journal, scope);
  model.setOnline(true); await model.open(proposal);
  const approving = model.approve(); await new Promise(resolve => setTimeout(resolve, 0));
  model.reset(); saved.resolve(); await approving;
  expect(commits).toBe(0);
  expect((await journal.load())?.request.proposalId).toBe('p');
});

test('reopening restores the complete candidate binding and original retry without another preview', async () => {
  const journal = memoryJournal();
  const sent: object[] = [];
  const first = createModel({ previewProposal: async () => read(preview), approveProposal: async args => { sent.push(args); return { kind: 'transport_error', code: 'indeterminate' }; } }, journal, scope);
  first.setOnline(true); await first.open(proposal); await first.approve(); first.dispose();
  expect(await journal.load()).toMatchObject({ version: 1, scope, target, revision, changes: preview.changes, intent: proposal.intent, selectedEventIds: ['e1'], request: sent[0] });
  let previews = 0;
  const reopened = createModel({ previewProposal: async () => { previews++; return read(preview); }, approveProposal: async args => { sent.push(args); return success(receipt); } }, journal, scope);
  reopened.setOnline(true); await reopened.open({ ...proposal, version: 'v2' });
  expect(get(reopened).unresolved).toBe(true);
  await reopened.approve();
  expect(sent[1]).toEqual(sent[0]);
  expect(previews).toBe(0);
  expect(await journal.load()).toBeNull();
});

test('a different principal cannot read, replace or retry the retained approval', async () => {
  const journal = memoryJournal(); let commits = 0;
  const first = createModel({ previewProposal: async () => read(preview), approveProposal: async () => ({ kind: 'transport_error', code: 'indeterminate' }) }, journal, scope);
  first.setOnline(true); await first.open(proposal); await first.approve();
  const before = await journal.load();
  const other = createModel({ previewProposal: async () => read(preview), approveProposal: async () => { commits++; return success(receipt); } }, journal, { ...scope, principalId: 'user-other' });
  other.setOnline(true); await other.open(proposal); await other.approve();
  expect(commits).toBe(0);
  expect(await journal.load()).toEqual(before);
  expect(get(other).error).toContain('unavailable');
});

test('unavailable reads and purged mutation outcomes remove retained display content', async () => {
  const hidden = createModel({ previewProposal: async () => ({ kind: 'unavailable' }), approveProposal: async () => success(receipt) }, memoryJournal(), scope);
  await hidden.open(proposal);
  expect(get(hidden).proposal).toBeNull();
  const journal = memoryJournal();
  const purged = createModel({ previewProposal: async () => read(preview), approveProposal: async () => ({ kind: 'purged' }) }, journal, scope);
  purged.setOnline(true); await purged.open(proposal); await purged.approve();
  expect(get(purged)).toMatchObject({ purged: true, proposal: null, preview: null, receipt: null, conflicts: [] });
  expect(await journal.load()).toBeNull();
});

test('definitive stale approval invalidates its preview and cannot silently mint another request', async () => {
  let commits = 0;
  const model = createModel({ previewProposal: async () => read(preview), approveProposal: async () => { commits++; return { kind: 'error', code: 'proposal_changed', resolution: 'not_committed', conflicts: [] }; } }, memoryJournal(), scope);
  model.setOnline(true); await model.open(proposal); await model.approve(); await model.approve();
  expect(commits).toBe(1);
  expect(get(model).preview).toBeNull();
  expect(get(model).error).toBe('proposal changed');
});

test('a completed old approval clears its journal without refreshing a new session', async () => {
  for (const transition of ['reset', 'dispose'] as const) {
    let refreshed = 0; const result = deferred<ApprovalResult>(); const journal = memoryJournal();
    const model = createModel({ previewProposal: async () => read(preview), approveProposal: () => result.promise }, journal, scope, () => { refreshed++; });
    model.setOnline(true); await model.open(proposal);
    const applying = model.approve(); await new Promise(resolve => setTimeout(resolve, 0));
    model[transition](); result.resolve(success(receipt)); await applying;
    expect(refreshed).toBe(0); expect(await journal.load()).toBeNull();
  }
});

test('a review waiting for journal restore cannot reopen after navigation', async () => {
  const loaded = deferred<null>(); let previews = 0;
  const model = createModel({ previewProposal: async () => { previews++; return read(preview); }, approveProposal: async () => success(receipt) }, { ...memoryJournal(), load: () => loaded.promise }, scope);
  const opening = model.open(proposal); model.reset(); loaded.resolve(null); await opening;
  expect(previews).toBe(0); expect(get(model).proposal).toBeNull();
});

test('failed retention disables replacement attempts and sends nothing', async () => {
  let commits = 0; let retains = 0;
  const model = createModel({ previewProposal: async () => read(preview), approveProposal: async () => { commits++; return success(receipt); } }, { ...memoryJournal(), retain: async () => { retains++; throw new Error('Existing competing entry'); } }, scope);
  model.setOnline(true); await model.open(proposal); await model.approve(); await model.approve();
  expect(commits).toBe(0); expect(retains).toBe(1);
});

// These are normalized API results. HTTP/status validation belongs to the future
// core adapter, which remains unavailable. Exercise the real model and its journal
// protocol so a rejected retry cannot erase an earlier uncertain approval.
async function retryAfterLostResponse(result: ApprovalResult) {
  const journal = memoryJournal();
  const requests: object[] = [];
  let previews = 0;
  const api = {
    previewProposal: async () => { previews++; return read(preview); },
    approveProposal: async (args: object): Promise<ApprovalResult> => {
      requests.push(structuredClone(args));
      if (requests.length === 1) return { kind: 'transport_error', code: 'indeterminate' };
      return requests.length === 2 ? result : success(receipt);
    },
  };
  const model = createModel(api, journal, scope);
  model.setOnline(true); await model.open(proposal); await model.approve();
  const original = structuredClone(await journal.load());
  await model.approve();
  expect(await journal.load()).toEqual(original);
  expect(get(model)).toMatchObject({ unresolved: true, preview: null, receipt: null });
  const unresolved = get(model);
  await model.open({ ...proposal, version: 'replacement-version' });
  expect(previews).toBe(1);
  model.dispose();
  const reopened = createModel(api, journal, scope);
  reopened.setOnline(true); await reopened.ready; await reopened.approve();
  expect(requests).toEqual([original!.request, original!.request, original!.request]);
  expect(await journal.load()).toBeNull();
  expect(get(reopened).receipt).toEqual(receipt);
  reopened.dispose();
  return unresolved;
}

test.each([
  ['authentication retry (401)', 'permission_denied'],
  ['authority retry (403)', 'permission_denied'],
  ['usage-cap retry (429)', 'unavailable'],
  ['missing resource', 'unavailable'],
  ['changed proposal', 'proposal_changed'],
  ['changed row', 'revision_changed'],
  ['incomplete history', 'history_unavailable'],
  ['validation failure', 'validation_failed'],
  ['expired preview', 'expired_preview'],
  ['idempotency conflict', 'idempotency_conflict'],
] as const)('%s with unresolved resolution preserves the exact request through reopen', async (_label, code) => {
  const state = await retryAfterLostResponse({ kind: 'error', code, resolution: 'unresolved', conflicts: [] });
  expect(state.contentUnavailable).toBe(code === 'permission_denied' || code === 'unavailable');
});

test.each([
  ['missing', {}],
  ['null', { resolution: null }],
  ['unknown', { resolution: 'settled' }],
  ['boolean', { resolution: true }],
  ['object', { resolution: { kind: 'not_committed' } }],
] as const)('%s resolution cannot settle or reinterpret an uncertain approval', async (_label, fields) => {
  const state = await retryAfterLostResponse({ kind: 'error', code: 'revision_changed', conflicts: [], ...fields } as unknown as ApprovalResult);
  expect(state.error).toContain('unknown');
});

test('an offline retry retains an earlier uncertain approval through reopen', async () => {
  await retryAfterLostResponse({ kind: 'transport_error', code: 'offline' });
});

test.each([
  ['read unavailable', { kind: 'unavailable' }],
  ['unknown kind', { kind: 'settled' }],
  ['null', null],
  ['undefined', undefined],
  ['primitive', 'success'],
  ['purged with payload', { kind: 'purged', value: receipt }],
  ['success without receipt', { kind: 'success' }],
  ['success with incomplete receipt', { kind: 'success', value: { operationId: 'op' } }],
  ['success with resolution', { ...success(receipt), resolution: 'not_committed' }],
  ['error without conflicts', { kind: 'error', code: 'revision_changed', resolution: 'not_committed' }],
  ['error with unknown code', { kind: 'error', code: 'gone', resolution: 'not_committed', conflicts: [] }],
  ['error with malformed conflict', { kind: 'error', code: 'revision_changed', resolution: 'not_committed', conflicts: [{}] }],
] as const)('%s response preserves the journal as indeterminate', async (_label, result) => {
  const state = await retryAfterLostResponse(result as unknown as ApprovalResult);
  expect(state.error).toContain('unknown');
});

test.each(['proposal_changed', 'revision_changed', 'history_unavailable', 'validation_failed', 'unavailable', 'expired_preview'] as const)(
  'durable not_committed %s settles only the original request and requires fresh review', async code => {
    const journal = memoryJournal(); const requests: { idempotencyKey: string }[] = [];
    const model = createModel({ previewProposal: async () => read(preview), approveProposal: async args => {
      requests.push(args); return { kind: 'error', code, resolution: 'not_committed', conflicts: [] };
    } }, journal, scope);
    model.setOnline(true); await model.open(proposal); await model.approve();
    expect(await journal.load()).toBeNull();
    expect(get(model)).toMatchObject({ unresolved: false, preview: null, receipt: null });
    await model.approve(); expect(requests).toHaveLength(1);
    await model.open({ ...proposal, version: 'v2' }); await model.approve();
    expect(requests).toHaveLength(2);
    expect(requests[1].idempotencyKey).not.toBe(requests[0].idempotencyKey);
    model.dispose();
  }
);

test.each(['reset', 'dispose'] as const)('late unresolved denial after %s preserves its original journal', async transition => {
  const response = deferred<ApprovalResult>(); const journal = memoryJournal();
  const model = createModel({ previewProposal: async () => read(preview), approveProposal: () => response.promise }, journal, scope);
  model.setOnline(true); await model.open(proposal);
  const applying = model.approve(); await new Promise(resolve => setTimeout(resolve, 0));
  const original = structuredClone(await journal.load());
  model[transition]();
  response.resolve({ kind: 'error', code: 'permission_denied', resolution: 'unresolved', conflicts: [] });
  await applying;
  expect(await journal.load()).toEqual(original);
  expect(get(model).receipt).toBeNull();
});

test.each([
  ['proposal', { ...receipt, proposalId: 'other-proposal' }],
  ['version', { ...receipt, proposalVersion: 'other-version' }],
  ['table', { ...receipt, target: { ...target, table: 'other-items' } }],
  ['row', { ...receipt, target: { ...target, rowId: 'other-row' } }],
] as const)('a receipt for another %s cannot settle the captured approval', async (_label, other) => {
  const state = await retryAfterLostResponse(success(other));
  expect(state.error).toContain('unknown');
});

test.each(['reset', 'dispose'] as const)('a matching replay after %s settles its captured request with an older revision and empty history', async transition => {
  const response = deferred<ApprovalResult>(); const journal = memoryJournal();
  let refreshed = 0;
  const model = createModel({ previewProposal: async () => read(preview), approveProposal: () => response.promise }, journal, scope, () => { refreshed++; });
  model.setOnline(true); await model.open(proposal);
  const applying = model.approve(); await new Promise(resolve => setTimeout(resolve, 0));
  const original = structuredClone(await journal.load());
  const resolved: unknown[] = [];
  const resolve = journal.resolve;
  journal.resolve = async entry => { resolved.push(structuredClone(entry)); await resolve(entry); };
  model[transition]();
  response.resolve(success({ ...receipt, revision: { updated_at: '2024-01-01T00:00:00.000Z', hub_at: null }, historyEventIds: [] }));
  await applying;
  expect(resolved).toEqual([original]);
  expect(await journal.load()).toBeNull();
  expect(refreshed).toBe(0);
});

test.each([
  { kind: 'error', code: 'revision_changed', resolution: 'unresolved', conflicts: [{ code: 'revision_changed', column: 'status', eventIds: ['e1'], message: 'Earlier attempt conflict' }] },
  { kind: 'error', code: 'permission_denied', resolution: 'unresolved', conflicts: [] },
] satisfies ApprovalResult[])('a successful same-instance retry clears prior $code feedback', async rejection => {
  const requests: object[] = []; const journal = memoryJournal();
  const model = createModel({ previewProposal: async () => read(preview), approveProposal: async args => {
    requests.push(args); return requests.length === 1 ? structuredClone(rejection) : success(receipt);
  } }, journal, scope);
  model.setOnline(true); await model.open(proposal); await model.approve();
  expect(get(model).unresolved).toBe(true);
  await model.approve();
  expect(requests[1]).toEqual(requests[0]);
  expect(get(model)).toMatchObject({ receipt, conflicts: [], contentUnavailable: false, unresolved: false, error: '' });
  expect(await journal.load()).toBeNull();
});
