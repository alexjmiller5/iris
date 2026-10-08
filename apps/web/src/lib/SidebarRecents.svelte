<script lang="ts">
	import { IconDatabase, IconFile, IconLayoutList, IconX } from '@tabler/icons-svelte';
	import { recentKey, type RecentEntry } from './sidebar-recents';
	import type { Destination } from './workspace-navigation';
	let {
		entries,
		current,
		busy,
		storageError,
		onchoose,
		onremove
	}: {
		entries: RecentEntry[];
		current: Destination | null;
		busy: boolean;
		storageError: string;
		onchoose: (destination: Destination) => unknown;
		onremove: (destination: Destination) => void;
	} = $props();
</script>

<section aria-label="Recents">
	<h2>Recent</h2>
	{#if storageError}<p role="status" class="storage-error">{storageError}</p>{/if}
	<nav aria-label="Recent destinations">
		{#each entries as entry (recentKey(entry.destination))}
			<div class="entry">
				<button
					class="destination"
					type="button"
					aria-current={current && recentKey(current) === recentKey(entry.destination)
						? 'page'
						: undefined}
					disabled={busy || entry.loading || !!entry.unavailable}
					onclick={() => onchoose(entry.destination)}
				>
					{#if entry.destination.row}<IconFile
							size={16}
						/>{:else if entry.destination.view}<IconLayoutList size={16} />{:else}<IconDatabase
							size={16}
						/>{/if}
					<span
						><strong>{entry.label}</strong> <small
							>{entry.context}{entry.trash ? ' · Trash' : ''}</small
						>{#if entry.loading}<small>Loading…</small>{/if}</span
					>
				</button>
				<button
					class="remove"
					type="button"
					aria-label={`Remove ${entry.label} from recents`}
					onclick={() => onremove(entry.destination)}><IconX size={14} /></button
				>
				{#if entry.unavailable}<p class="reason">{entry.unavailable}</p>{/if}
			</div>
		{:else}<p class="empty">Opened tables, views and records appear here.</p>{/each}
	</nav>
</section>

<style>
	section {
		min-width: 0;
	}
	h2 {
		font-size: 12px;
		font-weight: 600;
		color: var(--color-muted);
		margin: 0 8px 8px;
	}
	nav {
		display: grid;
		gap: 4px;
		max-height: 42vh;
		overflow: auto;
		padding: 3px;
	}
	.entry {
		display: grid;
		grid-template-columns: minmax(0, 1fr) 28px;
		align-items: start;
	}
	button {
		border: 0;
		border-radius: var(--radius-field);
		background: none;
		color: var(--color-muted);
		cursor: pointer;
	}
	.destination {
		display: flex;
		align-items: start;
		gap: 8px;
		text-align: left;
		min-width: 0;
		padding: 8px;
		font-size: 12px;
	}
	.destination :global(svg) {
		flex: none;
		margin-top: 2px;
	}
	.destination span {
		min-width: 0;
		overflow-wrap: anywhere;
	}
	strong {
		display: block;
		font-weight: 500;
		color: var(--color-ink);
	}
	small {
		display: block;
		font-size: 10px;
		line-height: 1.5;
		margin-top: 2px;
	}
	.destination[aria-current] {
		background: var(--color-accent-soft);
		color: var(--color-accent);
	}
	.destination[aria-current] strong {
		color: var(--color-accent);
	}
	.destination:disabled {
		cursor: default;
		opacity: 0.65;
	}
	.remove {
		display: grid;
		place-items: center;
		width: 28px;
		min-height: 32px;
	}
	.remove:hover {
		color: var(--color-ink);
		background: var(--color-bone);
	}
	p {
		font-size: 11px;
		line-height: 1.5;
		color: var(--color-muted);
		margin: 4px 8px;
		overflow-wrap: anywhere;
	}
	.reason {
		grid-column: 1/-1;
		margin-bottom: 8px;
	}
	.storage-error {
		color: var(--color-violation);
	}
	@media (max-width: 700px) {
		nav {
			display: flex;
			max-height: 160px;
		}
		.entry {
			flex: 0 0 200px;
		}
		.empty {
			margin: 0 8px;
		}
	}
</style>
