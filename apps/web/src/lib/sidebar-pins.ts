import type {
	MoveTablePinArgs,
	PinTableArgs,
	Row,
	SidebarPin,
	SidebarPinList,
	UnpinTableArgs
} from 'life-ui-core/client';

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
	private async mutate(write: (api: PinAPI) => Promise<SidebarPinList>): Promise<boolean> {
		if (!this.api || this.disabled) return false;
		const revision = ++this.revision;
		this.update({ busy: true });
		try {
			const snapshot = await write(this.api);
			if (revision !== this.revision) return false;
			this.update({ snapshot, error: null });
			return true;
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
	move(id: string, direction: 'up' | 'down') {
		const expected = this.active.map(({ id, updated_at }) => ({ id, updated_at }));
		return this.mutate((api) => api.move({ id, direction, expected }));
	}
}
