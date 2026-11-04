import type { WorkspaceMigrationSnapshot } from './workspace-migration';
import type { HubConnection } from './device-enrollment';
const encoder = new TextEncoder();
const unavailable = () => new Error('Complete retained workspace inventory is unavailable.');
function framed(value: unknown) {
	return encoder.encode(JSON.stringify(value));
}
/** Hash the bytes just read, never the cached checksum in attachment JSON. This
 * bounded whole-blob seam matches existing 128MiB attachments. Larger backups
 * must wait for a reviewed streaming adapter; they are never skipped/truncated.
 */
async function fingerprint(file: File, signal?: AbortSignal) {
	signal?.throwIfAborted();
	if (
		!Number.isSafeInteger(file.size) ||
		file.size < 0 ||
		file.size > 128 * 1024 * 1024 ||
		!Number.isSafeInteger(file.lastModified) ||
		typeof file.type !== 'string'
	)
		throw unavailable();
	const bytes = new Uint8Array(await file.arrayBuffer());
	try {
		signal?.throwIfAborted();
		if (bytes.byteLength !== file.size) throw unavailable();
		const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
		signal?.throwIfAborted();
		return {
			bytes: file.size,
			modified: file.lastModified,
			mime: file.type,
			sha256: Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('')
		};
	} finally {
		bytes.fill(0);
	}
}
/** Raw readonly traversal includes every scope, stage/orphan file and backup lane.
 * Do not call AttachmentOutbox.refresh: it normalizes states and removes stages.
 * The owner must retire legacy writers and compare fresh captures before/after copy.
 * Logical paths/metadata must themselves be encrypted by the target adapter.
 */
export async function collectLegacyFileInventory(
	root: FileSystemDirectoryHandle,
	options: { signal?: AbortSignal } = {}
): Promise<Pick<WorkspaceMigrationSnapshot, 'files' | 'backups'>> {
	const result: Pick<WorkspaceMigrationSnapshot, 'files' | 'backups'> = { files: [], backups: [] };
	let budget = 0,
		nodes = 0;
	const guard = () => options.signal?.throwIfAborted();
	const add = (domain: 'files' | 'backups', key: string, value: unknown) => {
		const bytes = framed(value);
		budget += encoder.encode(key).length + bytes.length;
		if (budget > 64 * 1024 * 1024 || ++nodes > 100000)
			throw new Error('Retained file inventory requires a streaming host.');
		result[domain].push({ key, value: bytes });
	};
	async function walk(
		directory: FileSystemDirectoryHandle,
		path: string[],
		domain: 'files' | 'backups'
	) {
		guard();
		if (path.length > 64) throw unavailable();
		add(domain, JSON.stringify(['directory', ...path]), { kind: 'directory' });
		const seen = new Set<string>();
		for await (const entry of directory as unknown as AsyncIterable<[string, FileSystemHandle]>) {
			guard();
			const [name, handle] = entry;
			if (
				typeof name !== 'string' ||
				!name.length ||
				name.length > 4096 ||
				name === '.' ||
				name === '..' ||
				name.includes('/') ||
				name.includes('\0') ||
				seen.has(name) ||
				!handle ||
				handle.name !== name
			)
				throw unavailable();
			seen.add(name);
			const next = [...path, name];
			if (handle.kind === 'directory')
				await walk(handle as FileSystemDirectoryHandle, next, domain);
			else if (handle.kind === 'file') {
				const file = await (handle as FileSystemFileHandle).getFile();
				guard();
				if (file.name !== name) throw unavailable();
				add(domain, JSON.stringify(['file', ...next]), await fingerprint(file, options.signal));
			} else throw unavailable();
		}
	}
	for (const [name, domain] of [
		['iris-attachments', 'files'],
		['backups', 'backups']
	] as const) {
		guard();
		let directory: FileSystemDirectoryHandle;
		try {
			directory = await root.getDirectoryHandle(name, { create: false });
		} catch (error) {
			if (error instanceof DOMException && error.name === 'NotFoundError') {
				add(domain, JSON.stringify(['root']), { exists: false });
				continue;
			}
			throw error;
		}
		guard();
		if (directory.kind !== 'directory') throw unavailable();
		add(domain, JSON.stringify(['root']), { exists: true });
		await walk(directory, [], domain);
		result[domain].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
	}
	guard();
	return result;
}
type ReadStorage = Pick<Storage, 'length' | 'key' | 'getItem'>;
/** Preserve raw strings/code units, including unreadable old JSON. No UI parser
 * trimming recents or choosing defaults is allowed in preservation evidence.
 * Two matching reads detect ordinary capture races, not cross-store atomicity.
 */
