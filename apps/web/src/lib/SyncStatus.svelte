<script lang="ts">
	import { syncPill, type PillInput } from './sync-status';
	let {
		onaction,
		...input
	}: Omit<PillInput, 'now'> & { onaction(action: 'rejected' | 'connect'): void } = $props();
	// Read the clock when someone looks; the title is the only time-dependent text.
	let now = $state(Date.now());
	const pill = $derived(syncPill({ ...input, now }));
	const look = () => (now = Date.now());
</script>

<div
	class="sync-status"
	data-tone={pill.tone}
	data-last-sync={input.lastSync ?? ''}
	data-pending={input.pending}
	aria-live="polite"
>
	{#if pill.action}
		{@const action = pill.action}
		<button
			type="button"
			title={pill.title}
			aria-label={`Sync status: ${pill.label}`}
			onpointerenter={look}
			onfocus={look}
			onclick={() => onaction(action)}><span class="dot"></span>{pill.label}</button
		>
	{:else}
		<span
			role="status"
			title={pill.title}
			aria-label={`Sync status: ${pill.label}`}
			onpointerenter={look}><span class="dot"></span>{pill.label}</span
		>
	{/if}
</div>

<style>
	.sync-status > * {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		max-width: 100%;
		padding: 4px 10px;
		border: 1px solid var(--color-rule);
		border-radius: 999px;
		background: var(--color-bone);
		color: var(--color-muted);
		font: inherit;
		font-size: 12px;
		line-height: 1.4;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	button {
		cursor: pointer;
	}
	button:hover {
		color: var(--color-ink);
	}
	button:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 2px;
	}
	.dot {
		flex: none;
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--color-muted);
	}
	[data-tone='ok'] .dot {
		background: var(--color-valid);
	}
	[data-tone='busy'] .dot {
		background: var(--color-accent);
		animation: pulse 1.2s ease-in-out infinite;
	}
	[data-tone='warn'] .dot {
		background: transparent;
		border: 1.5px solid var(--color-muted);
	}
	[data-tone='error'] .dot {
		background: var(--color-violation);
	}
	[data-tone='error'] > * {
		color: var(--color-violation);
	}
	@keyframes pulse {
		50% {
			opacity: 0.35;
		}
	}
	@media (prefers-reduced-motion: reduce) {
		[data-tone='busy'] .dot {
			animation: none;
		}
	}
</style>
