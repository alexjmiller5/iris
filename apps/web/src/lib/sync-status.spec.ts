import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { ChangeSocket, SyncScheduler, leadership, syncPill, syncProgressLabel } from './sync-status';
import type { Liveness } from './sync-status';

let ready = true;
let runs = 0;
let fail = false;
let hold: (() => void) | null = null;
const host = {
	ready: () => ready,
	run: async () => {
		runs++;
		if (hold) await new Promise<void>((resolve) => (hold = resolve));
		if (fail) throw new Error('hub HTTP 500');
	}
};
let scheduler: SyncScheduler;
beforeEach(() => {
	vi.useFakeTimers();
	ready = true;
	runs = 0;
	fail = false;
	hold = null;
	scheduler = new SyncScheduler(host, () => {});
});
afterEach(() => {
	scheduler.stop();
	vi.useRealTimers();
});

test('debounces committed writes into one push 750 ms after the last write', async () => {
	scheduler.wrote();
	await vi.advanceTimersByTimeAsync(500);
	scheduler.wrote();
	await vi.advanceTimersByTimeAsync(700);
	expect(runs).toBe(0);
	await vi.advanceTimersByTimeAsync(50);
	expect(runs).toBe(1);
});

test('pulls every 2 s while ready', async () => {
	scheduler.wake();
	await vi.advanceTimersByTimeAsync(0);
	expect(runs).toBe(1);
	await vi.advanceTimersByTimeAsync(1999);
	expect(runs).toBe(1);
	await vi.advanceTimersByTimeAsync(1);
	expect(runs).toBe(2);
	await vi.advanceTimersByTimeAsync(4000);
	expect(runs).toBe(4);
});

test('checks once a minute while the wake socket is live, every 2 s again once it drops', async () => {
	scheduler.cadence(60_000);
	scheduler.wake();
	await vi.advanceTimersByTimeAsync(0);
	expect(runs).toBe(1);
	await vi.advanceTimersByTimeAsync(59_999);
	expect(runs).toBe(1);
	await vi.advanceTimersByTimeAsync(1);
	expect(runs).toBe(2);
	await vi.advanceTimersByTimeAsync(10_000);
	scheduler.cadence(2000);
	await vi.advanceTimersByTimeAsync(2000);
	expect(runs).toBe(3);
	await vi.advanceTimersByTimeAsync(2000);
	expect(runs).toBe(4);
});

test('pauses while hidden or offline and resumes immediately on wake', async () => {
	scheduler.wake();
	await vi.advanceTimersByTimeAsync(0);
	ready = false;
	await vi.advanceTimersByTimeAsync(20_000);
	expect(runs).toBe(1);
	scheduler.wrote();
	await vi.advanceTimersByTimeAsync(5000);
	expect(runs).toBe(1);
	ready = true;
	scheduler.wake();
	await vi.advanceTimersByTimeAsync(0);
	expect(runs).toBe(2);
});

test('runs one sync at a time and coalesces requests made during a run', async () => {
	hold = () => {};
	scheduler.wake();
	await vi.advanceTimersByTimeAsync(0);
	scheduler.wake();
	scheduler.wrote();
	await vi.advanceTimersByTimeAsync(5000);
	expect(runs).toBe(1);
	expect(scheduler.syncing).toBe(true);
	const release = hold;
	hold = null;
	release();
	await vi.advanceTimersByTimeAsync(0);
	expect(runs).toBe(2);
	await vi.advanceTimersByTimeAsync(0);
	expect(runs).toBe(2);
	expect(scheduler.syncing).toBe(false);
});

test('backs off exponentially on hub errors and resets after a success', async () => {
	fail = true;
	scheduler.wake();
	await vi.advanceTimersByTimeAsync(0);
	expect(scheduler.failures).toBe(1);
	await vi.advanceTimersByTimeAsync(3999);
	expect(runs).toBe(1);
	await vi.advanceTimersByTimeAsync(1);
	expect(runs).toBe(2);
	await vi.advanceTimersByTimeAsync(8000);
	expect(runs).toBe(3);
	fail = false;
	await vi.advanceTimersByTimeAsync(16_000);
	expect(runs).toBe(4);
	expect(scheduler.failures).toBe(0);
	await vi.advanceTimersByTimeAsync(2000);
	expect(runs).toBe(5);
});

