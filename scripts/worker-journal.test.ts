import { expect, test } from 'bun:test';
import { createWorkspaceAdmission } from '../apps/web/src/lib/workspace-admission';
import type { WorkerJournalResource } from '../apps/web/src/lib/governance/worker-journal';
const { createWorkerJournalHost } = (await import(
	process.env.IRIS_TEST_WORKER_JOURNAL || '../apps/web/src/lib/governance/worker-journal'
)) as typeof import('../apps/web/src/lib/governance/worker-journal');
const { openJournalProxy } = (await import(
	process.env.IRIS_TEST_JOURNAL_PROXY || '../apps/web/src/lib/governance/journal-proxy'
)) as typeof import('../apps/web/src/lib/governance/journal-proxy');
import type { JournalRequest } from '../apps/web/src/lib/governance/journal-protocol';
import type { PendingApproval } from '../apps/web/src/lib/governance/api';
import type { PendingChangeset } from '../apps/web/src/lib/governance/changeset-journal';
import type { EncryptedWorkspaceRecord } from '../apps/web/src/lib/workspace-records';
const scope = { deploymentId: 'deployment-1', sessionId: 'session-1', principalId: 'principal-1' };
const governance = {
	...scope,
	protocol: 'selected-inverse-proposals-v1',
	principal: { kind: 'user', principalId: scope.principalId },
	authority: { propose: true, approve: true },
	limits: {
		maxSelectedEvents: 100,
		maxChangedColumns: 64,
		maxRequestBytes: 65536,
		maxPageSize: 100,
		previewTtlSeconds: 300
	}
};
// Capabilities identify their principal through the canonical principal object, not a top-level field.
delete (governance as Partial<typeof governance>).principalId;
const changesets = {
	deploymentId: scope.deploymentId,
	sessionId: scope.sessionId,
	protocol: 'bounded-changeset-proposals-v1',
	principal: { kind: 'user', principalId: scope.principalId },
	authority: { propose: true, approve: true },
	limits: {
		maxOperations: 20,
		maxTables: 10,
		maxBytes: 65536,
		maxReadSets: 10,
		maxMembershipRows: 100,
		maxReadRows: 100,
		previewTtlSeconds: 300
	}
};
const approval: PendingApproval = {
	version: 1,
	scope,
	target: { table: 'items', rowId: 'row-1' },
	intent: { kind: 'selected_inverse', eventIds: ['event-1'] },
	revision: { updated_at: '2030-01-01T00:00:00.000Z', hub_at: null },
	changes: [
		{
			column: 'quantity',
			before: { type: 'integer', value: '9223372036854775807' },
			after: { type: 'null' }
		}
	],
	selectedEventIds: ['event-1'],
	request: {
		proposalId: 'proposal-1',
		expectedVersion: 'version-1',
		previewToken: 'synthetic-preview',
		idempotencyKey: 'uncertain-key'
	}
};
const change: PendingChangeset = {
	version: 1,
	scope: { ...scope, endpoint: 'https://example.test' },
	proposal: {
		id: 'proposal-1',
		version: 'version-1',
		state: 'pending',
		input: {
			operations: [
				{
					kind: 'create',
					table: 'items',
					id: 'row-1',
					expected_revision: null,
					values: { label: 'synthetic' }
				}
			],
			reads: []
		},
		changes: [
			{ table: 'items', id: 'row-1', kind: 'create', before: null, after: { label: 'synthetic' } }
		],
		dependencies: 'digest',
		proposedBy: { kind: 'agent', principalId: 'agent-1' },
		claimedOrigin: null,
		createdAt: '2030-01-01T00:00:00.000Z',
		updatedAt: '2030-01-01T00:00:00.000Z'
	},
	request: { ...approval.request }
};
async function fixture(beforeOpen?: () => Promise<void>, beforeLoad?: () => Promise<void>) {
	let revision = 0;
	const values = new Map<string, EncryptedWorkspaceRecord>();
	const wire: unknown[] = [];
	let opened = 0,
		closed = 0;
	const resource: WorkerJournalResource = {
		root: new Uint8Array(32).fill(31),
		workspace: 'workspace-1',
		generation: 1,
		connection: {
			endpoint: 'https://example.test',
			capabilities: {
				governance: structuredClone(governance),
				changesets: structuredClone(changesets)
			}
		}
	};
	const admission = createWorkspaceAdmission({
		revisions: {
			read: async () => revision,
			advance: async () => ++revision,
			subscribe: () => () => {}
		},
		close: async () => host.close()
	});
	const host = createWorkerJournalHost({
		admission,
		openStore: async (key, codec) => {
			opened++;
			await beforeOpen?.();
			return {
				load: async () => {
					await beforeLoad?.();
					return values.has(key) ? codec.decode(structuredClone(values.get(key))) : null;
				},
				retain: async (entry) => {
					const next = codec.encode(entry);
					if (values.has(key) && !codec.equal(values.get(key), next)) throw Error('Changed');
					values.set(key, structuredClone(next) as EncryptedWorkspaceRecord);
				},
				resolve: async (entry) => {
					if (values.has(key) && !codec.equal(values.get(key), codec.encode(entry)))
						throw Error('Changed');
					values.delete(key);
				},
				close: () => {
					closed++;
				}
			};
		}
	});
	await admission.unlock(async () => resource);
	const transport = async (request: JournalRequest) => {
		const copy = structuredClone(request);
		wire.push(copy);
		return structuredClone(await host.request(copy));
	};
	return {
		host,
		admission,
		resource,
		values,
		wire,
		transport,
		get opened() {
			return opened;
		},
		get closed() {
			return closed;
		}
	};
}
for (const kind of ['governance', 'changesets'] as const)
	test(`${kind} typed proxy preserves actual canonical pending request while only worker owns keys`, async () => {
		const f = await fixture();
		const proxy = await openJournalProxy(kind, f.transport);
		const entry = kind === 'governance' ? approval : change;
		await proxy.retain(entry as never);
		expect(await proxy.load()).toEqual(entry);
		await proxy.retain(entry as never);
		expect([...f.values.keys()][0]).toMatch(/^[a-f0-9]{64}$/);
		expect(JSON.stringify([...f.values.values()])).not.toContain(entry.request.idempotencyKey);
		for (const request of f.wire as Record<string, unknown>[]) {
			expect(request).not.toHaveProperty('root');
			expect(request).not.toHaveProperty('token');
			expect(request).not.toHaveProperty('scope');
		}
		await proxy.resolve(entry as never);
		expect(await proxy.load()).toBeNull();
		await proxy.close();
		await expect(proxy.load()).rejects.toThrow();
		expect(f.closed).toBe(1);
		await f.admission.close();
	});
