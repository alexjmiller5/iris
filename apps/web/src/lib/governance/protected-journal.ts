import { deriveWorkspaceKey } from '../workspace-keys';
import {
	createWorkspaceRecords,
	readEncryptedWorkspaceRecord,
	type EncryptedWorkspaceRecord
} from '../workspace-records';
import { openScopedJournal, type DurableJournal } from './approval-journal';

const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
/** Worker-owned protection. Neither a root key nor a consumer credential crosses the UI bridge. */
export async function createJournalProtection(
	root: Uint8Array,
	workspace: string,
	generation: number,
	kind: 'governance' | 'changesets',
	scope: string
) {
	if (
		!Number.isSafeInteger(generation) ||
		generation < 0 ||
		!['governance', 'changesets'].includes(kind) ||
		typeof scope !== 'string' ||
		!scope.length ||
		scope.length > 65536
	)
		throw new Error('Invalid journal protection scope.');
	const metadata = await deriveWorkspaceKey(root, workspace, 'metadata');
	let indexKey: CryptoKey;
	try {
		const material = await crypto.subtle.importKey('raw', metadata, 'HKDF', false, ['deriveKey']);
		indexKey = await crypto.subtle.deriveKey(
			{
				name: 'HKDF',
				hash: 'SHA-256',
				salt: encoder.encode(workspace),
				info: encoder.encode(`iris-journal-index/v1/${kind}`)
			},
			material,
			{ name: 'HMAC', hash: 'SHA-256', length: 256 },
			false,
			['sign']
		);
	} finally {
		metadata.fill(0);
	}
	const signature = new Uint8Array(
		await crypto.subtle.sign('HMAC', indexKey, encoder.encode(scope))
	);
	const key = Array.from(signature, (byte) => byte.toString(16).padStart(2, '0')).join('');
	const records = await createWorkspaceRecords(root, workspace, 'metadata');
	const context = { store: `journal-${kind}`, id: key, generation };
	return {
		key,
		databaseName: `iris-vault-${workspace}-${generation}`,
		seal: (bytes: Uint8Array) => records.seal(context, bytes),
		open: (value: unknown) => records.open(context, value)
	};
}
type Protection = Awaited<ReturnType<typeof createJournalProtection>>;
type Admission = { run<T>(work: (signal: AbortSignal) => Promise<T>): Promise<T> };
function copyRecord(value: unknown): EncryptedWorkspaceRecord {
	const record = readEncryptedWorkspaceRecord(value);
	return {
		version: 1,
		iv: new Uint8Array(record.iv),
		ciphertext: new Uint8Array(record.ciphertext)
	};
}
function equalRecords(left: unknown, right: unknown) {
	const a = readEncryptedWorkspaceRecord(left),
		b = readEncryptedWorkspaceRecord(right);
	return (
		a.iv.length === b.iv.length &&
		a.ciphertext.length === b.ciphertext.length &&
		a.iv.every((byte, i) => byte === b.iv[i]) &&
		a.ciphertext.every((byte, i) => byte === b.ciphertext[i])
	);
}
/** Crypto runs outside IDB transactions. The strict store owns retain-if-empty and exact-snapshot delete. */
export async function openProtectedJournal<T>(
	codec: { encode(entry: T): string; decode(raw: unknown): T },
	options: {
		protection: Protection;
		admission: Admission;
		indexedDB?: IDBFactory;
		openStore?: (
			key: string,
			codec: {
				encode(value: EncryptedWorkspaceRecord): unknown;
				decode(raw: unknown): EncryptedWorkspaceRecord;
				equal(left: unknown, right: unknown): boolean;
			},
			options: { indexedDB?: IDBFactory; databaseName: string }
		) => Promise<DurableJournal<EncryptedWorkspaceRecord>>;
	}
): Promise<DurableJournal<T>> {
	const { protection, admission } = options;
	const acquired: { store?: DurableJournal<EncryptedWorkspaceRecord> } = {};
	try {
		await admission.run(async (signal) => {
			signal.throwIfAborted();
			acquired.store = await (options.openStore ?? openScopedJournal)(
				protection.key,
				{ encode: copyRecord, decode: copyRecord, equal: equalRecords },
				{
					...(Object.hasOwn(options, 'indexedDB') ? { indexedDB: options.indexedDB } : {}),
					databaseName: protection.databaseName
				}
			);
			signal.throwIfAborted();
		});
	} catch (error) {
		acquired.store?.close();
		throw error;
	}
	if (!acquired.store) throw new Error('Journal storage did not open.');
	const opened = acquired.store;
	let closed = false;
	const guard = (signal: AbortSignal) => {
		signal.throwIfAborted();
		if (closed) throw new Error('Protected journal is closed.');
	};
	async function run<R>(work: (signal: AbortSignal) => Promise<R>) {
		return admission.run(async (signal) => {
			guard(signal);
			const value = await work(signal);
			guard(signal);
			return value;
		});
	}
	async function decode(record: EncryptedWorkspaceRecord) {
		const bytes = await protection.open(record);
		try {
			return codec.decode(decoder.decode(bytes));
		} finally {
			bytes.fill(0);
		}
	}
	return {
		load: () =>
			run(async (signal) => {
				const record = await opened.load();
				guard(signal);
				return record === null ? null : decode(record);
			}),
		retain: (entry) =>
			run(async (signal) => {
				const encoded = codec.encode(entry);
				const retained = await opened.load();
				guard(signal);
				if (retained !== null) {
					const previous = await decode(retained);
					guard(signal);
					if (codec.encode(previous) !== encoded)
						throw new Error('Resolve the retained journal entry first.');
					await opened.retain(retained);
					return;
				}
				const bytes = encoder.encode(encoded);
				let sealed: EncryptedWorkspaceRecord;
				try {
					sealed = await protection.seal(bytes);
				} finally {
					bytes.fill(0);
				}
				guard(signal);
				await opened.retain(sealed);
			}),
		resolve: (entry) =>
			run(async (signal) => {
				const encoded = codec.encode(entry);
				const retained = await opened.load();
				guard(signal);
				if (retained === null) return;
				const previous = await decode(retained);
				guard(signal);
				if (codec.encode(previous) !== encoded)
					throw new Error('Retained journal entry does not match.');
				await opened.resolve(retained);
			}),
		close() {
			closed = true;
			opened.close();
		}
	};
}
