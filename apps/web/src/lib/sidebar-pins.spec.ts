import { expect, test, vi } from 'vitest';
import { SidebarPins, unpinnedTables } from './sidebar-pins';
import type { SidebarPinList } from 'iris-core/client';
const list = (names: string[]): SidebarPinList => ({
	unavailable: null,
	pins: names.map((tbl, position) => ({
		id: `pin:${tbl}`,
		tbl,
		position,
		updated_at: '2026-01-01T00:00:00.000Z',
		deleted_at: null,
		unavailable: null
	}))
});
function fixture() {
	const api = {
		list: vi.fn(async () => list(['zeta', 'alpha'])),
		pin: vi.fn(async () => list(['zeta', 'alpha', 'beta'])),
		unpin: vi.fn(async () => list(['alpha'])),
		move: vi.fn(async () => list(['alpha', 'zeta']))
	};
	const model = new SidebarPins(() => {});
	model.setWorkspace(api);
	return { model, api };
}
test('pins keep acknowledged order and remove duplicates from ordinary and system tables', async () => {
	const { model } = fixture();
	await model.refresh();
	expect(model.active.map((p) => p.tbl)).toEqual(['zeta', 'alpha']);
	expect(
		unpinnedTables([{ id: 'alpha' }, { id: 'beta' }, { id: 'zeta', readOnly: true }], model.active)
	).toEqual([{ id: 'beta' }]);
});
test('mutation waits for its receipt; a failed write retains pins and reports failure', async () => {
	const { model, api } = fixture();
	await model.refresh();
	let reject!: (e: Error) => void;
	api.unpin.mockImplementation(() => new Promise((_, r) => (reject = r)));
	const pending = model.unpin('pin:zeta');
	expect(model.state.busy).toBe(true);
	expect(model.active.map((p) => p.tbl)).toEqual(['zeta', 'alpha']);
	reject(Error('Storage unavailable'));
	expect(await pending).toBe(false);
	expect(model.active.map((p) => p.tbl)).toEqual(['zeta', 'alpha']);
	expect(model.state.error).toBe('Storage unavailable');
	expect(await model.move('pin:zeta', 'down')).toBe(false);
	expect(api.move).not.toHaveBeenCalled();
});
test('failed refresh retains last good list and a successful retry clears the error', async () => {
	const { model, api } = fixture();
	await model.refresh();
	api.list.mockRejectedValueOnce(Error('Offline read failure'));
	await model.refresh();
	expect(model.active).toHaveLength(2);
	expect(model.state.error).toBeTruthy();
	await model.refresh();
	expect(model.state.error).toBeNull();
});
test('workspace replacement ignores a late list and a late write receipt', async () => {
	const { model, api } = fixture();
	let resolve!: (v: SidebarPinList) => void;
	api.list.mockImplementationOnce(() => new Promise((r) => (resolve = r)));
	const pending = model.refresh();
	model.setWorkspace(null);
	resolve(list(['old']));
	await pending;
	expect(model.state.snapshot).toBeNull();
	model.setWorkspace(api);
	await model.refresh();
	api.pin.mockImplementationOnce(() => new Promise((r) => (resolve = r)));
	const writing = model.pin('beta');
	model.setWorkspace(null);
	resolve(list(['old']));
	await writing;
	expect(model.state.snapshot).toBeNull();
	expect(model.state.busy).toBe(false);
});
test('restoring pins uses tombstone revision and moving sends the selected complete list', async () => {
	const { model, api } = fixture();
	const snapshot = list(['zeta', 'alpha', 'beta']);
	snapshot.pins[2].deleted_at = snapshot.pins[2].updated_at;
	api.list.mockResolvedValue(snapshot);
	await model.refresh();
	await model.pin('beta');
	expect(api.pin).toHaveBeenCalledWith({
		table: 'beta',
		expectedUpdatedAt: '2026-01-01T00:00:00.000Z'
	});
	await model.move('pin:alpha', 'up');
	expect(api.move).toHaveBeenCalledWith({
		id: 'pin:alpha',
		direction: 'up',
		expected: list(['zeta', 'alpha', 'beta']).pins.map(({ id, updated_at }) => ({ id, updated_at }))
	});
});
test('a missing target stays removable; unavailable storage disables mutations', async () => {
	const { model, api } = fixture();
	const snapshot = list(['missing']);
	snapshot.pins[0].unavailable = 'No longer available';
	api.list.mockResolvedValue(snapshot);
	await model.refresh();
	await model.unpin('pin:missing');
	expect(api.unpin).toHaveBeenCalledWith({
		id: 'pin:missing',
		expectedUpdatedAt: snapshot.pins[0].updated_at
	});
	api.list.mockResolvedValue({ pins: [], unavailable: 'Sync pin storage first' });
	await model.refresh();
	expect(await model.pin('beta')).toBe(false);
	expect(model.state.snapshot?.unavailable).toBe('Sync pin storage first');
});
