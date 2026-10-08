<script lang="ts">
	import { onMount, tick } from 'svelte';
	import ChangesetReview from './governance/ChangesetReview.svelte';
	import { IconBell, IconSettings, IconX } from '@tabler/icons-svelte';
	import {
		createHttpHub,
		readUsage,
		readNotifications,
		markNotificationsRead,
		type ServiceHub,
		type UsageSummary,
		type NotificationFeed
	} from 'life-ui-core/client';

	let {
		connection,
		canReview = false,
		syncRevision = 0
	}: {
		connection: { endpoint: string; token: string } | null;
		canReview?: boolean;
		syncRevision?: number;
	} = $props();
	let section = $state<'notifications' | 'settings' | null>(null);
	let dialog: HTMLDialogElement;
	let feed = $state<NotificationFeed | null>(null);
	let usage = $state<UsageSummary | null>(null);
	let refreshing = $state(false),
		loadingUsage = $state(false),
		marking = $state(false);
	let feedError = $state(''),
		usageError = $state('');
	let checkedAt = $state<Date | null>(null);
	let hub: ServiceHub | null = null;
	let active = false;
	const unread = $derived(feed?.unread_count ?? 0);
	const notifications = $derived([...(feed?.notifications ?? [])].reverse());
	const metricNames: Record<string, string> = {
		d1_rows_read: 'D1 reads',
		d1_rows_written: 'D1 writes',
		requests: 'Requests',
		d1_storage_bytes: 'D1 storage'
	};
	const date = (value: string) =>
		new Date(value).toLocaleDateString('en-US', {
			timeZone: 'UTC',
			month: 'short',
			day: 'numeric',
			year: 'numeric'
		});
	const timestamp = (value: string | null) =>
		value ? new Date(value).toLocaleString() : 'not measured yet';
	const amount = (value: number | null, unit: string) => {
		if (value === null) return 'Unmeasured';
		if (unit === 'bytes') {
			const divisor = value >= 1e9 ? 1e9 : value >= 1e6 ? 1e6 : value >= 1e3 ? 1e3 : 1;
			return `${(value / divisor).toLocaleString(undefined, { maximumFractionDigits: 2 })} ${divisor === 1e9 ? 'GB' : divisor === 1e6 ? 'MB' : divisor === 1e3 ? 'KB' : 'bytes'}`;
		}
		return value.toLocaleString();
	};
	const message = (e: unknown) => (e instanceof Error ? e.message : 'The request failed.');

	async function refreshFeed() {
		if (!hub || !active || refreshing || marking) return;
		feedAt = Date.now();
		refreshing = true;
		try {
			const result = await readNotifications(hub);
			if (active) {
				feed = result;
				checkedAt = new Date();
				feedError = '';
			}
		} catch (e) {
			if (active) feedError = message(e);
		} finally {
			if (active) refreshing = false;
		}
	}
	async function refreshUsage() {
		if (!hub || !active || loadingUsage) return;
		usageAt = Date.now();
		loadingUsage = true;
		try {
			const result = await readUsage(hub);
			if (active) {
				usage = result;
				usageError = '';
			}
		} catch (e) {
			if (active) usageError = message(e);
		} finally {
			if (active) loadingUsage = false;
		}
	}
	async function markRead(ids?: string[]) {
		if (!hub || !feed || refreshing || marking) return;
		marking = true;
		try {
			await markNotificationsRead(hub, ids ? { ids } : { through: feed.latest_cursor });
			if (active) {
				marking = false;
				await refreshFeed();
			}
		} catch (e) {
			if (active) feedError = message(e);
		} finally {
			if (active) marking = false;
		}
	}
	async function open(next: 'notifications' | 'settings') {
		section = next;
		await tick();
		dialog.showModal();
		if (next === 'settings') void refreshUsage();
		else void refreshFeed();
	}
	// An open panel follows the background sync loop, at most every 30 s so a
	// slow read never keeps its actions disabled.
	let feedAt = 0,
		usageAt = 0;
	$effect(() => {
		if (!syncRevision) return;
		const stale = (at: number) => Date.now() - at > 30_000;
		if (section === 'settings' && stale(usageAt)) void refreshUsage();
		else if (section === 'notifications' && stale(feedAt)) void refreshFeed();
	});
	onMount(() => {
		if (!connection) return;
		active = true;
		const abort = new AbortController();
		hub = createHttpHub(connection.endpoint, connection.token, (url, init) =>
			fetch(url, { ...init, signal: AbortSignal.any([abort.signal, AbortSignal.timeout(15000)]) })
		);
		const foreground = () => {
			if (document.visibilityState !== 'visible' || !navigator.onLine) return;
			void refreshFeed();
			if (section === 'settings') void refreshUsage();
		};
		foreground();
		const timer = setInterval(() => {
			if (document.visibilityState === 'visible' && navigator.onLine) void refreshFeed();
		}, 60000);
		document.addEventListener('visibilitychange', foreground);
		window.addEventListener('online', foreground);
		return () => {
			active = false;
			abort.abort();
			clearInterval(timer);
			document.removeEventListener('visibilitychange', foreground);
			window.removeEventListener('online', foreground);
		};
	});
