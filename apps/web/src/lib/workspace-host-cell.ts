import { deriveWorkspaceKey } from './workspace-keys';
import {
	createWorkspaceRecords,
	readEncryptedWorkspaceRecord,
	type EncryptedWorkspaceRecord,
	type WorkspaceRecordContext
} from './workspace-records';
import type { WorkspaceControlStore } from './workspace-control-store';
import type { HubConnection } from './device-enrollment';
import { collectConsumerCredentialInventory } from './workspace-auxiliary-inventory';
export interface WorkerKeyResource {
	root: Uint8Array;
	workspace: string;
	generation: number;
}
type Admission = {
	run<R>(work: (resource: WorkerKeyResource, signal: AbortSignal) => Promise<R>): Promise<R>;
};
type Options = {
	admission: Admission;
	openStore(workspace: string, opaqueId: string): Promise<WorkspaceControlStore>;
};
const encoder = new TextEncoder(),
	decoder = new TextDecoder('utf-8', { fatal: true });
const denied = () => new Error('Encrypted workspace cell is unavailable.');
const equal = (a: Uint8Array | null, b: Uint8Array | null) =>
	a === null || b === null ? a === b : a.length === b.length && a.every((v, i) => v === b[i]);
function bytes(value: Uint8Array) {
	if (!(value instanceof Uint8Array) || value.byteLength > 16 * 1024 * 1024) throw denied();
	return new Uint8Array(value);
}
function snapshot(value: unknown) {
	const v = readEncryptedWorkspaceRecord(value);
	return {
		version: 1 as const,
		iv: new Uint8Array(v.iv),
		ciphertext: new Uint8Array(v.ciphertext)
	};
}
async function opaqueId(
	root: Uint8Array,
	workspace: string,
	purpose: string,
	context: WorkspaceRecordContext
) {
	const metadata = await deriveWorkspaceKey(root, workspace, 'metadata');
	let key: CryptoKey;
	try {
		const material = await crypto.subtle.importKey('raw', metadata, 'HKDF', false, ['deriveKey']);
		key = await crypto.subtle.deriveKey(
			{
				name: 'HKDF',
				hash: 'SHA-256',
				salt: encoder.encode(workspace),
				info: encoder.encode('iris-host-cell-index/v1')
			},
			material,
			{ name: 'HMAC', hash: 'SHA-256', length: 256 },
			false,
			['sign']
		);
	} finally {
		metadata.fill(0);
	}
	const digest = new Uint8Array(
		await crypto.subtle.sign(
			'HMAC',
			key,
			encoder.encode(JSON.stringify([1, purpose, context.store, context.id, context.generation]))
		)
	);
	return Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('');
}
/** Worker-private exact-byte cell over strict encrypted CAS storage. Keys come
 * only from the admitted worker resource; only an opaque HMAC ID reaches storage.
 * The immutable unlock signal prevents reuse across lock/reunlock, even if a bad
 * owner accidentally reuses its resource object. Owner must still end the worker:
 * close blocks operations/closes handles, not physical CryptoKey destruction.
 */
