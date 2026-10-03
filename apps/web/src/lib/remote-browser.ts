import { writable } from 'svelte/store';
import type { RemoteRecord, RemoteRowsPage, RemoteRowResult } from 'life-ui-core/client';

export interface OnlineState {
	rows: RemoteRecord[];
	nextCursor: string | null;
	selected: RemoteRecord | null;
	loading: boolean;
	error: string;
}

/** Transient presentation only. The shared core validates each bounded receipt. */
export function createRemoteBrowser(
	readPage: (cursor?: string) => Promise<RemoteRowsPage>,
	readRow: (id: string) => Promise<RemoteRowResult>
) {
	let state: OnlineState = {
		rows: [],
		nextCursor: null,
		selected: null,
		loading: false,
		error: ''
	};
	const { subscribe, set } = writable(state);
	let generation = 0,
		disposed = false;
	const update = (patch: Partial<OnlineState>) => {
		state = { ...state, ...patch };
		set(state);
	};
	const current = (version: number) => !disposed && generation === version;
	async function page(cursor?: string) {
		if (disposed) return;
		const version = ++generation;
		update({
			loading: true,
			error: '',
			...(cursor === undefined ? { rows: [], nextCursor: null, selected: null } : {})
		});
		try {
			const receipt = await readPage(cursor);
			if (!current(version)) return;
			update({
				rows: [
					...new Map([...state.rows, ...receipt.rows].map((row) => [row.record.id, row])).values()
				],
				nextCursor: receipt.nextCursor,
				loading: false
			});
		} catch (error) {
			if (current(version))
				update({
					error: error instanceof Error ? error.message : 'Online records could not be loaded.',
					loading: false
				});
		}
	}
	return {
		subscribe,
		refresh: () => page(),
		async more() {
			if (!disposed && !state.loading && state.nextCursor !== null) await page(state.nextCursor);
		},
		async open(id: string) {
			if (disposed || state.loading) return;
			const version = ++generation;
			update({ loading: true, error: '', selected: null });
			try {
				const { row } = await readRow(id);
				if (current(version))
					update({
						selected: row,
						loading: false,
						error: row ? '' : 'This record was not found on the hub.'
					});
			} catch (error) {
				if (current(version))
					update({
						error:
							error instanceof Error ? error.message : 'This online record could not be loaded.',
						loading: false
					});
			}
		},
		back() {
			if (!disposed) {
				generation++;
				update({ selected: null, error: '', loading: false });
			}
		},
		dispose() {
			disposed = true;
			generation++;
		}
	};
}