</script>

<div class="service-actions">
	<ChangesetReview {connection} {canReview} />
	<button
		disabled={!connection}
		aria-label={feed ? `Notifications, ${unread} unread` : 'Notifications'}
		onclick={() => open('notifications')}
	>
		<IconBell size={17} /> Notifications {#if unread > 0}<span class="badge">{unread}</span>{/if}
	</button>
	<button disabled={!connection} onclick={() => open('settings')}
		><IconSettings size={17} /> Settings</button
	>
</div>

<dialog bind:this={dialog} onclose={() => (section = null)} aria-labelledby="services-title">
	<header>
		<div>
			<h2 id="services-title">{section === 'notifications' ? 'Notifications' : 'Settings'}</h2>
			<p class="endpoint">{connection?.endpoint}</p>
		</div>
		<button aria-label="Close" onclick={() => dialog.close()}><IconX size={20} /></button>
	</header>
	{#if section === 'notifications'}
		<div class="actions">
			<p>
				{feed
					? `${unread} unread`
					: refreshing
						? 'Loading notifications…'
						: 'Notifications unavailable'}
			</p>
			<button disabled={!unread || refreshing || marking} onclick={() => markRead()}
				>Mark all read</button
			>
		</div>
		{#if feedError}<p role="alert" class="failure">
				Could not update notifications: {feedError}
				{feed ? 'Showing the last successful result.' : ''}
			</p>{/if}
		{#if checkedAt}<p class="muted">
				Last checked {checkedAt.toLocaleString()}. Read state is shared across your devices.
			</p>{/if}
		{#if feed && !notifications.length}<p>No notifications yet.</p>{/if}
		<div class="notifications">
			{#each notifications as notification (notification.id)}
				<article class:unread={!notification.read_at}>
					<div class="notification-meta">
						<span>{notification.severity}</span><time datetime={notification.created_at}
							>{timestamp(notification.created_at)}</time
						>
					</div>
					<h3>{notification.title}</h3>
					<p>{notification.body}</p>
					{#if !notification.read_at}<button
							disabled={marking || refreshing}
							onclick={() => markRead([notification.id])}
							>Mark read<span class="sr-only">: {notification.title}</span></button
						>{/if}
				</article>
			{/each}
		</div>
	{:else if section === 'settings'}
		<div class="actions">
			<h3>Usage</h3>
		</div>
		<p class="muted">Usage for this hub deployment.</p>
		{#if usageError}<p role="alert" class="failure">
				Could not update usage: {usageError}
				{usage ? 'Showing the last successful result.' : ''}
			</p>{/if}
		{#if usage}
			<p>{date(usage.period.start)} - {date(usage.period.end)} <span class="muted">(UTC)</span></p>
			<p class="muted">Resets {date(usage.period.end)}. Measured {timestamp(usage.measured_at)}.</p>
			{#if usage.capped}
				<p class="failure" role="status">
					Sync is paused at the {metricNames[usage.capped.metric] ?? usage.capped.metric} cap. Resets
					{timestamp(usage.capped.resets_at)}. Local editing and notifications remain available.
				</p>
			{/if}
			<div class="metrics">
				{#each Object.entries(usage.metrics) as [key, metric] (key)}
					<section aria-label={metricNames[key] ?? key} class="metric">
						<h4>{metricNames[key] ?? key}</h4>
						<strong>{amount(metric.used, metric.unit)}</strong>
						<p>
							{metric.kind === 'gauge' ? 'Current storage' : 'This billing month'}{metric.unit ===
							'rows'
								? ' · rows'
								: ''}
						</p>
						<div class="limit">
							<span>Free allowance</span><span>{amount(metric.allowance, metric.unit)}</span>
						</div>
						{#if metric.used !== null && metric.allowance !== null && metric.allowance > 0}<progress
								aria-label={`${metricNames[key] ?? key} free allowance`}
								max={metric.allowance}
								value={metric.used}
							></progress>{/if}
						<div class="limit">
							<span>Hard cap</span><span
								>{metric.cap === null ? 'No hard cap' : amount(metric.cap, metric.unit)}</span
							>
						</div>
						{#if metric.used !== null && metric.cap !== null && metric.cap > 0}<progress
								aria-label={`${metricNames[key] ?? key} hard cap`}
								max={metric.cap}
								value={metric.used}
							></progress>{/if}
						<small
							>{metric.measured_at
								? `Measured ${timestamp(metric.measured_at)}`
								: 'Not measured yet'}</small
						>
					</section>
				{/each}
			</div>
			<h3>Devices and services</h3>
			<p class="muted">Storage belongs to the deployment and is not split between devices.</p>
			<div class="table-scroll">
				<table>
					<thead
						><tr><th>Device or service</th><th>Reads</th><th>Writes</th><th>Requests</th></tr
						></thead
					><tbody>
						{#each usage.by_principal as principal (principal.id)}<tr
								><th scope="row"
									>{principal.label || principal.id}<small>{principal.kind}</small></th
								><td>{amount(principal.rows_read, 'rows')}</td><td
									>{amount(principal.rows_written, 'rows')}</td
								><td>{amount(principal.requests, 'requests')}</td></tr
							>{/each}
					</tbody>
				</table>
			</div>
		{:else if loadingUsage}<p>Loading usage…</p>{/if}
	{/if}
</dialog>

<style>
	.service-actions {
		display: grid;
		gap: 0.4rem;
		margin: 0.6rem 0;
	}
	button {
		display: inline-flex;
		align-items: center;
		gap: 0.5rem;
		min-height: 38px;
		padding: 0.4rem 0.65rem;
		color: var(--color-ink);
		background: var(--color-paper);
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		cursor: pointer;
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	.badge {
		margin-left: auto;
		min-width: 1.4rem;
		padding: 0.08rem 0.3rem;
		background: var(--color-accent);
		color: var(--color-on-accent);
		border-radius: 1rem;
		font-size: 0.8rem;
	}
	dialog {
		width: min(760px, calc(100vw - 2rem));
		max-height: calc(100dvh - 2rem);
		margin: auto;
		padding: 1.5rem;
		color: var(--color-ink);
		background: var(--color-paper);
		border: 1px solid var(--color-rule);
		border-radius: 0.75rem;
		overflow-y: auto;
	}
	dialog::backdrop {
		background: #0007;
	}
	header {
		display: flex;
		justify-content: space-between;
		align-items: start;
		gap: 1rem;
	}
	h2 {
		margin: 0;
		font-size: 1.5rem;
		font-weight: 650;
	}
	h3 {
		font-size: 1.1rem;
		font-weight: 600;
	}
	h4 {
		margin: 0 0 0.4rem;
		font-size: 1rem;
		font-weight: 600;
	}
	p {
		margin: 0.5rem 0;
		line-height: 1.5;
	}
	.endpoint {
		max-width: 55ch;
		overflow-wrap: anywhere;
		color: var(--color-muted);
		font-size: 0.85rem;
	}
	.actions {
		display: flex;
		gap: 0.5rem;
		align-items: center;
		flex-wrap: wrap;
		margin-top: 1rem;
	}
	.actions p,
	.actions h3 {
		margin-right: auto;
	}
	.muted,
	small,
	.notification-meta {
		color: var(--color-muted);
		font-size: 0.8rem;
	}
	.failure {
		color: var(--color-violation);
	}
	.notifications article {
		padding: 1rem 0;
		border-bottom: 1px solid var(--color-rule);
	}
	.notifications article.unread {
		border-left: 3px solid var(--color-accent);
		padding-left: 0.8rem;
	}
	.notifications h3 {
		margin: 0.35rem 0;
	}
	.notification-meta {
		display: flex;
		justify-content: space-between;
		gap: 1rem;
	}
	.metrics {
		margin: 1.2rem 0;
		display: grid;
		grid-template-columns: repeat(2, minmax(0, 1fr));
		gap: 1.4rem;
	}
	.metric {
		border-top: 1px solid var(--color-rule);
		padding-top: 0.8rem;
	}
	.metric strong {
		font-size: 1.5rem;
		font-variant-numeric: tabular-nums;
	}
	.metric p {
		font-size: 0.8rem;
		color: var(--color-muted);
	}
	.limit {
		display: flex;
		justify-content: space-between;
		gap: 0.6rem;
		margin-top: 0.6rem;
		font-size: 0.8rem;
	}
	progress {
		display: block;
		width: 100%;
		height: 6px;
		margin: 0.4rem 0;
		accent-color: var(--color-accent);
	}
	.metric small {
		display: block;
		margin-top: 0.6rem;
	}
	.table-scroll {
		overflow-x: auto;
	}
	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 0.85rem;
		font-variant-numeric: tabular-nums;
	}
	th,
	td {
		padding: 0.7rem 0.5rem;
		text-align: right;
		border-bottom: 1px solid var(--color-rule);
	}
	th:first-child {
		text-align: left;
	}
	th small {
		display: block;
		font-weight: normal;
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip-path: inset(50%);
	}
	@media (max-width: 540px) {
		dialog {
			padding: 1rem;
		}
		.metrics {
			grid-template-columns: minmax(0, 1fr);
		}
		.notification-meta {
			flex-wrap: wrap;
			gap: 0.25rem;
		}
	}
</style>
