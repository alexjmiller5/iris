import { createRequire } from 'node:module';
const webDependency = createRequire(new URL('../apps/web/package.json', import.meta.url)).resolve;
import { expect, test } from 'bun:test';
const { get } = await import(webDependency('svelte/store')) as typeof import('svelte/store');
const { createProposalReview: createModel } = await import(process.env.LIFE_UI_TEST_PROPOSAL_REVIEW || '../apps/web/src/lib/governance/proposal-review') as typeof import('../apps/web/src/lib/governance/proposal-review');
import type { Preview, Proposal, ApprovalReceipt, ApprovalResult } from '../apps/web/src/lib/governance/contract';

const scope = { deploymentId: 'deployment-1', sessionId: 'session-1', principalId: 'user-1' };
function memoryJournal() { let entry: import('../apps/web/src/lib/governance/api').PendingApproval | null = null; return { load: async () => entry, retain: async (value: NonNullable<typeof entry>) => { entry = structuredClone(value); }, resolve: async () => { entry = null; } }; }
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
  const denied = createProposalReview({ previewProposal: async () => read(preview), approveProposal: async () => { return { kind: 'error', code: 'permission_denied', conflicts: [] };  } });
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
  const model = createModel({ previewProposal: async () => read(preview), approveProposal: async () => { commits++; return { kind: 'error', code: 'proposal_changed', conflicts: [] }; } }, memoryJournal(), scope);
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
