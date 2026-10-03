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
