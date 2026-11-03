import { withOpfsKeyLease, type OpfsKeyLease } from './opfs-key-lease';
interface KeyModule {
	retryOps: Promise<unknown>[];
	HEAPU8: Uint8Array;
	_malloc(length: number): number;
	_free(pointer: number): void;
}
interface DatabaseKeyOptions extends OpfsKeyLease {
	vfs: OpfsKeyLease['vfs'] & { lastError: unknown };
	module: KeyModule;
	connection: number;
	key: Uint8Array;
	bind(connection: number, schema: string, pointer: number, length: number): number;
}
/** C-key boundary for an already opened MC connection. No SQL, URI key or logs.
 * The caller owns the dispatch lock and must close/terminate on any failure.
 * This remains unwired until the encrypted engine and host admission are promoted.
 */
export async function bindWorkspaceDatabaseKey(options: DatabaseKeyOptions): Promise<void> {
	if (
		!(options.key instanceof Uint8Array) ||
		options.key.byteLength !== 32 ||
		!Number.isSafeInteger(options.connection) ||
		options.connection <= 0
	)
		throw new Error('Invalid workspace database key.');
	if (!Object.hasOwn(options.vfs, 'lastError')) throw new Error('Cannot observe database key I/O.');
	await withOpfsKeyLease(options, () => {
		const raw = new Uint8Array(36);
		raw.set([114, 97, 119, 58]);
		raw.set(options.key, 4);
		let pointer = 0;
		try {
			pointer = options.module._malloc(raw.length);
			if (
				!Number.isSafeInteger(pointer) ||
				pointer <= 0 ||
				pointer + raw.length > options.module.HEAPU8.length
			) {
				pointer = 0;
				throw new Error('Cannot allocate workspace database key.');
			}
			options.module.HEAPU8.set(raw, pointer);
			options.vfs.lastError = null;
			const rc = options.bind(options.connection, 'main', pointer, raw.length);
			if (rc !== 0 || options.vfs.lastError !== null)
				throw new Error('Cannot configure workspace database key.', {
					cause: options.vfs.lastError
				});
		} finally {
			raw.fill(0);
			if (pointer) {
				options.module.HEAPU8.fill(0, pointer, pointer + 36);
				options.module._free(pointer);
			}
		}
	});
}
