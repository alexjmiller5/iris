import { createWorkerEncryptedCell } from './workspace-host-cell';
import { createWorkerFileStore } from './workspace-file-store';
type CellOptions = Parameters<typeof createWorkerEncryptedCell>[0];
type Tree = {
	version: 1;
	revision: string;
	exists: boolean;
	directories: string[][];
	files: { path: string[]; object: string; revision: string }[];
};
type Source = { exists: boolean; directories: string[][]; files: { path: string[]; file: File }[] };
const encoder = new TextEncoder(),
	decoder = new TextDecoder('utf-8', { fatal: true });
const fail = () => new Error('Complete retained file tree is unavailable.');
const uuid = (v: unknown): v is string =>
	typeof v === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(v);
const name = (v: unknown): v is string =>
	typeof v === 'string' &&
	v.length > 0 &&
	v.length <= 4096 &&
	v !== '.' &&
	v !== '..' &&
	!v.includes('/') &&
	!v.includes('\0');
const path = (v: unknown): v is string[] => Array.isArray(v) && v.length <= 64 && v.every(name);
const exact = (v: unknown, keys: string[]) =>
	!!v &&
	typeof v === 'object' &&
	!Array.isArray(v) &&
	Object.keys(v).length === keys.length &&
	keys.every((key) => Object.hasOwn(v, key));
const equal = (a: Uint8Array, b: Uint8Array) =>
	a.length === b.length && a.every((v, i) => v === b[i]);
const order = (a: string[], b: string[]) =>
	JSON.stringify(a) < JSON.stringify(b) ? -1 : JSON.stringify(a) > JSON.stringify(b) ? 1 : 0;
function decode(raw: Uint8Array | null): Tree | null {
	if (raw === null) return null;
	try {
		const value = JSON.parse(decoder.decode(raw));
		if (
			!exact(value, ['version', 'revision', 'exists', 'directories', 'files']) ||
			value.version !== 1 ||
			!uuid(value.revision) ||
			typeof value.exists !== 'boolean' ||
			!Array.isArray(value.directories) ||
			!Array.isArray(value.files) ||
			value.directories.length + value.files.length > 10000
		)
			throw fail();
		const dirs = new Set<string>(),
			all = new Set<string>(),
			objects = new Set<string>();
		for (const p of value.directories) {
			if (!path(p) || all.has(JSON.stringify(p))) throw fail();
			dirs.add(JSON.stringify(p));
			all.add(JSON.stringify(p));
		}
		if (value.exists ? !dirs.has('[]') : value.directories.length + value.files.length !== 0)
			throw fail();
		for (const entry of value.files) {
			if (
				!exact(entry, ['path', 'object', 'revision']) ||
				!path(entry.path) ||
				!entry.path.length ||
				!uuid(entry.object) ||
				!uuid(entry.revision) ||
				all.has(JSON.stringify(entry.path)) ||
				objects.has(entry.object)
			)
				throw fail();
			all.add(JSON.stringify(entry.path));
			objects.add(entry.object);
		}
		for (const p of [
			...value.directories,
			...value.files.map((entry: { path: string[] }) => entry.path)
		])
			if (p.length && !dirs.has(JSON.stringify(p.slice(0, -1)))) throw fail();
		value.directories.sort(order);
		value.files.sort((a: { path: string[] }, b: { path: string[] }) => order(a.path, b.path));
		return value;
	} catch {
		throw fail();
	}
}
async function capture(
	root: FileSystemDirectoryHandle | null,
	guard: () => Promise<void>
): Promise<Source> {
	const value: Source = { exists: root !== null, directories: [], files: [] };
	let bytes = 0;
	async function walk(dir: FileSystemDirectoryHandle, prefix: string[]) {
		await guard();
		if (dir.kind !== 'directory' || prefix.length > 64) throw fail();
		value.directories.push(prefix);
		const seen = new Set<string>();
		for await (const [entry, handle] of dir as unknown as AsyncIterable<
			[string, FileSystemHandle]
		>) {
			await guard();
			if (!name(entry) || seen.has(entry) || handle.name !== entry) throw fail();
			seen.add(entry);
			const next = [...prefix, entry];
			bytes += encoder.encode(JSON.stringify(next)).length;
			if (
				bytes > 8 * 1024 * 1024 ||
				value.directories.length + value.files.length >= 10000 ||
				next.length > 64
			)
				throw fail();
			if (handle.kind === 'directory') await walk(handle as FileSystemDirectoryHandle, next);
			else if (handle.kind === 'file') {
				const file = await (handle as FileSystemFileHandle).getFile();
				await guard();
				if (file.name !== entry) throw fail();
				value.files.push({ path: next, file });
			} else throw fail();
		}
	}
	if (root) await walk(root, []);
	value.directories.sort(order);
	value.files.sort((a, b) => order(a.path, b.path));
	return value;
}
/** Worker-private tree staging over encrypted cells. Includes empty directories,
 * all scopes/stages/orphans without an outbox refresh. Host owns namespace mapping,
 * exclusive migration lease and source-before/after checks. Never deletes sources.
 */
