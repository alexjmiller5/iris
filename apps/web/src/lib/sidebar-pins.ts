import type {
	MoveTablePinArgs,
	PinTableArgs,
	Row,
	SidebarPin,
	SidebarPinList,
	UnpinTableArgs
} from 'iris-core/client';

export interface PinAPI {
	list(): Promise<SidebarPinList>;
	pin(args: PinTableArgs): Promise<SidebarPinList>;
	unpin(args: UnpinTableArgs): Promise<SidebarPinList>;
	move(args: MoveTablePinArgs): Promise<SidebarPinList>;
}
export interface PinState {
	snapshot: SidebarPinList | null;
	loading: boolean;
	busy: boolean;
	error: string | null;
}
const empty = (): PinState => ({ snapshot: null, loading: false, busy: false, error: null });
export function unpinnedTables(tables: Row[], pins: SidebarPin[]): Row[] {
	const pinned = new Set(pins.map((pin) => pin.tbl));
	return tables.filter((table) => !pinned.has(String(table.id)));
}
/** Disposable acknowledged state only. All persistence is in the workspace API. */
export class SidebarPins {
	state = empty();
	private api: PinAPI | null = null;
	private revision = 0;
	constructor(private changed: (state: PinState) => void) {}
	get active() {
		return this.state.snapshot?.pins.filter((pin) => !pin.deleted_at) ?? [];
	}
	get disabled() {
		return (
			this.state.busy ||
			this.state.loading ||
			!!this.state.error ||
			!this.state.snapshot ||
			!!this.state.snapshot.unavailable
		);
	}
	private update(patch: Partial<PinState>) {
		this.state = { ...this.state, ...patch };
		this.changed(this.state);
	}
	setWorkspace(api: PinAPI | null) {
		this.revision++;
		this.api = api;
		this.state = empty();
		this.changed(this.state);
	}
	async refresh() {
		if (!this.api || this.state.busy) return;
		const api = this.api,
			revision = ++this.revision;
		this.update({ loading: true });
		try {
			const snapshot = await api.list();
			if (revision === this.revision) this.update({ snapshot, error: null });
		} catch (error) {
			if (revision === this.revision)
				this.update({ error: error instanceof Error ? error.message : String(error) });
		} finally {
			if (revision === this.revision) this.update({ loading: false });
		}
	}
	private async mutate(
		write: (
			api: PinAPI,
			acknowledge: (snapshot: SidebarPinList) => boolean
		) => Promise<SidebarPinList>
	): Promise<boolean> {
		if (!this.api || this.disabled) return false;
		const revision = ++this.revision;
		const acknowledge = (snapshot: SidebarPinList) => {
			if (revision !== this.revision) return false;
			this.update({ snapshot, error: null });
			return true;
		};
		this.update({ busy: true });
		try {
			return acknowledge(await write(this.api, acknowledge));
		} catch (error) {
			if (revision === this.revision)
				this.update({ error: error instanceof Error ? error.message : String(error) });
			return false;
		} finally {
			if (revision === this.revision) this.update({ busy: false });
		}
	}
	pin(table: string) {
		const expectedUpdatedAt =
			this.state.snapshot?.pins.find((pin) => pin.tbl === table)?.updated_at ?? null;
		return this.mutate((api) => api.pin({ table, expectedUpdatedAt }));
	}
	unpin(id: string) {
		const pin = this.active.find((pin) => pin.id === id);
		if (!pin) return Promise.resolve(false);
		return this.mutate((api) => api.unpin({ id, expectedUpdatedAt: pin.updated_at }));
	}
	/** Moves a pin to index `to` of the active list in single guarded core steps,
	 * each against the revisions the previous step acknowledged. */
	reorder(id: string, to: number) {
		const from = this.active.findIndex((pin) => pin.id === id);
		if (from < 0 || to === from || to < 0 || to >= this.active.length)
			return Promise.resolve(false);
		const direction = to < from ? 'up' : 'down';
		// ponytail: one write per step, so a failure mid-drag keeps the acknowledged
		// partial order; a core move-to-index operation would make it atomic.
		return this.mutate(async (api, acknowledge) => {
			for (let step = Math.abs(to - from); ; step--) {
				const expected = this.active.map(({ id, updated_at }) => ({ id, updated_at }));
				const snapshot = await api.move({ id, direction, expected });
				if (step === 1 || !acknowledge(snapshot)) return snapshot;
			}
		});
	}
}
/** Index a dragged pin lands on: the other rows whose centre its centre passed. */
export function dropIndex(centres: number[], from: number, y: number) {
	return centres.filter((centre, i) => i !== from && centre < y).length;
}