test('page supplied scope/root/token and unknown method are rejected before opening storage', async () => {
	const f = await fixture();
	for (const extra of [
		{ scope },
		{ root: new Uint8Array(32) },
		{ token: 'synthetic-consumer-secret' }
	])
		await expect(
			f.host.request({ method: 'open', kind: 'governance', ...extra })
		).rejects.toThrow();
	await expect(f.host.request({ method: 'unknown' })).rejects.toThrow();
	expect(f.opened).toBe(0);
	await f.admission.close();
});
test('canonical worker connection rejects a foreign scope and malformed retained candidate', async () => {
	const f = await fixture(),
		proxy = await openJournalProxy('governance', f.transport);
	await expect(
		proxy.retain({ ...approval, scope: { ...scope, principalId: 'other' } })
	).rejects.toThrow();
	await expect(proxy.retain({ ...approval, changes: [] })).rejects.toThrow();
	expect(f.values.size).toBe(0);
	await f.admission.close();
});
test('connection replacement retires old proxy without adopting another principal pending entry', async () => {
	const f = await fixture(),
		proxy = await openJournalProxy('governance', f.transport);
	await proxy.retain(approval);
	f.resource.connection = {
		...f.resource.connection,
		capabilities: {
			...f.resource.connection.capabilities,
			governance: { ...governance, sessionId: 'replacement-session' }
		}
	};
	await expect(proxy.load()).rejects.toThrow();
	expect(f.values.size).toBe(1);
	expect(f.closed).toBe(1);
	const next = await openJournalProxy('governance', f.transport);
	expect(await next.load()).toBeNull();
	await f.admission.close();
});
test('unsupported capability and locked admission never open protected storage', async () => {
	const f = await fixture();
	f.resource.connection.capabilities.governance = { ...governance, protocol: 'future' };
	await expect(openJournalProxy('governance', f.transport)).rejects.toThrow();
	expect(f.opened).toBe(0);
	await f.admission.lock();
	await expect(openJournalProxy('changesets', f.transport)).rejects.toThrow();
	expect(f.opened).toBe(0);
	await f.admission.close();
});
test('whole-set candidate must match the worker endpoint as well as authenticated session', async () => {
	const f = await fixture(),
		proxy = await openJournalProxy('changesets', f.transport);
	await expect(
		proxy.retain({ ...change, scope: { ...change.scope, endpoint: 'https://other.test' } })
	).rejects.toThrow();
	expect(f.values.size).toBe(0);
	await f.admission.close();
});

