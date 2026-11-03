import type { WorkspaceMigrationSnapshot } from './workspace-migration';
type Part = Pick<WorkspaceMigrationSnapshot, 'governance-journal' | 'changeset-journal'>;
const journals = [
	['iris-governance', 'governance-journal'],
	['iris-changesets', 'changeset-journal']
] as const;
const encoder = new TextEncoder();
const unavailable = () => new Error('Complete legacy journal inventory is unavailable.');
/** Read BOTH whole legacy stores, not just the current principal. Preserve raw
 * strings (including unreadable pending requests) and sensitive scope keys exactly.
 * This never assigns unknown legacy scopes to a new endpoint, decrypts credentials,
 * creates a missing store, copies data or authorizes plaintext cleanup.
 */
export async function collectLegacyJournalInventory(
	factory: IDBFactory | undefined = globalThis.indexedDB,
	options: { signal?: AbortSignal } = {}
): Promise<Part> {
	if (!factory || typeof factory.databases !== 'function') throw unavailable();
	const guard = () => options.signal?.throwIfAborted();
	guard();
	const listed = await factory.databases();
	guard();
	const result: Part = { 'governance-journal': [], 'changeset-journal': [] };
	let budget = 0;
	const add = (domain: keyof Part, key: string, value: unknown) => {
		const bytes = encoder.encode(JSON.stringify(value));
		budget += encoder.encode(key).length + bytes.length;
		if (budget > 64 * 1024 * 1024)
			throw new Error('Legacy journal inventory requires a streaming host.');
		result[domain].push({ key, value: bytes });
	};
	for (const [name, domain] of journals) {
		guard();
		const matches = listed.filter((db) => db.name === name);
		if (matches.length > 1 || (matches.length === 1 && matches[0].version !== 1))
			throw unavailable();
		if (!matches.length) {
			add(domain, JSON.stringify([name, 'schema']), { exists: false });
			continue;
		}
		const db = await new Promise<IDBDatabase>((resolve, reject) => {
			const opening = factory.open(name, 1);
			let failed = false;
			opening.onblocked = () => {
				failed = true;
				reject(new Error('Legacy journal inventory is blocked.'));
			};
			opening.onupgradeneeded = () => {
				failed = true;
				opening.transaction?.abort();
				reject(new Error('Listed legacy journal disappeared.'));
			};
			opening.onerror = () => reject(opening.error ?? unavailable());
			opening.onsuccess = () => {
				const opened = opening.result;
				if (
					failed ||
					opened.version !== 1 ||
					opened.objectStoreNames.length !== 1 ||
					!opened.objectStoreNames.contains('pending')
				) {
					opened.close();
					reject(unavailable());
					return;
				}
				resolve(opened);
			};
		});
		let changed = false,
			active: IDBTransaction | undefined;
		db.onversionchange = () => {
			changed = true;
			try {
				active?.abort();
			} catch {
				/* already finished */
			}
			db.close();
		};
		const cancel = () => {
			try {
				active?.abort();
			} catch {
				/* already finished */
			}
		};
		try {
			guard();
			options.signal?.addEventListener('abort', cancel, { once: true });
			await new Promise<void>((resolve, reject) => {
				let failure: unknown;
				const fail = (error: unknown) => {
					failure = error;
					try {
						active?.abort();
					} catch {
						reject(error);
					}
				};
				try {
					active = db.transaction('pending', 'readonly');
					const tx = active;
					tx.oncomplete = () => {
						if (changed || options.signal?.aborted) reject(unavailable());
						else resolve();
					};
					tx.onabort = () => reject(failure ?? tx.error ?? unavailable());
					tx.onerror = () => {
						failure ??= tx.error;
					};
					const store = tx.objectStore('pending');
					if (store.keyPath !== null || store.autoIncrement || store.indexNames.length !== 0)
						throw unavailable();
					add(domain, JSON.stringify([name, 'schema']), {
						exists: true,
						version: db.version,
						store: 'pending',
						keyPath: null,
						autoIncrement: false,
						indexes: []
					});
					const request = store.openCursor();
					request.onsuccess = () => {
						try {
							guard();
							if (changed) throw unavailable();
							const cursor = request.result;
							if (cursor === null) return;
							if (
								typeof cursor.key !== 'string' ||
								!cursor.key.length ||
								typeof cursor.value !== 'string'
							)
								throw unavailable();
							if (cursor.key.length > 1048576 || cursor.value.length > 1048576)
								throw new Error('Legacy journal entry requires a streaming host.');
							add(domain, JSON.stringify([name, 'pending', cursor.key]), cursor.value);
							cursor.continue();
						} catch (error) {
							fail(error);
						}
					};
				} catch (error) {
					if (active) fail(error);
					else reject(error);
				}
			});
			guard();
			if (changed) throw unavailable();
		} finally {
			options.signal?.removeEventListener('abort', cancel);
			db.onversionchange = null;
			db.close();
		}
		result[domain].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
	}
	return result;
}
