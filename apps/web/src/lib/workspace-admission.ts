/** Public durable revision storage is supplied by the encrypted workspace host. */
export interface WorkspaceRevisions {
	read(): Promise<number>;
	advance(): Promise<number>;
	subscribe(changed: () => void): () => void;
}
/** Admission only. The host must drain/close encrypted storage before close resolves. */
export function createWorkspaceAdmission<T>(options: {
	revisions: WorkspaceRevisions;
	close(resource: T): Promise<void>;
}) {
	let state: 'locked' | 'unlocking' | 'unlocked' | 'locking' = 'locked';
	let generation = 0;
	let revision = -1;
	let controller = new AbortController();
	let resource: T | undefined;
	let opening: Promise<void> | undefined;
	let closing: Promise<void> | undefined;
	let cleanupError: unknown;
	const denied = () => new Error('Workspace is locked.');
	const current = (version: number) =>
		state === 'unlocked' && version === generation && !controller.signal.aborted;
	async function dispose() {
		if (resource === undefined) return;
		const target = resource;
		await options.close(target);
		if (resource === target) resource = undefined;
	}
	function invalidate(): Promise<void> {
		if (closing) return closing;
		state = 'locking';
		generation++;
		controller.abort();
		const pending = opening;
		closing = (async () => {
			if (pending) await pending.catch(() => {});
			await dispose();
			state = 'locked';
			cleanupError = undefined;
		})();
		const finished = closing;
		void finished.then(
			() => {
				if (closing === finished) closing = undefined;
			},
			(error) => {
				cleanupError = error;
				if (closing === finished) closing = undefined;
			}
		);
		return finished;
	}
	async function readRevision() {
		const value = await options.revisions.read();
		if (!Number.isSafeInteger(value) || value < 0) throw denied();
		return value;
	}
	async function checkRevision() {
		try {
			return await readRevision();
		} catch {
			await invalidate().catch(() => {});
			throw denied();
		}
	}
	const unsubscribe = options.revisions.subscribe(() => {
		// A notification is only a hint. Every request also checks the durable revision.
		void readRevision()
			.then((value) => {
				if (value !== revision && (state === 'unlocked' || state === 'unlocking'))
					return invalidate();
			})
			.catch((error) => {
				cleanupError = error;
				void invalidate().catch((error) => {
					cleanupError = error;
				});
			});
	});
	return {
		get state() {
			return state;
		},
		get cleanupError() {
			return cleanupError;
		},
		async unlock(open: (signal: AbortSignal) => Promise<T>) {
			if (state !== 'locked' || opening || closing || resource !== undefined) throw denied();
			state = 'unlocking';
			const version = ++generation;
			controller = new AbortController();
			const signal = controller.signal;
			const task = (async () => {
				const at = await readRevision();
				if (version !== generation || signal.aborted) throw denied();
				revision = at;
				const target = await open(signal);
				resource = target;
				if (version !== generation || signal.aborted) {
					await dispose();
					throw denied();
				}
				if ((await readRevision()) !== at || version !== generation || signal.aborted) {
					await dispose();
					throw denied();
				}
				revision = at;
				state = 'unlocked';
			})();
			opening = task;
			try {
				await task;
			} catch (error) {
				if (version === generation) {
					controller.abort();
					if (resource !== undefined) {
						state = 'locking';
						cleanupError = error;
						await dispose();
					}
					state = 'locked';
				}
				throw error;
			} finally {
				if (opening === task) opening = undefined;
			}
		},
		async run<R>(operation: (resource: T, signal: AbortSignal) => Promise<R>): Promise<R> {
			const version = generation;
			if (!current(version) || resource === undefined) throw denied();
			if ((await checkRevision()) !== revision) {
				await invalidate().catch(() => {});
				throw denied();
			}
			if (!current(version) || resource === undefined) throw denied();
			const result = await operation(resource, controller.signal);
			if (!current(version)) throw denied();
			if ((await checkRevision()) !== revision) {
				await invalidate().catch(() => {});
				throw denied();
			}
			if (!current(version)) throw denied();
			return result;
		},
		async lock() {
			// Revoke local admission synchronously, even if advancing durable state fails.
			const stopped = invalidate();
			const advanced = options.revisions.advance();
			const results = await Promise.allSettled([stopped, advanced]);
			for (const result of results) if (result.status === 'rejected') throw result.reason;
		},
		async close() {
			unsubscribe();
			await invalidate();
		}
	};
}
