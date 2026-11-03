import { expect, test } from 'bun:test';
import type { WorkspaceControlStore } from '../apps/web/src/lib/workspace-control';
const { createWorkspaceControl } = (await import(
	process.env.IRIS_TEST_WORKSPACE_CONTROL || '../apps/web/src/lib/workspace-control'
)) as typeof import('../apps/web/src/lib/workspace-control');
import {
	createWorkspaceRecords,
	type EncryptedWorkspaceRecord
} from '../apps/web/src/lib/workspace-records';
const root = new Uint8Array(32).fill(41),
	workspace = 'workspace-1';
const copying = {
	version: 1 as const,
	workspace,
	source: 'legacy-1',
	target: 'encrypted-1',
	phase: 'copying' as const
};
function fixture() {
	let record: EncryptedWorkspaceRecord | null = null,
		calls = 0,
		closed = false,
		noop = false,
		conflict = false;
	const store: WorkspaceControlStore = {
		read: async () => structuredClone(record),
		compareAndSwap: async (before, next) => {
			calls++;
			if (conflict) return false;
			if (JSON.stringify(before) !== JSON.stringify(record)) return false;
			if (!noop) record = structuredClone(next);
			return true;
		},
		close: () => {
			closed = true;
		}
	};
	return {
		store,
		get record() {
			return record;
		},
		get calls() {
			return calls;
		},
		get closed() {
			return closed;
		},
		set noop(v: boolean) {
			noop = v;
		},
		set conflict(v: boolean) {
			conflict = v;
		},
		set record(value: EncryptedWorkspaceRecord | null) {
			record = value;
		}
	};
}
test('explicit initialization encrypts authenticated revision and complete manifest, reopening preserves them', async () => {
	const f = fixture(),
		control = await createWorkspaceControl(root, workspace, f.store);
	await expect(control.read()).rejects.toThrow();
	await control.initialize();
	expect(await control.read()).toBe(0);
	expect(await control.readManifest()).toBeNull();
	await control.writeManifest(null, copying);
	expect(JSON.stringify(f.record)).not.toContain(copying.source);
	expect(await control.advance()).toBe(1);
	expect(await control.readManifest()).toEqual(copying);
	const reopened = await createWorkspaceControl(root, workspace, f.store);
	expect(await reopened.read()).toBe(1);
	expect(await reopened.readManifest()).toEqual(copying);
	await expect(reopened.initialize()).rejects.toThrow();
});
test('wrong root/workspace or actual ciphertext mutation never becomes an empty control state', async () => {
	const f = fixture(),
		control = await createWorkspaceControl(root, workspace, f.store);
	await control.initialize();
	for (const c of [
		await createWorkspaceControl(new Uint8Array(32).fill(42), workspace, f.store),
		await createWorkspaceControl(root, 'other-workspace', f.store)
	])
		await expect(c.read()).rejects.toThrow();
	const mutated = structuredClone(f.record!);
	mutated.ciphertext[0] ^= 1;
	f.record = mutated;
	await expect(control.readManifest()).rejects.toThrow();
});
test('a no-op store cannot acknowledge an initialized state, revision advance or manifest publication', async () => {
	const f = fixture(),
		control = await createWorkspaceControl(root, workspace, f.store);
	f.noop = true;
	await expect(control.initialize()).rejects.toThrow();
	f.noop = false;
	await control.initialize();
	f.noop = true;
	await expect(control.advance()).rejects.toThrow();
	expect(await control.read()).toBe(0);
	await expect(control.writeManifest(null, copying)).rejects.toThrow();
	expect(await control.readManifest()).toBeNull();
});
test('invalid authenticated revisions are rejected rather than coerced', async () => {
	const f = fixture(),
		control = await createWorkspaceControl(root, workspace, f.store),
		records = await createWorkspaceRecords(root, workspace, 'metadata');
	for (const revision of ['1', null, -1, Number.MAX_SAFE_INTEGER + 1]) {
		f.record = await records.seal(
			{ store: 'workspace-control', id: 'state', generation: 0 },
			new TextEncoder().encode(JSON.stringify({ version: 1, revision, manifest: null }))
		);
		await expect(control.read()).rejects.toThrow();
	}
});
test('manifest compare-and-swap preserves exact generation and enforces recoverable phase order', async () => {
	const f = fixture(),
		control = await createWorkspaceControl(root, workspace, f.store);
	await control.initialize();
	await control.writeManifest(null, copying);
	await expect(control.writeManifest(null, copying)).rejects.toThrow();
	await expect(control.writeManifest(copying, { ...copying, phase: 'complete' })).rejects.toThrow();
	await expect(
		control.writeManifest(copying, { ...copying, target: 'replacement', phase: 'cleanup' })
	).rejects.toThrow();
	const cleanup = { ...copying, phase: 'cleanup' as const };
	await control.writeManifest(copying, cleanup);
	await expect(control.writeManifest(cleanup, copying)).rejects.toThrow();
	const complete = { ...copying, phase: 'complete' as const };
	await control.writeManifest(cleanup, complete);
	expect(await control.readManifest()).toEqual(complete);
	expect(await control.read()).toBe(0);
});
test('two control instances serialize concurrent authenticated revision advances without losing manifest', async () => {
	const f = fixture(),
		a = await createWorkspaceControl(root, workspace, f.store),
		b = await createWorkspaceControl(root, workspace, f.store);
	await a.initialize();
	await a.writeManifest(null, copying);
	expect((await Promise.all([a.advance(), b.advance()])).sort()).toEqual([1, 2]);
	expect(await a.read()).toBe(2);
	expect(await b.readManifest()).toEqual(copying);
});
test('persistent CAS conflict is bounded and never acknowledges revocation', async () => {
	const f = fixture(),
		control = await createWorkspaceControl(root, workspace, f.store);
	await control.initialize();
	const before = f.calls;
	f.conflict = true;
	await expect(control.advance()).rejects.toThrow();
	expect(f.calls - before).toBeLessThanOrEqual(8);
	expect(await control.read()).toBe(0);
});
test('close disposes the owned store and rejects stale control operations', async () => {
	const f = fixture(),
		control = await createWorkspaceControl(root, workspace, f.store);
	await control.initialize();
	control.close();
	expect(f.closed).toBe(true);
	await expect(control.read()).rejects.toThrow();
	await expect(control.advance()).rejects.toThrow();
});