export async function createWorkerFileTree(
	options: Pick<CellOptions, 'admission' | 'openStore'> & { domain: 'files' | 'backups' }
) {
	const { admission, openStore, domain } = options;
	if (!['files', 'backups'].includes(domain)) throw fail();
	const manifest = await createWorkerEncryptedCell({
		admission,
		openStore,
		purpose: 'metadata',
		context: { store: 'retained-file-tree', id: domain }
	});
	let closed = false;
	async function guard() {
		if (closed) throw fail();
		const epoch = await manifest.read();
		epoch?.fill(0);
	}
	async function current() {
		if (closed) throw fail();
		const raw = await manifest.read();
		try {
			return { raw, value: decode(raw) };
		} catch (error) {
			raw?.fill(0);
			throw error;
		}
	}
	const file = (id: string) => createWorkerFileStore({ admission, openStore, domain, id });
	async function verify(value: Tree, source: Source) {
		if (
			value.exists !== source.exists ||
			JSON.stringify(value.directories) !== JSON.stringify(source.directories) ||
			JSON.stringify(value.files.map((entry) => entry.path)) !==
				JSON.stringify(source.files.map((entry) => entry.path))
		)
			throw fail();
		for (let i = 0; i < value.files.length; i++) {
			await guard();
			const sourceFile = source.files[i].file,
				entry = value.files[i],
				target = await file(entry.object);
			try {
				const metadata = await target.metadata();
				if (
					!metadata ||
					metadata.revision !== entry.revision ||
					metadata.name !== sourceFile.name ||
					metadata.type !== sourceFile.type ||
					metadata.lastModified !== sourceFile.lastModified ||
					metadata.size !== sourceFile.size
				)
					throw fail();
				let offset = 0;
				for await (const chunk of target.read()) {
					let expected: Uint8Array | undefined;
					try {
						await guard();
						expected = new Uint8Array(
							await sourceFile.slice(offset, offset + chunk.length).arrayBuffer()
						);
						await guard();
						if (!equal(chunk, expected)) throw fail();
						offset += chunk.length;
					} finally {
						chunk.fill(0);
						expected?.fill(0);
					}
				}
				if (offset !== sourceFile.size) throw fail();
			} finally {
				target.close();
			}
		}
		await guard();
	}
	return {
		async metadata() {
			const { raw, value } = await current();
			raw?.fill(0);
			return value;
		},
		async copy(expectedRevision: string | null, root: FileSystemDirectoryHandle | null) {
			const { raw, value } = await current();
			try {
				if ((value?.revision ?? null) !== expectedRevision)
					throw new Error('Retained tree changed concurrently.');
				const source = await capture(root, guard),
					next: Tree = {
						version: 1,
						revision: crypto.randomUUID(),
						exists: source.exists,
						directories: source.directories,
						files: []
					};
				for (const entry of source.files) {
					await guard();
					const object = crypto.randomUUID(),
						target = await file(object);
					try {
						await target.replace(null, entry.file);
						const metadata = await target.metadata();
						if (!metadata) throw fail();
						next.files.push({ path: entry.path, object, revision: metadata.revision });
					} finally {
						target.close();
					}
				}
				// Fresh source handles and full target byte comparison before publication.
				await verify(next, await capture(root, guard));
				const encoded = encoder.encode(JSON.stringify(next));
				try {
					if (encoded.length > 16 * 1024 * 1024) throw fail();
					await manifest.replace(raw, encoded);
				} finally {
					encoded.fill(0);
				}
			} finally {
				raw?.fill(0);
			}
		},
		async verify(root: FileSystemDirectoryHandle | null) {
			const { raw, value } = await current();
			if (!raw || !value) {
				raw?.fill(0);
				throw fail();
			}
			try {
				await verify(value, await capture(root, guard));
				const now = await manifest.read();
				try {
					if (!now || !equal(raw, now)) throw fail();
				} finally {
					now?.fill(0);
				}
				return true;
			} finally {
				raw.fill(0);
			}
		},
		close() {
			closed = true;
			manifest.close();
		}
	};
}
