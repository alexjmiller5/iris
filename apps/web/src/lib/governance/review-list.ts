import { writable } from 'svelte/store';
import type { ReadResult } from './contract';

/** Presentation cache only. clear invalidates all replies already in flight. */
export function createReviewList<T extends { id: string }>(
	read: (cursor?: string) => Promise<ReadResult<{ items: T[]; nextCursor: string | null }>>,
	onUnavailable: () => void
) {
	const empty = () => ({
		items: [] as T[],
		nextCursor: undefined as string | null | undefined,
		busy: false,
		error: ''
	});
	let state = empty();
	let generation = 0;
	let disposed = false;
	const store = writable(state);
	function clear() {
		generation++;
		state = empty();
		if (!disposed) store.set(state);
	}
	return {
		subscribe: store.subscribe,
		clear,
		dispose() {
			disposed = true;
			clear();
		},
		async more() {
			if (disposed || state.busy || state.nextCursor === null) return;
			const current = generation;
			state = { ...state, busy: true, error: '' };
			store.set(state);
			try {
				const result = await read(state.nextCursor ?? undefined);
				if (disposed || current !== generation) return;
				if (result.kind === 'unavailable') {
					clear();
					onUnavailable();
					state = { ...state, error: 'Content is unavailable.' };
				} else if (result.kind !== 'success')
					state = { ...state, busy: false, error: 'Could not load content. Retry online.' };
				else {
					const merged = new Map(state.items.map((item) => [item.id, item]));
					for (const item of result.value.items) merged.set(item.id, item);
					state = {
						items: [...merged.values()],
						nextCursor: result.value.nextCursor,
						busy: false,
						error: ''
					};
				}
			} catch {
				if (disposed || current !== generation) return;
				state = { ...state, busy: false, error: 'Could not load content. Retry online.' };
			}
			store.set(state);
		}
	};
}
