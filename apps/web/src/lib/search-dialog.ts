import { writable } from 'svelte/store';
import type { SearchHit } from 'life-ui-core/client';

export type Search = (text: string, offset: number) => Promise<SearchHit[]>;
export interface SearchState {
	text: string;
	hits: SearchHit[];
	loading: boolean;
	searched: boolean;
	error: string;
	hasMore: boolean;
	activeIndex: number;
}

export function createSearchModel(search: Search) {
	let state: SearchState = {
		text: '',
		hits: [],
		loading: false,
		searched: false,
		error: '',
		hasMore: false,
		activeIndex: -1
	};
	const { subscribe, set } = writable(state);
	let generation = 0;
	let nextOffset = 0;
	let disposed = false;
	let timer: ReturnType<typeof setTimeout> | undefined;
	function update(patch: Partial<SearchState>) {
		state = { ...state, ...patch };
		set(state);
	}
	async function request(offset: number, version: number) {
		update({ loading: true, error: '' });
		try {
			const page = await search(state.text.trim(), offset);
			if (disposed || version !== generation) return;
			// The index may change between pages. Keep one result per record while
			// advancing by fetched rows, including overlapping records.
			const hits = [
				...new Map(
					[...(offset === 0 ? [] : state.hits), ...page].map(
						(hit) => [JSON.stringify([hit.table, hit.id]), hit] as const
					)
				).values()
			];
			nextOffset = offset + page.length;
			update({
				hits,
				activeIndex: offset === 0 ? (page.length ? 0 : -1) : state.activeIndex,
				hasMore: page.length === 50,
				searched: true,
				loading: false
			});
		} catch (error) {
			if (disposed || version !== generation) return;
			update({
				error: error instanceof Error ? error.message : 'Search failed.',
				loading: false,
				searched: true
			});
		}
	}
	return {
		subscribe,
		setQuery(text: string) {
			if (disposed || text === state.text) return;
			clearTimeout(timer);
			const version = ++generation;
			nextOffset = 0;
			update({
				text,
				hits: [],
				loading: !!text.trim(),
				searched: false,
				error: '',
				hasMore: false,
				activeIndex: -1
			});
			if (text.trim())
				timer = setTimeout(() => {
					void request(0, version);
				}, 200);
		},
		async more() {
			if (disposed || state.loading || !state.hasMore) return;
			await request(nextOffset, generation);
		},
		async retry() {
			if (disposed || state.loading || !state.error || !state.text.trim()) return;
			await request(nextOffset, generation);
		},
		move(direction: -1 | 1) {
			if (disposed || !state.hits.length) return;
			update({
				activeIndex: (state.activeIndex + direction + state.hits.length) % state.hits.length
			});
		},
		select(index: number) {
			if (disposed || !Number.isInteger(index) || index < 0 || index >= state.hits.length) return;
			update({ activeIndex: index });
		},
		dispose() {
			disposed = true;
			generation++;
			clearTimeout(timer);
		}
	};
}
