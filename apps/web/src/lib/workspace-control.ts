import { createWorkspaceRecords, type EncryptedWorkspaceRecord } from './workspace-records';
import {
	activeEncryptedGeneration,
	type WorkspaceMigrationManifest
} from './workspace-migration-runner';
import { openWorkspaceControlStore, type WorkspaceControlStore } from './workspace-control-store';
export type { WorkspaceControlStore } from './workspace-control-store';
const encoder = new TextEncoder(),
	decoder = new TextDecoder('utf-8', { fatal: true });
const context = { store: 'workspace-control', id: 'state', generation: 0 };
export interface WorkspaceControlHints {
	send(): void;
	subscribe(changed: () => void): () => void;
	close(): void;
}
type State = { version: 1; revision: number; manifest: WorkspaceMigrationManifest | null };
const invalid = () => new Error('Invalid or unavailable authenticated workspace control.');
function manifestBytes(value: WorkspaceMigrationManifest | null) {
	return value === null
		? 'null'
		: JSON.stringify([value.version, value.workspace, value.source, value.target, value.phase]);
}
function checkedManifest(value: WorkspaceMigrationManifest | null, workspace: string) {
	if (value !== null) activeEncryptedGeneration(value, workspace);
	return value;
}
function state(value: unknown, workspace: string): State {
	if (!value || typeof value !== 'object' || Array.isArray(value)) throw invalid();
	const v = value as State;
	if (
		Object.keys(v).length !== 3 ||
		!['version', 'revision', 'manifest'].every((k) => Object.hasOwn(v, k)) ||
		v.version !== 1 ||
		!Number.isSafeInteger(v.revision) ||
		v.revision < 0
	)
		throw invalid();
	checkedManifest(v.manifest, workspace);
	return v;
}
function transition(
	before: WorkspaceMigrationManifest | null,
	next: WorkspaceMigrationManifest,
	workspace: string
) {
	checkedManifest(next, workspace);
	if (before === null) {
		if (next.phase !== 'copying') throw invalid();
		return;
	}
	checkedManifest(before, workspace);
	const phases = ['copying', 'cleanup', 'complete'];
	if (
		before.source !== next.source ||
		before.target !== next.target ||
		phases.indexOf(next.phase) !== phases.indexOf(before.phase) + 1
	)
		throw invalid();
}
function control(
	workspace: string,
	records: Awaited<ReturnType<typeof createWorkspaceRecords>>,
	store: WorkspaceControlStore,
	hints?: WorkspaceControlHints
) {
	let closed = false;
	const listeners = new Set<() => void>();
	const notify = () => {
		for (const changed of listeners) changed();
	};
	const unsubscribe = hints?.subscribe(notify);
	const guard = () => {
		if (closed) throw new Error('Workspace control is closed.');
	};
	async function read() {
		guard();
		const encrypted = await store.read();
		guard();
		if (encrypted === null) throw invalid();
		const bytes = await records.open(context, encrypted);
		try {
			const value = state(JSON.parse(decoder.decode(bytes)), workspace);
			guard();
			return { encrypted, value };
		} finally {
			bytes.fill(0);
		}
	}
	async function seal(value: State) {
		const bytes = encoder.encode(JSON.stringify(value));
		try {
			return await records.seal(context, bytes);
		} finally {
			bytes.fill(0);
		}
	}
	async function commit(before: EncryptedWorkspaceRecord | null, next: State) {
		guard();
		const encrypted = await seal(next);
		guard();
		if (!(await store.compareAndSwap(before, encrypted))) return false;
		guard();
		const observed = await read();
		if (
			observed.value.revision < next.revision ||
			manifestBytes(observed.value.manifest) !== manifestBytes(next.manifest)
		)
			throw invalid();
		notify();
		hints?.send();
		return true;
	}
	return {
		async initialize() {
			guard();
			if ((await store.read()) !== null) throw invalid();
			guard();
			if (!(await commit(null, { version: 1, revision: 0, manifest: null }))) throw invalid();
		},
		async read() {
			return (await read()).value.revision;
		},
		async advance() {
			for (let attempt = 0; attempt < 8; attempt++) {
				const before = await read();
				if (before.value.revision === Number.MAX_SAFE_INTEGER) throw invalid();
				const revision = before.value.revision + 1;
				if (await commit(before.encrypted, { ...before.value, revision })) return revision;
			}
			throw new Error('Concurrent workspace control update did not settle.');
		},
		subscribe(changed: () => void) {
			guard();
			listeners.add(changed);
			return () => listeners.delete(changed);
		},
		async readManifest() {
			return structuredClone((await read()).value.manifest);
		},
		async writeManifest(
			before: WorkspaceMigrationManifest | null,
			next: WorkspaceMigrationManifest
		) {
			// Snapshot caller-owned values before asynchronous crypto or storage.
			const expected = structuredClone(before),
				replacement = structuredClone(next);
			transition(expected, replacement, workspace);
			const current = await read();
			if (manifestBytes(current.value.manifest) !== manifestBytes(expected)) throw invalid();
			if (!(await commit(current.encrypted, { ...current.value, manifest: replacement })))
				throw new Error('Workspace manifest changed concurrently.');
		},
		close() {
			closed = true;
			listeners.clear();
			unsubscribe?.();
			hints?.close();
			store.close();
		}
	};
}
/** Authenticated revisions are readable only after unlock. AEAD cannot detect a
 * complete same-generation rollback without an independent trusted checkpoint.
 * close does not erase captured values or destroy CryptoKeys; dispose the worker.
 */
export async function createWorkspaceControl(
	root: Uint8Array,
	workspace: string,
	store: WorkspaceControlStore,
	hints?: WorkspaceControlHints
) {
	return control(
		workspace,
		await createWorkspaceRecords(root, workspace, 'metadata'),
		store,
		hints
	);
}
export async function openWorkspaceControl(
	root: Uint8Array,
	workspace: string,
	options: Parameters<typeof openWorkspaceControlStore>[1] = {}
) {
	const records = await createWorkspaceRecords(root, workspace, 'metadata');
	const store = await openWorkspaceControlStore(workspace, options);
	try {
		const channel =
			typeof BroadcastChannel === 'undefined'
				? undefined
				: new BroadcastChannel(`iris:control:${workspace}`);
		const hints = channel
			? {
					send: () => channel.postMessage(null),
					subscribe: (changed: () => void) => {
						channel.addEventListener('message', changed);
						return () => channel.removeEventListener('message', changed);
					},
					close: () => channel.close()
				}
			: undefined;
		return control(workspace, records, store, hints);
	} catch (error) {
		store.close();
		throw error;
	}
}