export function collectWebStorageInventory(
	storage: ReadStorage
): Pick<WorkspaceMigrationSnapshot, 'recents' | 'preferences'> {
	function read() {
		const length = storage.length;
		if (!Number.isSafeInteger(length) || length < 0 || length > 100000) throw unavailable();
		const values = new Map<string, string>();
		let budget = 0;
		for (let index = 0; index < length; index++) {
			const key = storage.key(index);
			if (typeof key !== 'string' || values.has(key)) throw unavailable();
			const value = storage.getItem(key);
			if (typeof value !== 'string') throw unavailable();
			budget += framed([key, value]).length;
			if (budget > 64 * 1024 * 1024) throw unavailable();
			values.set(key, value);
		}
		if (storage.length !== length) throw unavailable();
		return [...values].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
	}
	const before = read(),
		after = read();
	if (JSON.stringify(before) !== JSON.stringify(after))
		throw new Error('Retained preferences changed during inventory.');
	const out: Pick<WorkspaceMigrationSnapshot, 'recents' | 'preferences'> = {
		recents: [],
		preferences: []
	};
	for (const [key, value] of before)
		out[key.startsWith('iris:recents:') ? 'recents' : 'preferences'].push({
			key: JSON.stringify(['localStorage', key]),
			value: framed(value)
		});
	return out;
}
/** Worker/migration-owner input only. This serializes the existing consumer
 * connection; it neither authenticates, fetches nor mints a broader credential.
 * Never send this inventory or its decrypted value through the page journal proxy.
 */
export function collectConsumerCredentialInventory(
	connection: Readonly<HubConnection> | null
): WorkspaceMigrationSnapshot['credential'] {
	if (
		connection !== null &&
		(!connection ||
			typeof connection !== 'object' ||
			Array.isArray(connection) ||
			Object.keys(connection).length !== 2 ||
			!Object.hasOwn(connection, 'endpoint') ||
			!Object.hasOwn(connection, 'token') ||
			typeof connection.endpoint !== 'string' ||
			!connection.endpoint.length ||
			typeof connection.token !== 'string' ||
			!connection.token.length ||
			connection.endpoint.length > 65536 ||
			connection.token.length > 65536)
	)
		throw unavailable();
	const bytes = framed(
		connection === null ? null : { endpoint: connection.endpoint, token: connection.token }
	);
	if (bytes.length > 65536) throw unavailable();
	return [{ key: 'consumer', value: bytes }];
}

export type OpfsOwnerEntry = {
	name: string;
	kind: 'file' | 'directory';
	owner: string;
};
/** Exact host-supplied ownership, never prefix inference. Include SQLite/VFS
 * sidecars explicitly. This proves namespace coverage, not file preservation:
 * legacy writers must be retired and each declared owner must collect its values.
 */
export async function collectOpfsOwnerInventory(
	root: FileSystemDirectoryHandle,
	declarations: readonly OpfsOwnerEntry[],
	signal?: AbortSignal
): Promise<OpfsOwnerEntry[]> {
	const validName = (value: unknown): value is string =>
		typeof value === 'string' &&
		value.length > 0 &&
		value.length <= 4096 &&
		value !== '.' &&
		value !== '..' &&
		!value.includes('/') &&
		!value.includes('\0');
	if (!Array.isArray(declarations) || declarations.length > 100000) throw unavailable();
	const expected = new Map<string, OpfsOwnerEntry>();
	for (const entry of declarations) {
		if (
			!entry ||
			!validName(entry.name) ||
			!validName(entry.owner) ||
			!['file', 'directory'].includes(entry.kind) ||
			expected.has(entry.name)
		)
			throw unavailable();
		expected.set(entry.name, { name: entry.name, kind: entry.kind, owner: entry.owner });
	}
	async function capture() {
		signal?.throwIfAborted();
		const seen = new Set<string>();
		for await (const [name, handle] of root as unknown as AsyncIterable<
			[string, FileSystemHandle]
		>) {
			signal?.throwIfAborted();
			const declared = expected.get(name);
			if (
				!declared ||
				seen.has(name) ||
				!handle ||
				handle.name !== name ||
				handle.kind !== declared.kind
			)
				throw unavailable();
			seen.add(name);
		}
		signal?.throwIfAborted();
		if (seen.size !== expected.size) throw unavailable();
	}
	await capture();
	await capture();
	return [...expected.values()].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}
