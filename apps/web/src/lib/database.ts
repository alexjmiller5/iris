import { CORE_CONTRACT_HASH } from 'life-ui-core/contract';
import type { DatabaseArgs, DatabaseMethod, DatabaseResult } from './database-contract';

/** One dedicated worker per workspace; requests and shutdown preserve FIFO order. */
export class WorkspaceDatabase extends EventTarget {
	private worker: Worker;
	private nextId = 0;
	private closed = false;
	private pending = new Map<
		number,
		{ resolve: (value: unknown) => void; reject: (error: Error) => void }
	>();

	constructor() {
		super();
		this.worker = new Worker(new URL('./database.worker.ts', import.meta.url), { type: 'module' });
		this.worker.onmessage = ({ data }) => {
			if (data.contractHash !== CORE_CONTRACT_HASH) {
				this.stop(new Error('Core contract does not match the database worker. Reload the app.'));
				return;
			}
			if (data.changed) {
				// detail: the database method that changed data, here or in another tab.
				this.dispatchEvent(new CustomEvent('change', { detail: data.changed }));
				return;
			}
			const pending = this.pending.get(data.id);
			if (!pending) return;
			this.pending.delete(data.id);
			if (data.error) pending.reject(Object.assign(new Error(data.error.message), data.error));
			else pending.resolve(data.result);
		};
		this.worker.onerror = (event) => {
			event.preventDefault();
			this.stop(new Error('Database worker failed. Persistent storage is unavailable.'));
		};
		this.worker.onmessageerror = () =>
			this.stop(new Error('Database worker returned an unreadable response.'));
	}

	request<M extends DatabaseMethod>(
		method: M,
		...input: {} extends DatabaseArgs<M> ? [args?: DatabaseArgs<M>] : [args: DatabaseArgs<M>]
	): Promise<DatabaseResult<M>> {
		const args = input[0] ?? {};
		if (this.closed) return Promise.reject(new Error('Database is closed.'));
		const id = ++this.nextId;
		return new Promise<DatabaseResult<M>>((resolve, reject) => {
			this.pending.set(id, { resolve: (value) => resolve(value as DatabaseResult<M>), reject });
			try {
				this.worker.postMessage({ id, method, args, contractHash: CORE_CONTRACT_HASH });
			} catch (error) {
				this.pending.delete(id);
				reject(error);
			}
		});
	}

	close(): void {
		if (this.closed) return;
		// Let queued writes commit and SQLite close its handles before terminating.
		const closing = this.request('close');
		this.closed = true;
		void closing.then(
			() => this.stop(),
			() => this.stop()
		);
	}

	private stop(error = new Error('Database is closed.')) {
		this.closed = true;
		this.worker.terminate();
		for (const pending of this.pending.values()) pending.reject(error);
		this.pending.clear();
	}
}
