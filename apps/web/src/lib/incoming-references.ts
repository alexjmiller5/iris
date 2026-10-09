import { writable } from 'svelte/store';
import type { ReferenceSource, ReferencedByPage, WorkspaceRow } from 'iris-core/client';

export interface ReferenceGroup {
	key: string;
	source: ReferenceSource;
	rows: WorkspaceRow[];
	nextOffset: number | null;
	loaded: boolean;
	loading: boolean;
	error: string;
	viewUnavailable?: string;
}
interface ReferenceState {
	groups: ReferenceGroup[];
	loading: boolean;
	error: string;
}

/** One mounted record's transient presentation; queries and identity rules remain in core. */
export function createIncomingReferences(
	readSources: () => Promise<ReferenceSource[]>,
	readPage: (source: ReferenceSource, offset: number) => Promise<ReferencedByPage>
) {
	let state: ReferenceState = { groups: [], loading: false, error: '' };
	const { subscribe, set } = writable(state);
	let generation = 0,
		disposed = false;
	const current = (version: number) => !disposed && version === generation;
	const update = (patch: Partial<ReferenceState>) => {
		state = { ...state, ...patch };
		set(state);
	};
	const groupUpdate = (key: string, patch: Partial<ReferenceGroup>) =>
		update({ groups: state.groups.map((g) => (g.key === key ? { ...g, ...patch } : g)) });
	const message = (e: unknown) =>
		e instanceof Error ? e.message : 'Relationships could not be loaded.';
	return {
		subscribe,
		async refresh() {
			if (disposed) return;
			const version = ++generation;
			update({ groups: [], loading: true, error: '' });
			try {
				const sources = await readSources();
				if (current(version))
					update({
						groups: sources.map((source) => ({
							key: JSON.stringify([source.table, source.column]),
							source,
							rows: [],
							nextOffset: null,
							loaded: false,
							loading: false,
							error: ''
						})),
						loading: false
					});
			} catch (e) {
				if (current(version)) update({ error: message(e), loading: false });
			}
		},
		async load(key: string, more = false) {
			if (disposed) return;
			const group = state.groups.find((g) => g.key === key);
			if (
				!group ||
				group.loading ||
				(more ? !group.loaded || group.nextOffset === null : group.loaded)
			)
				return;
			const version = generation;
			groupUpdate(key, { loading: true, error: '' });
			try {
				const receipt = await readPage(group.source, more ? group.nextOffset! : 0);
				if (current(version))
					groupUpdate(key, {
						source: receipt.source,
						viewUnavailable: receipt.viewUnavailable,
						rows: [
							...new Map(
								[...group.rows, ...receipt.rows].map((row) => [row.record.id, row])
							).values()
						],
						nextOffset: receipt.nextOffset,
						loading: false,
						loaded: true
					});
			} catch (e) {
				if (current(version)) groupUpdate(key, { loading: false, error: message(e) });
			}
		},
		/** Data changed underneath: re-read opened groups' first page, keeping the list open. */
		async reload() {
			const version = generation;
			await Promise.all(
				state.groups
					.filter((g) => g.loaded && !g.loading)
					.map(async (group) => {
						try {
							const receipt = await readPage(group.source, 0);
							if (current(version))
								groupUpdate(group.key, {
									source: receipt.source,
									viewUnavailable: receipt.viewUnavailable,
									rows: receipt.rows,
									nextOffset: receipt.nextOffset,
									error: ''
								});
						} catch (e) {
							if (current(version)) groupUpdate(group.key, { error: message(e) });
						}
					})
			);
		},
		dispose() {
			disposed = true;
			generation++;
		}
	};
}
