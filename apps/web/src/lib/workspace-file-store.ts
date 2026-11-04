import { createWorkerEncryptedCell } from './workspace-host-cell';
const CHUNK = 1024 * 1024;
const MAX_FILE = 1024 * 1024 * 1024;
const encoder = new TextEncoder(),
	decoder = new TextDecoder('utf-8', { fatal: true });
const denied = () => new Error('Encrypted retained file is unavailable.');
type CellOptions = Parameters<typeof createWorkerEncryptedCell>[0];
type Metadata = {
	version: 1;
	revision: string;
	name: string;
	type: string;
	lastModified: number;
	size: number;
	chunks: number;
};
function metadata(raw: Uint8Array | null): Metadata | null {
	if (raw === null) return null;
	try {
		const v = JSON.parse(decoder.decode(raw));
		if (
			!v ||
			typeof v !== 'object' ||
			Object.keys(v).sort().join(',') !== 'chunks,lastModified,name,revision,size,type,version' ||
			v.version !== 1 ||
			typeof v.revision !== 'string' ||
			!/^[a-f0-9-]{36}$/.test(v.revision) ||
			typeof v.name !== 'string' ||
			!v.name.length ||
			v.name.length > 4096 ||
			typeof v.type !== 'string' ||
			v.type.length > 4096 ||
			!Number.isSafeInteger(v.lastModified) ||
			!Number.isSafeInteger(v.size) ||
			v.size < 0 ||
			v.size > MAX_FILE ||
			v.chunks !== Math.ceil(v.size / CHUNK)
		)
			throw denied();
		return v;
	} catch {
		throw denied();
	}
}
function equal(a: Uint8Array, b: Uint8Array) {
	return a.length === b.length && a.every((v, i) => v === b[i]);
}
/** Worker-only bounded copy/readback over the existing authenticated record seam.
 * Each fresh revision stages opaque chunks before publishing one CAS manifest.
 * Pre-publication failure retains prior publication and encrypted staging; a lost
 * post-CAS acknowledgement requires rereading the durable revision. Garbage collection is
 * deliberately separate from preservation. No plaintext OPFS writes or deletion.
 */
export async function createWorkerFileStore(
	options: Pick<CellOptions, 'admission' | 'openStore'> & {
		domain: 'files' | 'backups';
		id: string;
	}
) {
	const { admission, openStore, domain, id } = options;
	if (
		!['files', 'backups'].includes(domain) ||
		typeof id !== 'string' ||
		!id.length ||
		id.length > 256
	)
		throw denied();
	const manifest = await createWorkerEncryptedCell({
		admission,
		openStore,
		purpose: 'metadata',
		context: { store: 'retained-file-manifest', id: JSON.stringify([domain, id]) }
	});
	let closed = false;
	const guard = () => {
		if (closed) throw denied();
	};
	const chunk = (revision: string, index: number) =>
		createWorkerEncryptedCell({
			admission,
			openStore,
			purpose: 'files',
			context: { store: 'retained-file-chunk', id: JSON.stringify([domain, id, revision, index]) }
		});
	async function current() {
		guard();
		const raw = await manifest.read();
		try {
			return { raw, value: metadata(raw) };
		} catch (error) {
			raw?.fill(0);
			throw error;
		}
	}
	async function unchanged(raw: Uint8Array) {
		guard();
		const now = await manifest.read();
		try {
			if (now === null || !equal(raw, now)) throw denied();
		} finally {
			now?.fill(0);
		}
	}
	return {
		async metadata() {
			const { raw, value } = await current();
			raw?.fill(0);
			return value;
		},
		async replace(expectedRevision: string | null, source: File) {
			guard();
			if (
				!source ||
				!Number.isSafeInteger(source.size) ||
				source.size < 0 ||
				source.size > MAX_FILE ||
				typeof source.name !== 'string' ||
				!source.name.length ||
				source.name.length > 4096 ||
				typeof source.type !== 'string' ||
				source.type.length > 4096 ||
				!Number.isSafeInteger(source.lastModified) ||
				typeof source.slice !== 'function'
			)
				throw denied();
			const { raw, value } = await current();
			try {
				if ((value?.revision ?? null) !== expectedRevision)
					throw new Error('Retained file changed concurrently.');
				const next: Metadata = {
					version: 1,
					revision: crypto.randomUUID(),
					name: source.name,
					type: source.type,
					lastModified: source.lastModified,
					size: source.size,
					chunks: Math.ceil(source.size / CHUNK)
				};
				for (let index = 0; index < next.chunks; index++) {
					guard();
					// This read also binds the operation to the original unlock epoch.
					const epoch = await manifest.read();
					epoch?.fill(0);
					const begin = index * CHUNK,
						end = Math.min(begin + CHUNK, next.size);
					let input: Uint8Array | undefined,
						verify: Uint8Array | undefined,
						observed: Uint8Array | null = null;
					const cell = await chunk(next.revision, index);
					try {
						input = new Uint8Array(await source.slice(begin, end).arrayBuffer());
						if (input.length !== end - begin) throw denied();
						await cell.replace(null, input);
						observed = await cell.read();
						verify = new Uint8Array(await source.slice(begin, end).arrayBuffer());
						if (!observed || !equal(input, verify) || !equal(observed, verify)) throw denied();
					} finally {
						input?.fill(0);
						verify?.fill(0);
						observed?.fill(0);
						cell.close();
					}
				}
				guard();
				const encoded = encoder.encode(JSON.stringify(next));
				try {
					await manifest.replace(raw, encoded);
				} finally {
					encoded.fill(0);
				}
			} finally {
				raw?.fill(0);
			}
		},
		/** Caller owns/wipes each yielded chunk. Stage until successful exhaustion:
		 * a later missing/tampered chunk can reject after an authenticated prefix. */
		async *read(): AsyncGenerator<Uint8Array> {
			const { raw, value } = await current();
			if (!raw || !value) {
				raw?.fill(0);
				throw denied();
			}
			try {
				for (let index = 0; index < value.chunks; index++) {
					await unchanged(raw);
					const cell = await chunk(value.revision, index);
					let bytes: Uint8Array | null = null;
					try {
						bytes = await cell.read();
						if (!bytes || bytes.length !== Math.min(CHUNK, value.size - index * CHUNK))
							throw denied();
						await unchanged(raw);
						// Transfer before suspending: return/throw/break skips code after yield.
						const delivered = bytes;
						bytes = null;
						yield delivered;
					} finally {
						bytes?.fill(0);
						cell.close();
					}
				}
				await unchanged(raw);
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
