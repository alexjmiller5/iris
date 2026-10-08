import { get } from 'svelte/store';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createSavedViewsModel, createViewAutosave } from './saved-views';

function deferred() {
	let resolve!: (value?: boolean) => void;
	let reject!: (error: Error) => void;
	const promise = new Promise<boolean | void>((yes, no) => {
		resolve = yes;
		reject = no;
	});
	return { promise, resolve, reject };
}

describe('saved-view interactions', () => {
	it('starts from the selected name and resets only when the context changes', () => {
		const model = createSavedViewsModel();
		model.setContext('widgets:view-a', 'Open items');
		model.setName('My draft');
		model.setContext('widgets:view-a', 'Refreshed name');
		expect(get(model).name).toBe('My draft');
		model.setContext('other:view-a', 'Other table');
		expect(get(model).name).toBe('Other table');
	});

	it('refreshes a pristine name without overwriting an edited one', () => {
		const model = createSavedViewsModel();
		model.setContext('view-a', 'Old name');
		model.setContext('view-a', 'New name');
		expect(get(model).name).toBe('New name');
	});

	it('blocks a second action while a request is pending', async () => {
		const model = createSavedViewsModel();
		const pending = deferred();
		const result = model.run('save', () => pending.promise);
		let calls = 0;
		expect(get(model).pending).toBe('save');
		expect(
			await model.run('delete', async () => {
				calls++;
			})
		).toBe(false);
		expect(calls).toBe(0);
		pending.resolve();
		expect(await result).toBe(true);
		expect(get(model).pending).toBeNull();
	});

	it('treats a cancelled choice as cancellation without erasing the name', async () => {
		const model = createSavedViewsModel();
		model.setName('Keep this');
		expect(await model.run('choose', async () => false)).toBe(false);
		expect(get(model)).toMatchObject({ name: 'Keep this', error: '', pending: null });
	});

	it('retains the input and delete confirmation when a request fails', async () => {
		const model = createSavedViewsModel();
		model.setName('Unsubmitted name');
		model.confirmDelete(true);
		expect(
			await model.run('delete', async () => {
				throw new Error('Revision changed');
			})
		).toBe(false);
		expect(get(model)).toEqual({
			name: 'Unsubmitted name',
			error: 'Revision changed',
			pending: null,
			confirming: true
		});
		expect(await model.run('delete', async () => {})).toBe(true);
		expect(get(model)).toMatchObject({ error: '', confirming: false, pending: null });
	});

	it.each(['resolve', 'reject'] as const)(
		'ignores a stale %s after changing table or selection',
		async (settle) => {
			const model = createSavedViewsModel();
			model.setContext('old:one', 'Old name');
			const pending = deferred();
			const result = model.run('save', () => pending.promise);
			model.setContext('new:two', 'New name');
			model.confirmDelete(true);
			if (settle === 'resolve') pending.resolve();
			else pending.reject(new Error('Old failure'));
			expect(await result).toBe(false);
			expect(get(model)).toEqual({ name: 'New name', pending: null, error: '', confirming: true });
		}
	);

	it('an old completion cannot clear a new context request', async () => {
		const model = createSavedViewsModel();
		const old = deferred(),
			next = deferred();
		model.setContext('old', 'Old');
		const oldResult = model.run('save', () => old.promise);
		model.setContext('next', 'Next');
		const nextResult = model.run('update', () => next.promise);
		old.resolve();
		expect(await oldResult).toBe(false);
		expect(get(model).pending).toBe('update');
		next.resolve();
		expect(await nextResult).toBe(true);
		expect(get(model).pending).toBeNull();
	});

	it('does not publish a late failure or accept new work after disposal', async () => {
		const model = createSavedViewsModel();
		const pending = deferred();
		const result = model.run('choose', () => pending.promise);
		model.dispose();
		const disposed = get(model);
		pending.reject(new Error('Late error'));
		expect(await result).toBe(false);
		expect(get(model)).toEqual(disposed);
		let calls = 0;
		expect(
			await model.run('save', async () => {
				calls++;
			})
		).toBe(false);
		expect(calls).toBe(0);
	});

	it('rejects work after disposal even when no previous request was pending', async () => {
		const model = createSavedViewsModel();
		model.dispose();
		let calls = 0;
		expect(
			await model.run('save', async () => {
				calls++;
			})
		).toBe(false);
		expect(calls).toBe(0);
	});
});

