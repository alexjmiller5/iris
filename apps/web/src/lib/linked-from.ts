import { writable } from 'svelte/store';
import type { MentionedByPage } from 'iris-core/client';

interface LinkedFromState extends MentionedByPage {
	loading: boolean;
	loaded: boolean;
	error: string;
}

/** One record's backlinks; the mentions index and its ordering live in core. */
export function createLinkedFrom(readPage: (offset: number) => Promise<MentionedByPage>) {
	let state: LinkedFromState = {
		rows: [],
		nextOffset: null,
		incomplete: false,
		loading: false,
		loaded: false,
		error: ''
	};
	const { subscribe, set } = writable(state);
	let generation = 0,
		disposed = false;
	const update = (patch: Partial<LinkedFromState>) => set((state = { ...state, ...patch }));
	return {
		subscribe,
		/** First page by default; `more` appends the next page and keeps rows on failure. */
		async load(more = false) {
			if (disposed || (more && (state.loading || state.nextOffset === null))) return;
			const version = ++generation;
			const offset = more ? state.nextOffset! : 0;
			update({ loading: true, error: '' });
			try {
				const page = await readPage(offset);
				if (disposed || version !== generation) return;
				const rows = more ? [...state.rows, ...page.rows] : page.rows;
				update({
					rows: [...new Map(rows.map((r) => [JSON.stringify([r.table, r.id]), r])).values()],
					nextOffset: page.nextOffset,
					incomplete: page.incomplete,
					loading: false,
					loaded: true
				});
			} catch (e) {
				if (!disposed && version === generation)
					update({ loading: false, error: e instanceof Error ? e.message : 'Links could not be loaded.' });
			}
		},
		dispose() {
			disposed = true;
			generation++;
		}
	};
}