export async function createWorkerEncryptedCell(
	options: Options & {
		purpose: 'metadata' | 'files';
		context: Pick<WorkspaceRecordContext, 'store' | 'id'>;
	}
) {
	const { admission, openStore, purpose } = options;
	const context = { store: options.context.store, id: options.context.id };
	if (
		!['metadata', 'files'].includes(purpose) ||
		![context.store, context.id].every(
			(value) => typeof value === 'string' && value.length > 0 && value.length <= 512
		)
	)
		throw denied();
	const opened: { store?: WorkspaceControlStore } = {};
	let initial: Awaited<ReturnType<typeof initialize>>;
	async function initialize() {
		return admission.run(async (resource, signal) => {
			if (!Number.isSafeInteger(resource.generation) || resource.generation < 0) throw denied();
			const owner = {
				resource,
				signal,
				workspace: resource.workspace,
				generation: resource.generation,
				root: resource.root
			};
			const boundContext = { ...context, generation: owner.generation };
			const check = () => {
				signal.throwIfAborted();
				if (
					resource.root !== owner.root ||
					resource.workspace !== owner.workspace ||
					resource.generation !== owner.generation
				)
					throw denied();
			};
			const records = await createWorkspaceRecords(owner.root, owner.workspace, purpose);
			const id = await opaqueId(owner.root, owner.workspace, purpose, boundContext);
			check();
			opened.store = await openStore(owner.workspace, id);
			check();
			if (
				!opened.store ||
				typeof opened.store.read !== 'function' ||
				typeof opened.store.compareAndSwap !== 'function' ||
				typeof opened.store.close !== 'function'
			)
				throw denied();
			return { owner, records, context: boundContext };
		});
	}
	try {
		initial = await initialize();
	} catch {
		let closeFailed = false;
		try {
			opened.store?.close();
		} catch {
			closeFailed = true;
		}
		if (closeFailed)
			throw new AggregateError(
				[new Error('Encrypted cell opening failed.'), new Error('Encrypted cell cleanup failed.')],
				'Encrypted cell opening failed.'
			);
		throw denied();
	}
	const { owner, records } = initial,
		boundContext = initial.context,
		store = opened.store!;
	let closed = false;
	function guard(resource: WorkerKeyResource, signal: AbortSignal) {
		signal.throwIfAborted();
		if (
			closed ||
			signal !== owner.signal ||
			resource !== owner.resource ||
			resource.root !== owner.root ||
			resource.workspace !== owner.workspace ||
			resource.generation !== owner.generation
		)
			throw denied();
	}
	async function run<R>(work: (signal: AbortSignal) => Promise<R>) {
		return admission.run(async (resource, signal) => {
			guard(resource, signal);
			const result = await work(signal);
			guard(resource, signal);
			return result;
		});
	}
	return {
		async read(): Promise<Uint8Array | null> {
			let plaintext: Uint8Array | undefined;
			try {
				return await run(async (signal) => {
					const raw = await store.read();
					signal.throwIfAborted();
					if (raw === null) return null;
					plaintext = await records.open(boundContext, snapshot(raw));
					signal.throwIfAborted();
					return plaintext;
				});
			} catch {
				plaintext?.fill(0);
				throw denied();
			}
		},
		async replace(expected: Uint8Array | null, next: Uint8Array): Promise<void> {
			if (
				!(next instanceof Uint8Array) ||
				next.byteLength > 16 * 1024 * 1024 ||
				(expected !== null &&
					(!(expected instanceof Uint8Array) || expected.byteLength > 16 * 1024 * 1024))
			)
				throw denied();
			const beforeBytes = expected === null ? null : bytes(expected),
				nextBytes = bytes(next);
			let old: Uint8Array | undefined, observed: Uint8Array | undefined;
			try {
				await run(async (signal) => {
					const raw = await store.read(),
						before = raw === null ? null : snapshot(raw);
					signal.throwIfAborted();
					old = before === null ? undefined : await records.open(boundContext, before);
					signal.throwIfAborted();
					if (!equal(old ?? null, beforeBytes))
						throw new Error('Encrypted cell changed concurrently.');
					const sealed = await records.seal(boundContext, nextBytes);
					guard(owner.resource, signal);
					if ((await store.compareAndSwap(before, sealed)) !== true)
						throw new Error('Encrypted cell changed concurrently.');
					const durable = await store.read();
					signal.throwIfAborted();
					if (durable === null) throw denied();
					observed = await records.open(boundContext, snapshot(durable));
					signal.throwIfAborted();
					if (!equal(observed, nextBytes))
						throw new Error('Encrypted cell write was not observed.');
				});
			} finally {
				old?.fill(0);
				observed?.fill(0);
				beforeBytes?.fill(0);
				nextBytes.fill(0);
			}
		},
		close() {
			closed = true;
			store.close();
		}
	};
}
function credential(raw: Uint8Array | null): HubConnection | null {
	if (raw === null) return null;
	try {
		const value: unknown = JSON.parse(decoder.decode(raw));
		collectConsumerCredentialInventory(value as HubConnection | null);
		return value as HubConnection | null;
	} catch {
		throw new Error('Encrypted consumer credential is unreadable.');
	}
}
/** Never expose this adapter on the page protocol. Its only consumer is the
 * worker's existing authenticated HTTP/session client; no provider operation here.
 */