test('caps the backoff delay', async () => {
	fail = true;
	scheduler.wake();
	await vi.advanceTimersByTimeAsync(0);
	for (let i = 0; i < 10; i++) await vi.advanceTimersByTimeAsync(60_000);
	const before = runs;
	await vi.advanceTimersByTimeAsync(60_000);
	expect(runs).toBe(before + 1);
});

test('stop cancels timers and an in-flight run does not reschedule', async () => {
	hold = () => {};
	scheduler.wake();
	await vi.advanceTimersByTimeAsync(0);
	scheduler.stop();
	const release = hold;
	hold = null;
	release();
	await vi.advanceTimersByTimeAsync(10_000);
	expect(runs).toBe(1);
	scheduler.wake();
	scheduler.wrote();
	await vi.advanceTimersByTimeAsync(10_000);
	expect(runs).toBe(1);
});

test('one tab leads at a time; a hidden leader hands over to a waiting tab', async () => {
	const queue: { grant(): void }[] = [];
	let held = false;
	const locks = {
		request(_name: string, options: { signal: AbortSignal }, body: () => Promise<void>) {
			return new Promise<void>((resolve, reject) => {
				const grant = () => {
					held = true;
					void body().then(() => {
						held = false;
						queue.shift()?.grant();
						resolve();
					});
				};
				options.signal.addEventListener('abort', () => {
					const index = queue.findIndex((entry) => entry.grant === grant);
					if (index >= 0) queue.splice(index, 1);
					reject(options.signal.reason);
				});
				if (held) queue.push({ grant });
				else grant();
			});
		}
	} as unknown as LockManager;
	const a: boolean[] = [],
		b: boolean[] = [];
	const first = leadership(locks, 'sync', (leader) => a.push(leader));
	const second = leadership(locks, 'sync', (leader) => b.push(leader));
	first.want(true);
	second.want(true);
	await vi.advanceTimersByTimeAsync(0);
	expect([a, b]).toEqual([[true], []]);
	first.want(false);
	await vi.advanceTimersByTimeAsync(0);
	expect([a, b]).toEqual([[true, false], [true]]);
	first.want(true);
	first.want(false);
	await vi.advanceTimersByTimeAsync(0);
	expect(queue).toHaveLength(0);
	second.want(false);
	await vi.advanceTimersByTimeAsync(0);
	expect(b).toEqual([true, false]);
});

const base = {
	demo: false,
	connected: true,
	online: true,
	syncing: false,
	pending: 0,
	rejected: 0,
	lastSync: '2026-10-08T12:00:00.000Z',
	error: '',
	now: Date.parse('2026-10-08T12:00:05.000Z')
};
test('pill names exactly one state, in priority order', () => {
	expect(syncPill(base)).toMatchObject({ label: 'Synced', title: 'Last synced 5 seconds ago' });
	expect(syncPill({ ...base, syncing: true })).toMatchObject({ label: 'Syncing' });
	expect(syncPill({ ...base, pending: 2 })).toMatchObject({ label: 'Syncing' });
	expect(syncPill({ ...base, online: false, pending: 3 })).toMatchObject({
		label: 'Offline · 3 pending'
	});
	expect(syncPill({ ...base, online: false })).toMatchObject({ label: 'Offline' });
	expect(syncPill({ ...base, error: 'Failed to fetch', pending: 1 })).toMatchObject({
		label: 'Offline · 1 pending'
	});
	expect(syncPill({ ...base, rejected: 2, online: false })).toMatchObject({
		label: '2 rejected',
		action: 'rejected'
	});
	expect(syncPill({ ...base, error: 'hub HTTP 429' })).toMatchObject({
		label: 'Paused · usage cap'
	});
	expect(syncPill({ ...base, error: 'hub HTTP 500' })).toMatchObject({
		label: 'Sync error',
		title: 'hub HTTP 500'
	});
	expect(syncPill({ ...base, connected: false, pending: 1 })).toMatchObject({
		label: 'Not connected · 1 pending',
		action: 'connect'
	});
	expect(syncPill({ ...base, demo: true, connected: false })).toMatchObject({
		label: 'Sample data'
	});
	expect(syncPill({ ...base, lastSync: null }).title).toBe('No sync completed yet');
});

