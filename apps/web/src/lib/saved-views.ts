import { writable } from 'svelte/store';

export type SavedViewAction = 'choose' | 'save' | 'update' | 'delete';
type State = { name: string; pending: SavedViewAction | null; error: string; confirming: boolean };

export function createSavedViewsModel() {
	let state: State = { name: '', pending: null, error: '', confirming: false };
	const { subscribe, set } = writable(state);
	let context: string | undefined;
	let savedName = '';
	let generation = 0;
	let disposed = false;
	function update(patch: Partial<State>) {
		state = { ...state, ...patch };
		set(state);
	}
	return {
		subscribe,
		setContext(identity: string, name: string) {
			if (disposed) return;
			if (context !== identity) {
				context = identity;
				generation++;
				update({ name, pending: null, error: '', confirming: false });
			} else if (state.name === savedName) update({ name });
			savedName = name;
		},
		setName(name: string) {
			if (!disposed) update({ name, error: '' });
		},
		confirmDelete(confirming: boolean) {
			if (!disposed && !state.pending) update({ confirming, error: '' });
		},
		async run(action: SavedViewAction, operation: () => Promise<boolean | void>) {
			if (disposed || state.pending) return false;
			const version = ++generation;
			const current = () => !disposed && version === generation;
			update({ pending: action, error: '' });
			try {
				const accepted = await operation();
				if (!current() || accepted === false) return false;
				update({ confirming: false });
				return true;
			} catch (error) {
				if (current())
					update({ error: error instanceof Error ? error.message : 'The request failed.' });
				return false;
			} finally {
				if (current()) update({ pending: null });
			}
		},
		dispose() {
			disposed = true;
			generation++;
		}
	};
}

/** Saves the applied view like a Notion cell: every change applies at once and
 * is written after a quiet period, but not while a popover is open. `capture`
 * snapshots the view synchronously, so a later context change cannot leak into
 * it; writes never overlap. A failed write is reported once; the next change
 * retries. */
export function createViewAutosave<T>(
	capture: () => T,
	write: (snapshot: T) => Promise<void>,
	onerror: (error: Error) => void,
	delay = 500
) {
	const { subscribe, set } = writable({ pending: false });
	let timer: ReturnType<typeof setTimeout> | undefined;
	let dirty = false,
		held = false,
		running = 0,
		disposed = false;
	let chain = Promise.resolve();
	const publish = () => set({ pending: !disposed && (dirty || running > 0) });
	function arm() {
		clearTimeout(timer);
		if (!held && dirty && !disposed) timer = setTimeout(() => void flush(), delay);
	}
	function flush(): Promise<void> {
		clearTimeout(timer);
		if (!dirty || disposed) return chain;
		dirty = false;
		const snapshot = capture();
		running++;
		publish();
		chain = chain
			.then(() => write(snapshot))
			.catch((error) => {
				if (!disposed) onerror(error instanceof Error ? error : new Error('The view was not saved.'));
			})
			.finally(() => {
				running--;
				publish();
			});
		return chain;
	}
	return {
		subscribe,
		flush,
		change() {
			if (disposed) return;
			dirty = true;
			publish();
			arm();
		},
		hold(open: boolean) {
			held = open;
			if (open) clearTimeout(timer);
			else arm();
		},
		dispose() {
			disposed = true;
			clearTimeout(timer);
			publish();
		}
	};
}
