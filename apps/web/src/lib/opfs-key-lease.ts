import { SQLITE_BUSY, SQLITE_LOCK_NONE, SQLITE_LOCK_SHARED, SQLITE_OK } from 'wa-sqlite';

interface KeyLeaseVfs {
	jLock(fileId: number, mode: number): number;
	jUnlock(fileId: number, mode: number): number;
}
export interface OpfsKeyLease {
	vfs: KeyLeaseVfs;
	module: { retryOps: Promise<unknown>[] };
	fileId: number;
	signal?: AbortSignal;
}
async function settlePending(pending: Promise<unknown>[], signal?: AbortSignal) {
	const settled = Promise.allSettled(pending);
	let abort: (() => void) | undefined;
	try {
		const results = signal
			? await Promise.race([
					settled,
					new Promise<never>((_resolve, reject) => {
						abort = () => reject(signal.reason);
						signal.addEventListener('abort', abort, { once: true });
						if (signal.aborted) abort();
					})
				])
			: await settled;
		const failure = results.find((result) => result.status === 'rejected');
		if (failure?.status === 'rejected') throw failure.reason;
	} finally {
		if (abort) signal?.removeEventListener('abort', abort);
	}
}
/** The caller must hold the workspace dispatch lock and supply its main-file id.
 * SQLite's initial unlocked header read releases OPFS access. SQLite3MC's C-key
 * setup then reads the salt without taking a pager lock, so acquire the existing
 * VFS shared lease around key setup. This adds no cipher or file format.
 * On any failure the caller must discard/close the connection; cancellation
 * cannot cancel the VFS's private pending acquisition, so terminate its worker.
 */
export async function withOpfsKeyLease<T>(options: OpfsKeyLease, bind: () => T): Promise<T> {
	if (!Number.isSafeInteger(options.fileId) || options.fileId <= 0)
		throw new Error('Missing main database file.');
	options.signal?.throwIfAborted();
	let attempted = false,
		failed = false,
		primary: unknown;
	try {
		// Match wa-sqlite's bounded retry protocol, not a hot busy loop.
		for (let attempt = 0; attempt < 2; attempt++) {
			options.signal?.throwIfAborted();
			attempted = true;
			const rc = options.vfs.jLock(options.fileId, SQLITE_LOCK_SHARED);
			if (rc === SQLITE_OK) {
				options.signal?.throwIfAborted();
				const value = await bind();
				options.signal?.throwIfAborted();
				return value;
			}
			if (rc !== SQLITE_BUSY || options.module.retryOps.length === 0)
				throw new Error('Cannot acquire database key lease.');
			await settlePending(options.module.retryOps.splice(0), options.signal);
		}
		throw new Error('Database key lease remained busy.');
	} catch (error) {
		failed = true;
		primary = error;
		throw error;
	} finally {
		if (attempted && options.vfs.jUnlock(options.fileId, SQLITE_LOCK_NONE) !== SQLITE_OK) {
			const cleanup = new Error('Cannot release database key lease.');
			throw failed
				? new AggregateError([primary, cleanup], 'Database key setup and cleanup failed.')
				: cleanup;
		}
	}
}