test('revision hints are notifications only; actual admission checks authenticated persisted state', async () => {
	const f = fixture(),
		control = await createWorkspaceControl(root, workspace, f.store);
	await control.initialize();
	let hints = 0;
	const unsubscribe = control.subscribe(() => hints++);
	await control.advance();
	expect(hints).toBe(1);
	unsubscribe();
	await control.advance();
	expect(hints).toBe(1);
});

test('cross-instance hints notify peers but only authenticated shared state establishes revocation', async () => {
	const f = fixture(),
		aListeners = new Set<() => void>(),
		bListeners = new Set<() => void>();
	let aClosed = false,
		bClosed = false;
	const hints = (own: Set<() => void>, peer: Set<() => void>, close: () => void) => ({
		send: () => {
			for (const callback of peer) callback();
		},
		subscribe: (callback: () => void) => {
			own.add(callback);
			return () => own.delete(callback);
		},
		close
	});
	const a = await createWorkspaceControl(
		root,
		workspace,
		f.store,
		hints(aListeners, bListeners, () => (aClosed = true))
	);
	const b = await createWorkspaceControl(
		root,
		workspace,
		f.store,
		hints(bListeners, aListeners, () => (bClosed = true))
	);
	await a.initialize();
	let notifications = 0;
	b.subscribe(() => notifications++);
	await a.advance();
	expect(notifications).toBe(1);
	expect(await b.read()).toBe(1);
	for (const callback of bListeners) callback();
	expect(notifications).toBe(2);
	expect(await b.read()).toBe(1);
	a.close();
	b.close();
	expect(aClosed && bClosed).toBe(true);
	expect(aListeners.size + bListeners.size).toBe(0);
});

test('actual admission rejects a peer after authenticated control revision advance', async () => {
	const { createWorkspaceAdmission } = await import('../apps/web/src/lib/workspace-admission');
	const f = fixture(),
		a = await createWorkspaceControl(root, workspace, f.store),
		b = await createWorkspaceControl(root, workspace, f.store);
	await a.initialize();
	let disposed = 0;
	const peer = createWorkspaceAdmission({
		revisions: b,
		close: async () => {
			disposed++;
		}
	});
	await peer.unlock(async () => ({ synthetic: true }));
	expect(await peer.run(async () => true)).toBe(true);
	await a.advance();
	await expect(peer.run(async () => true)).rejects.toThrow();
	expect(disposed).toBe(1);
	await peer.close();
});
