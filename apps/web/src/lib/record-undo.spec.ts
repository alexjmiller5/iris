import { describe, expect, it } from 'vitest';
import { reconcileUndo } from './record-undo';

describe('a saved-change undo receipt', () => {
	it('refreshes unchanged editor fields and their baseline', () => {
		const before = { title: 'Saved title', body: 'Saved body', quantity: '0' };
		const after = { title: 'Earlier title', body: 'Earlier body', quantity: '0' };
		expect(reconcileUndo(before, before, after)).toEqual({
			values: after,
			baseline: JSON.stringify(after),
			dirty: false
		});
	});

	it('preserves newer draft fields while accepting undone fields and the new revision baseline', () => {
		const values = Object.freeze({ title: 'Still typing', body: 'Saved body', quantity: '0' });
		const before = Object.freeze({ title: 'Saved title', body: 'Saved body', quantity: '0' });
		const after = Object.freeze({ title: 'Earlier title', body: 'Earlier body', quantity: '2' });
		expect(reconcileUndo(values, before, after)).toEqual({
			values: { title: 'Still typing', body: 'Earlier body', quantity: '2' },
			baseline: JSON.stringify(after),
			dirty: true
		});
	});

	it('needs no review when the newer draft already equals the undone value', () => {
		expect(
			reconcileUndo(
				{ body: 'Earlier', quantity: '2' },
				{ body: 'Saved', quantity: '2' },
				{ body: 'Earlier', quantity: '1' }
			)
		).toEqual({
			values: { body: 'Earlier', quantity: '1' },
			baseline: JSON.stringify({ body: 'Earlier', quantity: '1' }),
			dirty: false
		});
	});

	it('keeps the mounted field set and key order when the catalog changes', () => {
		expect(
			reconcileUndo(
				{ body: 'Saved', title: 'Saved title' },
				{ title: 'Saved title', body: 'Saved' },
				{ title: 'Earlier title', body: 'Earlier', newlyAdded: 'Never mounted' }
			)
		).toEqual({
			values: { body: 'Earlier', title: 'Earlier title' },
			baseline: JSON.stringify({ body: 'Earlier', title: 'Earlier title' }),
			dirty: false
		});
	});
});