test('a quiet pill names how the wake signal stands', () => {
	expect(syncPill({ ...base, liveness: 'live' })).toMatchObject({ label: 'Live', tone: 'ok' });
	expect(syncPill({ ...base, liveness: 'reconnecting' })).toMatchObject({ label: 'Reconnecting' });
	expect(syncPill({ ...base, liveness: 'minute' })).toMatchObject({
		label: 'Checking every minute'
	});
	// Every other state still outranks it.
	expect(syncPill({ ...base, liveness: 'live', pending: 1 })).toMatchObject({ label: 'Syncing' });
	expect(syncPill({ ...base, liveness: 'live', online: false })).toMatchObject({ label: 'Offline' });
});

test('shows a long backup action in place of sync state', () => {
	expect(syncPill({ ...base, activity: 'Restoring 42%' })).toMatchObject({
		label: 'Restoring 42%',
		tone: 'busy',
		action: null
	});
	expect(syncPill({ ...base, demo: true, activity: 'Exporting' })).toMatchObject({
		label: 'Exporting'
	});
	expect(syncPill({ ...base, activity: '' })).toMatchObject({ label: 'Synced' });
});

test('a long sync names the tables left and, once the size is known, the time left', () => {
	const cold = {
		tablesDone: 37,
		tablesTotal: 113,
		rowsReceived: 21_638,
		rowsExpected: 150_714,
		table: 'people'
	};
	expect(syncProgressLabel(cold, 60_000)).toBe('76 tables left · ~6 min');
	expect(syncProgressLabel({ ...cold, rowsReceived: 140_000 }, 60_000)).toBe(
		'76 tables left · <1 min'
	);
	// Too early to tell, a changes-only round, or nothing to measure against.
	expect(syncProgressLabel({ ...cold, rowsReceived: 1_000 }, 60_000)).toBe('76 tables left');
	expect(syncProgressLabel(cold, 2_000)).toBe('76 tables left');
	expect(syncProgressLabel({ ...cold, rowsExpected: null }, 60_000)).toBe('76 tables left');
	expect(syncProgressLabel({ ...cold, rowsExpected: 0 }, 60_000)).toBe('76 tables left');
	expect(syncProgressLabel({ ...cold, tablesDone: 112 }, 60_000)).toBe('1 table left · ~6 min');
	expect(syncProgressLabel({ ...cold, tablesDone: 113 }, 60_000)).toBe('');
	// The first download runs while connecting: it is a sync, not "Not connected".
	expect(
		syncPill({ ...base, connected: false, syncing: true, syncDetail: '76 tables left' })
	).toMatchObject({ label: '76 tables left' });
	expect(syncPill({ ...base, syncing: true, syncDetail: '76 tables left · ~6 min' })).toMatchObject(
		{
			label: '76 tables left · ~6 min',
			title: 'Syncing: 76 tables left · ~6 min',
			tone: 'busy'
		}
	);
});

class FakeSocket {
	static all: FakeSocket[] = [];
	sent: string[] = [];
	closed = false;
	onopen: (() => void) | null = null;
	onmessage: ((event: { data: unknown }) => void) | null = null;
	onclose: (() => void) | null = null;
	onerror: (() => void) | null = null;
	constructor(
		readonly url: string,
		readonly protocols: string[]
	) {
		FakeSocket.all.push(this);
	}
	send(data: string) {
		this.sent.push(data);
	}
	close() {
		if (this.closed) return;
		this.closed = true;
		this.onclose?.();
	}
	open() {
		this.onopen?.();
	}
	receive(data: string) {
		this.onmessage?.({ data });
	}
	drop() {
		this.onerror?.();
		this.close();
	}
}

