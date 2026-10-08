/** Background sync cadence: push shortly after writes, pull often while someone is looking. */
export class SyncScheduler {
	syncing = false;
	failures = 0;
	private timer: ReturnType<typeof setTimeout> | undefined;
	private again = false;
	private stopped = false;

	constructor(
		private readonly host: { ready(): boolean; run(): Promise<void> },
		private readonly onchange: () => void,
		private readonly options = { pushDelay: 750, pullInterval: 2000, maxBackoff: 60_000 }
	) {}

	/** A local write committed; push it once writes settle. */
	wrote() {
		this.schedule(this.options.pushDelay);
	}

	/** Visibility, focus, network or connection changed: sync now if allowed. */
	wake() {
		this.schedule(0);
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
	if (!s.connected) return pill(`Not connected${pending}`, 'idle', 'connect');
	if (s.syncing) return pill('Syncing', 'busy');
	if (s.error === 'hub HTTP 429')
		return pill('Paused · usage cap', 'warn', null, 'Hub usage cap reached; sync retries later');
	if (s.error) return pill('Sync error', 'error', null, s.error);
	if (s.pending) return pill('Syncing', 'busy');
	return pill('Synced', 'ok');
}