for (const patch of [
	{ authority: { propose: true, approve: false } },
	{ principal: { kind: 'agent', principalId: 'agent-1' } }
])
	test(
		'unapproved or non-user worker identity cannot open a journal: ' + JSON.stringify(patch),
		async () => {
			const f = await fixture();
			f.resource.connection.capabilities.governance = { ...governance, ...patch };
			await expect(openJournalProxy('governance', f.transport)).rejects.toThrow();
			expect(f.opened).toBe(0);
			await f.admission.close();
		}
	);
test('host shutdown during asynchronous acquisition closes the late handle', async () => {
	let started!: () => void, release!: () => void;
	const entered = new Promise<void>((res) => (started = res)),
		blocked = new Promise<void>((res) => (release = res));
	const f = await fixture(async () => {
		started();
		await blocked;
	});
	const opening = openJournalProxy('governance', f.transport);
	await entered;
	f.host.close();
	release();
	await expect(opening).rejects.toThrow();
	expect(f.closed).toBe(1);
	await f.admission.close();
});
test('page proxy close denies an already in-flight reply and sends close only once', async () => {
	const f = await fixture();
	let started!: () => void, release!: () => void;
	const entered = new Promise<void>((res) => (started = res)),
		blocked = new Promise<void>((res) => (release = res));
	const proxy = await openJournalProxy('governance', async (request) => {
		const result = await f.transport(request);
		if (request.method === 'load') {
			started();
			await blocked;
		}
		return result;
	});
	await proxy.retain(approval);
	const loading = proxy.load();
	await entered;
	await proxy.close();
	await proxy.close();
	release();
	await expect(loading).rejects.toThrow();
	expect(f.wire.filter((v) => (v as JournalRequest).method === 'close').length).toBe(1);
	expect(f.values.size).toBe(1);
	await f.admission.close();
});
for (const field of ['workspace', 'generation'] as const)
	test('old handle denied after worker ' + field + ' changes', async () => {
		const f = await fixture(),
			proxy = await openJournalProxy('governance', f.transport);
		await proxy.retain(approval);
		if (field === 'workspace') f.resource.workspace = 'replacement-workspace';
		else f.resource.generation++;
		await expect(proxy.load()).rejects.toThrow();
		expect(f.values.size).toBe(1);
		await f.admission.close();
	});
test('actual canonical changeset and governance codecs reject cross-kind payloads', async () => {
	const f = await fixture(),
		a = await openJournalProxy('governance', f.transport),
		b = await openJournalProxy('changesets', f.transport);
	await expect(a.retain(change as never)).rejects.toThrow();
	await expect(b.retain(approval as never)).rejects.toThrow();
	expect(f.values.size).toBe(0);
	await f.admission.close();
});
test('corrupt ciphertext fails the worker load without clearing uncertain pending state', async () => {
	const f = await fixture(),
		proxy = await openJournalProxy('governance', f.transport);
	await proxy.retain(approval);
	const ciphertext = [...f.values.values()][0];
	ciphertext.ciphertext[0] ^= 1;
	await expect(proxy.load()).rejects.toThrow();
	expect(f.values.size).toBe(1);
	await f.admission.close();
});

test('worker connection change during an awaited load denies the stale plaintext reply', async () => {
	let pause = false,
		started!: () => void,
		release!: () => void;
	const entered = new Promise<void>((res) => (started = res)),
		blocked = new Promise<void>((res) => (release = res));
	const f = await fixture(undefined, async () => {
			if (pause) {
				started();
				await blocked;
			}
		}),
		proxy = await openJournalProxy('governance', f.transport);
	await proxy.retain(approval);
	pause = true;
	const loading = proxy.load();
	await entered;
	f.resource.connection = { ...f.resource.connection, endpoint: 'https://replacement.test' };
	release();
	await expect(loading).rejects.toThrow();
	expect(f.values.size).toBe(1);
	expect(f.closed).toBe(1);
	await f.admission.close();
});
