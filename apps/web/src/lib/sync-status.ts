/** Background sync cadence: push shortly after writes; between hub wake signals, check
 * every `pullInterval` (2 s while the socket is down, 60 s while it is live). */
export class SyncScheduler {
	syncing = false;
	failures = 0;
	private timer: ReturnType<typeof setTimeout> | undefined;
	private again = false;
	private stopped = false;

	constructor(
		private readonly host: { ready(): boolean; run(): Promise<void> },
		private readonly onchange: () => void,
		private options = { pushDelay: 750, pullInterval: 2000, maxBackoff: 60_000 }
	) {}

	/** A local write committed; push it once writes settle. */
	wrote() {
		this.schedule(this.options.pushDelay);
	}

	/** Visibility, focus, network, connection or a hub change signal: sync now if allowed. */
	wake() {
		this.schedule(0);
	}

	/** The idle check interval changed (the wake socket opened or dropped). */
	cadence(pullInterval: number) {
		if (pullInterval === this.options.pullInterval) return;
		this.options = { ...this.options, pullInterval };
		if (!this.syncing && !this.failures) this.schedule(pullInterval);
	}

	stop() {
		this.stopped = true;
		clearTimeout(this.timer);
	}

	private schedule(delay: number) {
		if (this.stopped) return;
		if (this.syncing) {
			this.again = true;
			return;
		}
		clearTimeout(this.timer);
		this.timer = setTimeout(() => void this.tick(), delay);
	}

	private async tick() {
		// Hidden, offline, disconnected or another tab leads: wait for the next wake.
		if (this.stopped || !this.host.ready()) return;
		this.syncing = true;
		this.again = false;
		this.onchange();
		try {
			await this.host.run();
			this.failures = 0;
		} catch {
			this.failures++;
		}
		this.syncing = false;
		this.onchange();
		if (this.stopped) return;
		const { pullInterval, maxBackoff } = this.options;
		if (this.again) this.schedule(0);
		else
			this.schedule(
				this.failures ? Math.min(pullInterval * 2 ** this.failures, maxBackoff) : pullInterval
			);
	}
}

/** How the hub's change signal stands: a live socket, a recent drop being retried,
 * or a socket down so long that the client checks once a minute. */
export type Liveness = 'live' | 'reconnecting' | 'minute';

/** The hub's WebSocket wake signal. Any change message starts a round; opening (or
 * reopening) the socket starts one too, which covers messages missed while down.
 * Browsers cannot set headers on a WebSocket, so the token rides as a subprotocol. */
export class ChangeSocket {
	private ws: WebSocket | null = null;
	private wanted = false;
	private attempt = 0;
	private downSince = 0;
	private retry: ReturnType<typeof setTimeout> | undefined;
	private ping: ReturnType<typeof setInterval> | undefined;
	private pong: ReturnType<typeof setTimeout> | undefined;

	constructor(
		private readonly hub: string,
		private readonly token: string,
		private readonly on: { wake(): void; state(liveness: Liveness): void },
		private readonly connect = (url: string, protocols: string[]) => new WebSocket(url, protocols),
		private readonly timing = { ping: 30_000, pong: 10_000, maxRetry: 30_000, minute: 120_000 }
	) {}

	want(on: boolean) {
		if (on === this.wanted) return;
		this.wanted = on;
		if (on) {
			this.downSince = Date.now();
			this.open();
		} else this.teardown();
	}

	private open() {
		const url = new URL('/v1/changes', this.hub);
		url.protocol = url.protocol === 'http:' ? 'ws:' : 'wss:';
		try {
			this.ws = this.connect(url.href, ['soma-changes-v1', `soma-token.${this.token}`]);
		} catch {
			return this.dropped();
		}
		const ws = this.ws;
		ws.onopen = () => {
			if (ws !== this.ws) return;
			this.attempt = 0;
			this.on.state('live');
			this.on.wake();
			this.ping = setInterval(() => {
				ws.send('ping');
				// A dead connection may never finish a close handshake: drop it now.
				this.pong ??= setTimeout(() => this.dropped(), this.timing.pong);
			}, this.timing.ping);
		};
		ws.onmessage = (event) => {
			if (ws !== this.ws) return;
			if (event.data === 'pong') {
				clearTimeout(this.pong);
				this.pong = undefined;
				return;
			}
			try {
				if (typeof JSON.parse(String(event.data))?.seq === 'number') this.on.wake();
			} catch {
				/* Not a change message. */
			}
		};
		ws.onclose = ws.onerror = () => {
			if (ws === this.ws) this.dropped();
		};
	}

	private dropped() {
		const wasLive = this.attempt === 0 && this.ws !== null && this.ping !== undefined;
		this.teardown();
		if (!this.wanted) return;
		if (wasLive) this.downSince = Date.now();
		const minute = Date.now() - this.downSince >= this.timing.minute;
		this.on.state(minute ? 'minute' : 'reconnecting');
		const delay = minute ? 60_000 : Math.min(1000 * 2 ** this.attempt, this.timing.maxRetry);
		this.attempt++;
		this.retry = setTimeout(() => this.open(), delay);
	}

	private teardown() {
		clearTimeout(this.retry);
		clearInterval(this.ping);
		clearTimeout(this.pong);
		this.retry = this.ping = this.pong = undefined;
		const ws = this.ws;
		this.ws = null;
		if (ws) {
			ws.onopen = ws.onmessage = ws.onclose = ws.onerror = null;
			ws.close();
		}
	}
}

