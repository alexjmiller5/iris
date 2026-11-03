/** Worker-only key envelopes. This does not encrypt or open SQLite storage. */
export type WorkspaceKeyEnvelope = {
	version: 1;
	workspace: string;
	kdf: 'PBKDF2-SHA256';
	iterations: number;
	salt: string;
	cipher: 'AES-256-GCM';
	iv: string;
	wrappedKey: string;
};
const encoder = new TextEncoder();
const iterations = 600_000;
const invalid = () => new Error('Invalid encrypted workspace.');
const locked = () =>
	new Error('Cannot unlock this workspace. Check the passphrase and retained data.');
const encode = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
function workspaceId(value: unknown): asserts value is string {
	if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(value)) throw invalid();
}
function decode(value: unknown, size: number): Uint8Array<ArrayBuffer> {
	if (
		typeof value !== 'string' ||
		value.length !== 4 * Math.ceil(size / 3) ||
		!/^[A-Za-z0-9+/]*={0,2}$/.test(value)
	)
		throw invalid();
	let bytes: Uint8Array<ArrayBuffer>;
	try {
		bytes = Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
	} catch {
		throw invalid();
	}
	if (bytes.length !== size || encode(bytes) !== value) throw invalid();
	return bytes;
}
function envelope(value: unknown): WorkspaceKeyEnvelope {
	if (!value || typeof value !== 'object' || Array.isArray(value)) throw invalid();
	const v = value as Record<string, unknown>;
	const fields = [
		'version',
		'workspace',
		'kdf',
		'iterations',
		'salt',
		'cipher',
		'iv',
		'wrappedKey'
	];
	if (
		Object.keys(v).length !== fields.length ||
		fields.some((k) => !Object.hasOwn(v, k)) ||
		v.version !== 1 ||
		v.kdf !== 'PBKDF2-SHA256' ||
		v.cipher !== 'AES-256-GCM' ||
		!Number.isSafeInteger(v.iterations) ||
		Number(v.iterations) < iterations ||
		Number(v.iterations) > 2_000_000
	)
		throw invalid();
	workspaceId(v.workspace);
	decode(v.salt, 16);
	decode(v.iv, 12);
	decode(v.wrappedKey, 48);
	return { ...v } as WorkspaceKeyEnvelope;
}
const authenticatedHeader = (v: WorkspaceKeyEnvelope) =>
	encoder.encode(
		JSON.stringify([
			'iris-workspace-key',
			v.version,
			v.workspace,
			v.kdf,
			v.iterations,
			v.salt,
			v.cipher,
			v.iv
		])
	);
async function wrappingKey(v: WorkspaceKeyEnvelope, passphrase: string) {
	if (typeof passphrase !== 'string' || !passphrase.length || passphrase.length > 1024)
		throw invalid();
	const bytes = encoder.encode(passphrase);
	try {
		const input = await crypto.subtle.importKey('raw', bytes, 'PBKDF2', false, ['deriveKey']);
		return await crypto.subtle.deriveKey(
			{ name: 'PBKDF2', hash: 'SHA-256', salt: decode(v.salt, 16), iterations: v.iterations },
			input,
			{ name: 'AES-GCM', length: 256 },
			false,
			['encrypt', 'decrypt']
		);
	} finally {
		bytes.fill(0);
	}
}
async function wrap(
	key: Uint8Array,
	workspace: string,
	passphrase: string
): Promise<WorkspaceKeyEnvelope> {
	workspaceId(workspace);
	if (key.length !== 32) throw invalid();
	const v: WorkspaceKeyEnvelope = {
		version: 1,
		workspace,
		kdf: 'PBKDF2-SHA256',
		iterations,
		salt: encode(crypto.getRandomValues(new Uint8Array(16))),
		cipher: 'AES-256-GCM',
		iv: encode(crypto.getRandomValues(new Uint8Array(12))),
		wrappedKey: ''
	};
	const kek = await wrappingKey(v, passphrase);
	const result = await crypto.subtle.encrypt(
		{
			name: 'AES-GCM',
			iv: decode(v.iv, 12),
			additionalData: authenticatedHeader(v),
			tagLength: 128
		},
		kek,
		new Uint8Array(key)
	);
	return { ...v, wrappedKey: encode(new Uint8Array(result)) };
}
export async function createWorkspaceKey(workspace: string, passphrase: string) {
	const key = crypto.getRandomValues(new Uint8Array(32));
	try {
		return { envelope: await wrap(key, workspace, passphrase), key };
	} catch (error) {
		key.fill(0);
		throw error;
	}
}
export async function unlockWorkspaceKey(
	value: unknown,
	workspace: string,
	passphrase: string
): Promise<Uint8Array<ArrayBuffer>> {
	const v = envelope(value);
	workspaceId(workspace);
	if (v.workspace !== workspace) throw invalid();
	const kek = await wrappingKey(v, passphrase);
	try {
		const key = await crypto.subtle.decrypt(
			{
				name: 'AES-GCM',
				iv: decode(v.iv, 12),
				additionalData: authenticatedHeader(v),
				tagLength: 128
			},
			kek,
			decode(v.wrappedKey, 48)
		);
		if (key.byteLength !== 32) throw locked();
		return new Uint8Array(key);
	} catch {
		throw locked();
	}
}
/** Rewrap does not revoke a previously copied envelope or its root key. */
export async function rewrapWorkspaceKey(
	value: unknown,
	workspace: string,
	passphrase: string,
	nextPassphrase: string
) {
	const key = await unlockWorkspaceKey(value, workspace, passphrase);
	try {
		return await wrap(key, workspace, nextPassphrase);
	} finally {
		key.fill(0);
	}
}
export async function deriveWorkspaceKey(
	key: Uint8Array,
	workspace: string,
	purpose: 'database' | 'files' | 'metadata'
): Promise<Uint8Array<ArrayBuffer>> {
	workspaceId(workspace);
	if (key.length !== 32 || !['database', 'files', 'metadata'].includes(purpose)) throw invalid();
	const root = await crypto.subtle.importKey('raw', new Uint8Array(key), 'HKDF', false, [
		'deriveBits'
	]);
	return new Uint8Array(
		await crypto.subtle.deriveBits(
			{
				name: 'HKDF',
				hash: 'SHA-256',
				salt: encoder.encode(workspace),
				info: encoder.encode(`iris-workspace/v1/${purpose}`)
			},
			root,
			256
		)
	);
}
