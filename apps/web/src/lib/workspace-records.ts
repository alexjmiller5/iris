import { deriveWorkspaceKey } from './workspace-keys';

export type WorkspaceRecordContext = { store: string; id: string; generation: number };
export type EncryptedWorkspaceRecord = {
	version: 1;
	iv: Uint8Array;
	ciphertext: Uint8Array;
};
// A record bound, not an attachment-size policy. File integration must stream bounded chunks.
const maxBytes = 16 * 1024 * 1024;
const encoder = new TextEncoder();
const invalid = () => new Error('Invalid encrypted workspace record.');
function contextBytes(workspace: string, purpose: string, value: WorkspaceRecordContext) {
	if (
		!value ||
		typeof value !== 'object' ||
		!Number.isSafeInteger(value.generation) ||
		value.generation < 0 ||
		typeof value.store !== 'string' ||
		!value.store.length ||
		value.store.length > 512 ||
		typeof value.id !== 'string' ||
		!value.id.length ||
		value.id.length > 512
	)
		throw invalid();
	return encoder.encode(
		JSON.stringify([
			'iris-workspace-record',
			1,
			workspace,
			purpose,
			value.store,
			value.id,
			value.generation
		])
	);
}
function record(value: unknown): EncryptedWorkspaceRecord {
	if (!value || typeof value !== 'object' || Array.isArray(value)) throw invalid();
	const v = value as Record<string, unknown>;
	if (
		Object.keys(v).length !== 3 ||
		!['version', 'iv', 'ciphertext'].every((k) => Object.hasOwn(v, k)) ||
		v.version !== 1 ||
		!(v.iv instanceof Uint8Array) ||
		v.iv.length !== 12 ||
		!(v.ciphertext instanceof Uint8Array) ||
		v.ciphertext.length < 16 ||
		v.ciphertext.length > maxBytes + 16
	)
		throw invalid();
	return v as EncryptedWorkspaceRecord;
}
/** Standard AEAD for host records only; no persistence or SQLite page framing. */
export async function createWorkspaceRecords(
	root: Uint8Array,
	workspace: string,
	purpose: 'metadata' | 'files'
) {
	if (!['metadata', 'files'].includes(purpose)) throw invalid();
	const bytes = await deriveWorkspaceKey(root, workspace, purpose);
	let key: CryptoKey;
	try {
		key = await crypto.subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt', 'decrypt']);
	} finally {
		bytes.fill(0);
	}
	return {
		async seal(
			context: WorkspaceRecordContext,
			plaintext: Uint8Array
		): Promise<EncryptedWorkspaceRecord> {
			const additionalData = contextBytes(workspace, purpose, context);
			if (!(plaintext instanceof Uint8Array) || plaintext.length > maxBytes) throw invalid();
			const iv = crypto.getRandomValues(new Uint8Array(12));
			const ciphertext = await crypto.subtle.encrypt(
				{ name: 'AES-GCM', iv, additionalData, tagLength: 128 },
				key,
				new Uint8Array(plaintext)
			);
			return { version: 1, iv, ciphertext: new Uint8Array(ciphertext) };
		},
		async open(context: WorkspaceRecordContext, value: unknown): Promise<Uint8Array<ArrayBuffer>> {
			const additionalData = contextBytes(workspace, purpose, context);
			const v = record(value);
			// Snapshot untrusted structured-clone data before yielding to WebCrypto.
			const iv = new Uint8Array(v.iv),
				ciphertext = new Uint8Array(v.ciphertext);
			try {
				return new Uint8Array(
					await crypto.subtle.decrypt(
						{ name: 'AES-GCM', iv, additionalData, tagLength: 128 },
						key,
						ciphertext
					)
				);
			} catch {
				throw invalid();
			}
		}
	};
}