/** Hold a cross-tab Web Lock while wanted, so one visible tab runs the loop. */
export function leadership(locks: LockManager, name: string, onchange: (leader: boolean) => void) {
	let release: (() => void) | null = null;
	let waiting: AbortController | null = null;
	return {
		want(on: boolean) {
			if (on && !release && !waiting) {
				const request = (waiting = new AbortController());
				locks
					.request(name, { signal: request.signal }, () => {
						waiting = null;
						onchange(true);
						return new Promise<void>((resolve) => (release = resolve));
					})
					.catch(() => {
						if (waiting === request) waiting = null;
					});
			} else if (!on) {
				waiting?.abort();
				waiting = null;
				if (release) {
					release();
					release = null;
					onchange(false);
				}
			}
		}
	};
}

export interface PillInput {
	demo: boolean;
	connected: boolean;
	online: boolean;
	syncing: boolean;
	pending: number;
	rejected: number;
	lastSync: string | null;
	error: string;
	now: number;
	/** A long user-initiated action (backup, export, restore) in progress. */
	activity?: string;
	/** Where a long sync stands (syncProgressLabel). */
	syncDetail?: string;
	/** The leader tab's wake socket; other tabs leave it unset. */
	liveness?: Liveness;
	/** Records the search index step has yet to index (0 when caught up). */
	indexing?: number;
}
export interface Pill {
	label: string;
	tone: 'ok' | 'busy' | 'warn' | 'error' | 'idle';
	title: string;
	action: 'rejected' | 'connect' | null;
}

const relative = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
function ago(lastSync: string | null, now: number) {
	if (!lastSync) return 'No sync completed yet';
	const seconds = Math.round((Date.parse(lastSync) - now) / 1000);
	const [value, unit]: [number, Intl.RelativeTimeFormatUnit] =
		Math.abs(seconds) < 60
			? [seconds, 'second']
			: Math.abs(seconds) < 3600
				? [Math.round(seconds / 60), 'minute']
				: Math.abs(seconds) < 86400
					? [Math.round(seconds / 3600), 'hour']
					: [Math.round(seconds / 86400), 'day'];
	return `Last synced ${relative.format(value, unit)}`;
}

/** The one sync status, highest-priority state first. */
export function syncPill(s: PillInput): Pill {
	const title = ago(s.lastSync, s.now);
	const pending = s.pending ? ` · ${s.pending} pending` : '';
	const pill = (label: string, tone: Pill['tone'], action: Pill['action'] = null, t = title) => ({
		label,
		tone,
		title: t,
		action
	});
	if (s.activity) return pill(s.activity, 'busy', null, s.activity);
	if (s.demo) return pill('Sample data', 'idle', null, 'The sample workspace never syncs');
	if (s.rejected) return pill(`${s.rejected} rejected`, 'error', 'rejected');
	if (!s.online || /fetch|network|load failed|timed out|offline/i.test(s.error))
		return pill(`Offline${pending}`, 'warn');
	// Connecting runs the first download: show it as the sync it is.
	if (!s.connected && !s.syncing) return pill(`Not connected${pending}`, 'idle', 'connect');
	// The busy dot says syncing; a long sync's label is where it stands.
	if (s.syncing)
		return pill(
			s.syncDetail || 'Syncing',
			'busy',
			null,
			s.syncDetail ? `Syncing: ${s.syncDetail}` : title
		);
	if (s.error === 'hub HTTP 429')
		return pill('Paused · usage cap', 'warn', null, 'Hub usage cap reached; sync retries later');
	if (s.error) return pill('Sync error', 'error', null, s.error);
	if (s.pending) return pill('Syncing', 'busy');
	if (s.indexing)
		return pill(
			'Indexing search…',
			'busy',
			null,
			`${s.indexing.toLocaleString('en-US')} ${s.indexing === 1 ? 'record' : 'records'} left to index. Search and links may be incomplete until then.`
		);
	if (s.liveness === 'reconnecting') return pill('Reconnecting', 'idle');
	if (s.liveness === 'minute') return pill('Checking every minute', 'warn');
	return pill(s.liveness === 'live' ? 'Live' : 'Synced', 'ok');
}

/** Core's sync progress (SyncProgress), as the database worker forwards it. */
export interface SyncProgress {
	tablesDone: number;
	tablesTotal: number;
	rowsReceived: number;
	rowsExpected: number | null;
	table: string | null;
}

/** "76 tables left · ~6 min": the time left only once a full download has
 * a known size and enough of it is done to extrapolate. */
export function syncProgressLabel(p: SyncProgress, elapsedMs: number) {
	const left = p.tablesTotal - p.tablesDone;
	if (left <= 0) return '';
	const tables = `${left} ${left === 1 ? 'table' : 'tables'} left`;
	const done = p.rowsExpected ? p.rowsReceived / p.rowsExpected : 0;
	if (done < 0.02 || elapsedMs < 5_000) return tables;
	const seconds = ((elapsedMs / 1000) * (1 - Math.min(done, 1))) / done;
	return `${tables} · ${seconds < 60 ? '<1 min' : `~${Math.round(seconds / 60)} min`}`;
}