describe('view autosave', () => {
	beforeEach(() => vi.useFakeTimers());
	afterEach(() => vi.useRealTimers());
	let state = 0;
	const capture = () => ++state;

	it('coalesces rapid changes into one save after the debounce', async () => {
		const write = vi.fn(async (_: number) => {});
		const autosave = createViewAutosave(capture, write, () => {}, 500);
		autosave.change();
		autosave.change();
		await vi.advanceTimersByTimeAsync(499);
		autosave.change();
		await vi.advanceTimersByTimeAsync(499);
		expect(write).not.toHaveBeenCalled();
		expect(get(autosave).pending).toBe(true);
		await vi.advanceTimersByTimeAsync(1);
		expect(write).toHaveBeenCalledTimes(1);
		expect(get(autosave).pending).toBe(false);
	});

	it('waits while a popover is open and saves soon after it closes', async () => {
		const write = vi.fn(async (_: number) => {});
		const autosave = createViewAutosave(capture, write, () => {}, 300);
		autosave.hold(true);
		autosave.change();
		await vi.advanceTimersByTimeAsync(10_000);
		expect(write).not.toHaveBeenCalled();
		autosave.hold(false);
		await vi.advanceTimersByTimeAsync(300);
		expect(write).toHaveBeenCalledTimes(1);
		autosave.hold(true);
		autosave.hold(false);
		await vi.advanceTimersByTimeAsync(1000);
		expect(write).toHaveBeenCalledTimes(1);
	});

	it('flush captures the view at once and never overlaps an in-flight write', async () => {
		const releases: (() => void)[] = [];
		const write = vi.fn(
			(_: number) =>
				new Promise<void>((resolve) => {
					releases.push(resolve);
				})
		);
		const autosave = createViewAutosave(capture, write, () => {}, 500);
		autosave.change();
		const before = state;
		const first = autosave.flush();
		expect(state).toBe(before + 1);
		await vi.advanceTimersByTimeAsync(0);
		expect(write).toHaveBeenCalledTimes(1);
		autosave.change();
		const second = autosave.flush();
		expect(state).toBe(before + 2);
		await vi.advanceTimersByTimeAsync(0);
		expect(write).toHaveBeenCalledTimes(1);
		releases[0]();
		await first;
		await vi.advanceTimersByTimeAsync(0);
		expect(write).toHaveBeenLastCalledWith(before + 2);
		expect(get(autosave).pending).toBe(true);
		releases[1]();
		await second;
		expect(get(autosave).pending).toBe(false);
	});

	it('reports a failed save once and waits for the next change before retrying', async () => {
		const write = vi.fn(async (_: number) => {
			throw new Error('The view changed; reload before retrying.');
		});
		const onerror = vi.fn();
		const autosave = createViewAutosave(capture, write, onerror, 100);
		autosave.change();
		await vi.advanceTimersByTimeAsync(5000);
		expect(write).toHaveBeenCalledTimes(1);
		expect(onerror).toHaveBeenCalledWith(
			expect.objectContaining({ message: expect.stringMatching(/changed/) })
		);
		autosave.change();
		await vi.advanceTimersByTimeAsync(100);
		expect(write).toHaveBeenCalledTimes(2);
	});

	it('drops pending work after disposal', async () => {
		const write = vi.fn(async (_: number) => {});
		const autosave = createViewAutosave(capture, write, () => {}, 100);
		autosave.change();
		autosave.dispose();
		await autosave.flush();
		await vi.advanceTimersByTimeAsync(1000);
		expect(write).not.toHaveBeenCalled();
	});
});
