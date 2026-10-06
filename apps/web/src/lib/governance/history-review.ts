import { writable } from 'svelte/store';

export interface HistoryReviewState<Preview> {
	selected: string[];
	preview: Preview | null;
	loading: boolean;
	error: string;
}

/** Presentation state only. The injected core owns all inverse/preview semantics. */
export function createHistoryReview<Preview>(preview: (eventIDs: string[]) => Promise<Preview>) {
	let generation = 0;
	let disposed = false;
	const empty = (): HistoryReviewState<Preview> => ({
		selected: [],
		preview: null,
		loading: false,
		error: ''
	});
	let state = empty();
	const store = writable(state);
	const publish = () => store.set(state);
	return {
		subscribe: store.subscribe,
		select(eventID: string, selected: boolean) {
			if (disposed || state.selected.includes(eventID) === selected) return;
			generation++;
			state = {
				...empty(),
				selected: selected
					? [...state.selected, eventID]
					: state.selected.filter((id) => id !== eventID)
			};
			publish();
		},
		async review() {
			if (disposed || state.loading || !state.selected.length) return;
			const request = ++generation;
			state = { ...state, preview: null, loading: true, error: '' };
			publish();
			try {
				const result = await preview([...state.selected]);
				if (disposed || request !== generation) return;
				state = { ...state, preview: result, loading: false };
			} catch (error) {
				if (disposed || request !== generation) return;
				state = {
					...state,
					loading: false,
					error: error instanceof Error ? error.message : 'Could not preview selected changes.'
				};
			}
			publish();
		},
		reset() {
			if (disposed) return;
			generation++;
			state = empty();
			publish();
		},
		dispose() {
			disposed = true;
			generation++;
		}
	};
}
