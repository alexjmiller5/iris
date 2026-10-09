import { writable } from 'svelte/store';
import type { RejectedEdit, RejectionsPage } from 'iris-core/client';

export interface RejectionSnapshot {
	page: RejectionsPage | null;
	error: string;
}

const message = (error: unknown) =>
	error instanceof Error ? error.message : 'Could not read rejected edits. Try again.';

// A damaged inbox must remain visible without preventing the workspace opening.
export async function rejectionSnapshot(
	read: () => RejectionsPage | Promise<RejectionsPage>
): Promise<RejectionSnapshot> {
	try {
		return { page: await read(), error: '' };
	} catch (error) {
		return { page: null, error: message(error) };
	}
}

export function createRejectionInbox(read: (offset: number) => Promise<RejectionsPage>) {
	let generation = 0;
	let disposed = false;
	let state = {
		total: 0,
		entries: [] as RejectedEdit[],
		nextOffset: null as number | null,
		loading: false,
		error: ''
	};
	const store = writable(state);
	const publish = () => store.set(state);
	return {
		subscribe: store.subscribe,
		reset(total: number, snapshot: RejectionSnapshot) {
			if (disposed) return;
			generation++;
			state = {
				total,
				entries: snapshot.page?.rejections ?? [],
				nextOffset: snapshot.page ? snapshot.page.nextOffset : 0,
				loading: false,
				error: snapshot.error
			};
			publish();
		},
		async more() {
			if (disposed || state.loading || state.nextOffset === null) return;
			const request = generation,
				offset = state.nextOffset;
			state = { ...state, loading: true, error: '' };
			publish();
			try {
				const page = await read(offset);
				if (disposed || request !== generation) return;
				const entries = new Map(
					state.entries.map((entry) => [JSON.stringify([entry.table, entry.rowID]), entry])
				);
				for (const entry of page.rejections)
					entries.set(JSON.stringify([entry.table, entry.rowID]), entry);
				state = {
					...state,
					entries: [...entries.values()],
					nextOffset: page.nextOffset,
					loading: false
				};
			} catch (error) {
				if (disposed || request !== generation) return;
				state = { ...state, error: message(error), loading: false };
			}
			publish();
		},
		dispose() {
			disposed = true;
			generation++;
		}
	};
}
