/** One dedicated worker per workspace; requests and shutdown preserve FIFO order. */
export class WorkspaceDatabase extends EventTarget {
	private worker: Worker;
	private nextId = 0;
	private closed = false;
	private pending = new Map<
		number,
		{ resolve: (value: any) => void; reject: (error: Error) => void }
	>();

	constructor() {
		super();
		this.worker = new Worker(new URL('./database.worker.ts', import.meta.url), { type: 'module' });
		this.worker.onmessage = ({ data }) => {
			if (data.changed) {
				this.dispatchEvent(new Event('change'));
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

	request(method: string, args: Record<string, unknown> = {}): Promise<any> {
		if (this.closed) return Promise.reject(new Error('Database is closed.'));
		const id = ++this.nextId;
		return new Promise((resolve, reject) => {
			this.pending.set(id, { resolve, reject });
			try {
				this.worker.postMessage({ id, method, args });
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
