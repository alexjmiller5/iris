import { createRequire } from 'node:module';
const webDependency = createRequire(new URL('../apps/web/package.json', import.meta.url)).resolve;
// Deterministic DOM boundary checks. This is not real-browser storage/interaction evidence.
// bun --conditions=browser scripts/check-governance-panel-dom.ts
import { strict as assert } from 'node:assert';
const { Window } = await import(webDependency('happy-dom')) as typeof import('happy-dom');
import { plugin } from 'bun';
const { compile } = await import(webDependency('svelte/compiler')) as typeof import('svelte/compiler');
import type { GovernanceAPI } from '../apps/web/src/lib/governance/api';
import type { ReadResult, Preview } from '../apps/web/src/lib/governance/contract';
const window = new Window();
for (const name of ['window', 'document', 'navigator', 'HTMLElement', 'Element', 'Node', 'Text', 'Comment', 'Event', 'MouseEvent', 'CustomEvent', 'getComputedStyle', 'requestAnimationFrame', 'cancelAnimationFrame']) Object.defineProperty(globalThis, name, { value: name === 'window' ? window : (window as any)[name], configurable: true });
plugin({ name: 'governance-dom', setup(build) { build.onLoad({ filter: /\.svelte$/ }, async ({ path }) => ({ contents: compile(await Bun.file(path).text(), { filename: path, generate: 'client' }).js.code, loader: 'js' })); } });
const { mount, unmount, tick } = await import(webDependency('svelte')) as typeof import('svelte');
const { default: Panel } = await import('../apps/web/src/lib/governance/GovernancePanel.svelte');
const scope = { deploymentId: 'test-deployment', sessionId: 'test-session', principalId: 'test-user' };
const target = { table: 'items', rowId: 'synthetic-row' };
const revision = { updated_at: '2025-01-01T00:00:00.000Z', hub_at: null };
const changes = [{ column: 'quantity', before: { type: 'text' as const, value: 'cached-secret-before' }, after: { type: 'text' as const, value: 'cached-secret-after' } }];
const preview: Preview = { target, revision, changes, selectedEventIds: ['e1'], conflicts: [], previewToken: 'synthetic-preview', expiresAt: null };
const deferred = <T>() => { let resolve!: (value: T) => void; const promise = new Promise<T>(yes => { resolve = yes; }); return { promise, resolve }; };
const settle = async () => { await new Promise(resolve => setTimeout(resolve, 0)); await tick(); };
const host = document.createElement('div'); document.body.append(host);
let current: ReturnType<typeof mount> | undefined;
function button(text: string) { const found = [...host.querySelectorAll('button')].find(el => el.textContent?.includes(text)); assert.ok(found, text); return found; }
const late = deferred<ReadResult<Preview>>();
const api = {
  historyEvents: async () => ({ kind: 'success', value: { events: [{ id: 'e1', operationId: 'op', target, ...changes[0], occurredAt: revision.updated_at, actor: null, claimedOrigin: null, reversible: true, unavailableReason: null }], nextCursor: null } }),
  listProposals: async () => ({ kind: 'success', value: { proposals: [{ id: 'p1', version: 'v1', target, intent: { kind: 'patch', changes: [{ column: 'quantity', after: changes[0]!.after }] }, changes, baseRevision: revision, state: 'pending', proposedBy: { principalId: 'agent-1', kind: 'agent' }, claimedOrigin: 'claimed-not-verified', createdAt: revision.updated_at, updatedAt: revision.updated_at }], nextCursor: null } }),
  previewChanges: () => late.promise,
  previewProposal: async () => ({ kind: 'success', value: preview }),
} as unknown as GovernanceAPI;
try {
  current = mount(Panel, { target: host, props: { api: null, journal: null, scope, target, online: true } }); await settle();
  assert.equal(host.querySelectorAll('button').length, 0); console.log('PASS null API mounts without actions');
  await unmount(current);
  current = mount(Panel, { target: host, props: { api, journal: null, scope, target, online: true } }); await settle();
  const checkbox = host.querySelector('input')!; checkbox.checked = true; checkbox.dispatchEvent(new Event('change', { bubbles: true })); await settle();
  button('Preview selected changes').click(); await settle();
  button('Review proposal').click(); await settle();
  assert.equal(button('Approve online').disabled, true); console.log('PASS unavailable journal cannot activate approval');
  // Authority loss invalidates all current data and the in-flight historical preview.
  api.previewProposal = async () => ({ kind: 'unavailable' }); button('Review proposal').click(); await settle();
  assert.ok(!host.textContent?.includes('cached-secret')); assert.ok(!host.textContent?.includes('claimed-not-verified'));
  console.log('PASS authority loss removes all displayed caches');
  // Fresh content and preview B must survive an obsolete unavailable response A.
  button('Load more history').click(); await settle();
  api.previewChanges = async () => ({ kind: 'success', value: preview });
  const fresh = host.querySelector('input')!; fresh.checked = true; fresh.dispatchEvent(new Event('change', { bubbles: true })); await settle();
  button('Preview selected changes').click(); await settle();
  assert.ok(host.querySelector('table'));
  late.resolve({ kind: 'unavailable' }); await settle();
  assert.ok(host.querySelector('table')); assert.ok(host.textContent?.includes('cached-secret'));
  console.log('PASS late unavailable preview cannot invalidate a newer accepted preview');
} finally { if (current) await unmount(current); await window.happyDOM.abort(); }
