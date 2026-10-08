<script lang="ts">
	import { onDestroy } from 'svelte';
	import type { RejectedEdit } from 'life-ui-core/client';
	import type { WorkspaceDatabase } from './database';
	import { createRejectionInbox, type RejectionSnapshot } from './rejection-inbox';
	let {
		core,
		total,
		snapshot,
		disabled = false,
		onreview
	}: {
		core: Pick<WorkspaceDatabase, 'request'>;
		total: number;
		snapshot: RejectionSnapshot;
		disabled?: boolean;
		onreview(entry: RejectedEdit): Promise<void>;
	} = $props();
	const model = createRejectionInbox((offset) =>
		core.request('rejections', { limit: 100, offset })
	);
	$effect(() => model.reset(total, snapshot));
	onDestroy(() => model.dispose());
</script>

{#if $model.total || $model.error}
	<details class="rejections" id="rejected-edits">
		<summary>{$model.total} rejected edits need attention</summary>
		<p role="status">Showing {$model.entries.length} of {$model.total} rejected edits</p>
		{#each $model.entries as entry (JSON.stringify([entry.table, entry.rowID]))}
			<article>
				<p>
					{entry.table} / {entry.rowID}: {entry.errors
						.map((error) => String(error.message ?? error.error ?? error.rule ?? 'Edit rejected'))
						.join('\n')}
				</p>
				<button type="button" {disabled} onclick={() => onreview(entry)}
					>Review rejected edit</button
				>
			</article>
		{/each}
		{#if $model.error}
			<p role="alert">{$model.error}</p>
			<button type="button" disabled={$model.loading} onclick={() => model.more()}
				>Retry rejected edits</button
			>
		{:else if $model.nextOffset !== null}
			<button type="button" disabled={$model.loading} onclick={() => model.more()}
				>Load more rejected edits</button
			>
		{/if}
		{#if $model.loading}<p role="status">Loading rejected edits…</p>{/if}
	</details>
{/if}

<style>
	.rejections {
		font-size: 13px;
		padding: 12px;
		background: var(--color-accent-soft);
		border-radius: 6px;
		margin-bottom: 16px;
		overflow-wrap: anywhere;
	}
	summary {
		cursor: pointer;
	}
	p {
		margin: 0.65rem 0;
		white-space: pre-line;
	}
	article {
		padding: 0.5rem 0;
		border-bottom: 1px solid var(--color-rule);
	}
	button {
		margin-top: 0.5rem;
		min-height: 36px;
		padding: 0.4rem 0.65rem;
		border: 1px solid var(--color-rule);
		border-radius: 0.35rem;
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
		cursor: pointer;
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	button:focus-visible,
	summary:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 2px;
	}
	[role='alert'] {
		color: var(--color-violation);
	}
</style>