export async function createWorkerCredentialStore(options: Options) {
	const cell = await createWorkerEncryptedCell({
		...options,
		purpose: 'metadata',
		context: { store: 'consumer-credential', id: 'connection' }
	});
	return {
		async read() {
			const raw = await cell.read();
			try {
				return credential(raw);
			} finally {
				raw?.fill(0);
			}
		},
		async replace(expected: HubConnection | null, next: HubConnection | null) {
			const before = collectConsumerCredentialInventory(expected)[0].value,
				replacement = collectConsumerCredentialInventory(next)[0].value;
			let current: Uint8Array | null = null,
				canonical: Uint8Array | undefined;
			try {
				current = await cell.read();
				canonical = collectConsumerCredentialInventory(credential(current))[0].value;
				if (!equal(canonical, before)) throw new Error('Consumer credential changed concurrently.');
				await cell.replace(current, replacement);
			} finally {
				before.fill(0);
				replacement.fill(0);
				current?.fill(0);
				canonical?.fill(0);
			}
		},
		close: () => cell.close()
	};
}

function storageBytes(values: ReadonlyMap<string, string>) {
	if (!(values instanceof Map) || values.size > 100000)
		throw new Error('Invalid retained preference snapshot.');
	const rows = [...values];
	if (rows.some(([key, value]) => typeof key !== 'string' || typeof value !== 'string'))
		throw new Error('Invalid retained preference snapshot.');
	rows.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
	const encoded = encoder.encode(JSON.stringify(rows));
	if (encoded.length > 16 * 1024 * 1024)
		throw new Error('Retained preferences require a streaming adapter.');
	return encoded;
}
function storageValues(raw: Uint8Array | null): Map<string, string> {
	if (raw === null) return new Map();
	try {
		const rows: unknown = JSON.parse(decoder.decode(raw));
		if (!Array.isArray(rows) || rows.length > 100000) throw denied();
		const result = new Map<string, string>();
		for (const row of rows) {
			if (
				!Array.isArray(row) ||
				row.length !== 2 ||
				typeof row[0] !== 'string' ||
				typeof row[1] !== 'string' ||
				result.has(row[0])
			)
				throw denied();
			result.set(row[0], row[1]);
		}
		return result;
	} catch {
		throw new Error('Encrypted retained preferences are unreadable.');
	}
}
/** Worker-private raw web-storage replacement. Unknown keys are preserved, not
 * interpreted as authority. Page hydration must expose only its declared UI keys. */
export async function createWorkerWebStorageStore(options: Options) {
	const cell = await createWorkerEncryptedCell({
		...options,
		purpose: 'metadata',
		context: { store: 'retained-web-storage', id: 'entries' }
	});
	return {
		async read() {
			const raw = await cell.read();
			try {
				return storageValues(raw);
			} finally {
				raw?.fill(0);
			}
		},
		async replace(expected: ReadonlyMap<string, string>, next: ReadonlyMap<string, string>) {
			const before = storageBytes(expected),
				replacement = storageBytes(next);
			let current: Uint8Array | null = null,
				canonical: Uint8Array | undefined;
			try {
				current = await cell.read();
				canonical = storageBytes(storageValues(current));
				if (!equal(canonical, before))
					throw new Error('Retained preferences changed concurrently.');
				await cell.replace(current, replacement);
			} finally {
				before.fill(0);
				replacement.fill(0);
				current?.fill(0);
				canonical?.fill(0);
			}
		},
		close: () => cell.close()
	};
}