function socketFixture() {
	FakeSocket.all = [];
	const wakes: number[] = [];
	const states: Liveness[] = [];
	const socket = new ChangeSocket(
		'https://hub.example/',
		'lt_abc',
		{ wake: () => wakes.push(Date.now()), state: (s) => states.push(s) },
		(url, protocols) => new FakeSocket(url, protocols) as unknown as WebSocket
	);
	const last = () => FakeSocket.all.at(-1)!;
	return { socket, wakes, states, last };
}

test('the wake socket authenticates with the token subprotocol and wakes a round on open and on each change', async () => {
	const { socket, wakes, states, last } = socketFixture();
	socket.want(true);
	expect(last().url).toBe('wss://hub.example/v1/changes');
	expect(last().protocols).toEqual(['soma-changes-v1', 'soma-token.lt_abc']);
	expect(wakes).toHaveLength(0);
	last().open();
	expect(states.at(-1)).toBe('live');
	expect(wakes).toHaveLength(1);
	last().receive('{"seq":7,"tables":["notes"]}');
	expect(wakes).toHaveLength(2);
	last().receive('pong');
	last().receive('not json');
	expect(wakes).toHaveLength(2);
	socket.want(false);
	expect(last().closed).toBe(true);
	await vi.advanceTimersByTimeAsync(120_000);
	expect(FakeSocket.all).toHaveLength(1);
});

test('a dropped socket reconnects with backoff and a silent one is closed after a missed pong', async () => {
	const { socket, states, last } = socketFixture();
	socket.want(true);
	last().open();
	last().drop();
	expect(states.at(-1)).toBe('reconnecting');
	await vi.advanceTimersByTimeAsync(999);
	expect(FakeSocket.all).toHaveLength(1);
	await vi.advanceTimersByTimeAsync(1);
	expect(FakeSocket.all).toHaveLength(2);
	last().drop();
	await vi.advanceTimersByTimeAsync(1999);
	expect(FakeSocket.all).toHaveLength(2);
	await vi.advanceTimersByTimeAsync(1);
	expect(FakeSocket.all).toHaveLength(3);
	// A healthy connection resets the backoff and pings every 30 s.
	last().open();
	await vi.advanceTimersByTimeAsync(30_000);
	expect(last().sent).toEqual(['ping']);
	last().receive('pong');
	await vi.advanceTimersByTimeAsync(30_000);
	expect(last().sent).toEqual(['ping', 'ping']);
	// No pong within 10 s: the connection is dead even if the OS has not said so.
	await vi.advanceTimersByTimeAsync(10_000);
	expect(last().closed).toBe(true);
	expect(states.at(-1)).toBe('reconnecting');
	await vi.advanceTimersByTimeAsync(1000);
	expect(FakeSocket.all).toHaveLength(4);
	socket.want(false);
});

test('a socket down for two minutes falls back to checking every minute', async () => {
	const { socket, states, last } = socketFixture();
	socket.want(true);
	// Never opens: every attempt fails for three minutes.
	for (let i = 0; i < 6; i++) {
		last().drop();
		await vi.advanceTimersByTimeAsync(30_000);
	}
	expect(states.at(-1)).toBe('minute');
	const count = FakeSocket.all.length;
	last().drop();
	await vi.advanceTimersByTimeAsync(59_999);
	expect(FakeSocket.all).toHaveLength(count);
	await vi.advanceTimersByTimeAsync(1);
	expect(FakeSocket.all).toHaveLength(count + 1);
	last().open();
	expect(states.at(-1)).toBe('live');
	socket.want(false);
});

test('a socket that drops after a long healthy life reconnects at once, not once a minute', async () => {
	const { socket, states, last } = socketFixture();
	socket.want(true);
	last().open();
	for (let i = 0; i < 10; i++) {
		await vi.advanceTimersByTimeAsync(30_000);
		last().receive('pong');
	}
	last().drop();
	expect(states.at(-1)).toBe('reconnecting');
	await vi.advanceTimersByTimeAsync(1000);
	expect(FakeSocket.all).toHaveLength(2);
	socket.want(false);
});
