<script lang="ts">
	import { onMount, onDestroy, untrack } from 'svelte';
	import { IconArrowUpRight } from '@tabler/icons-svelte';
	import type { WorkspaceDatabase } from './database';
	import { createLinkedFrom } from './linked-from';
	let {
		core,
		table,
		rowId,
		revision = 0,
		disabled = false,
		onopen
	}: {
		core: Pick<WorkspaceDatabase, 'request'>;
		table: string;
		rowId: string;
		revision?: number;
		disabled?: boolean;
		onopen(target: { table: string; id: string }, button: HTMLButtonElement): Promise<void>;
	} = $props();
	const model = createLinkedFrom((offset) =>
		core.request('mentionedBy', { table, rowId, limit: 20, offset })
	);
	onMount(() => void model.load());
	// Bodies edited here, in other tabs or by sync change who links to this record.
	let seen = untrack(() => revision);
	$effect(() => {
		if (revision === seen) return;
		seen = revision;
		void model.load();
	});
	onDestroy(() => model.dispose());
</script>

<section aria-label="Linked from" class="incoming">
	<header>
		<h3>
			Linked from{#if $model.indexing}<span class="indexing" role="status">(indexing)</span>{/if}
		</h3>
	</header>
	{#if $model.incomplete}<p class="partial" role="status">
			Local links may be incomplete. Some tables are not fully downloaded.
		</p>{/if}
	{#if $model.error}<p role="alert">{$model.error}</p>
		<button
			type="button"
			disabled={$model.loading}
			onclick={() => model.load($model.rows.length > 0)}>Retry</button
		>{/if}
	{#if $model.loading && !$model.rows.length}<p role="status">Loading links…</p>
	{:else if $model.loaded && !$model.rows.length && !$model.error}<p>
			{$model.indexing
				? 'No links found yet. Search is still indexing this device.'
				: 'No local records mention this record.'}
		</p>{/if}
	<ul>
		{#each $model.rows as row (`${row.table}/${row.id}`)}
			<li>
				<button
					type="button"
					class="record"
					aria-label={`Open ${row.label}`}
					{disabled}
					onclick={(event) => onopen({ table: row.table, id: row.id }, event.currentTarget)}
					><span>{row.label}<small>{row.table.replace(/_/g, ' ')}</small></span><IconArrowUpRight
						size={16}
					/></button
				>
			</li>
		{/each}
	</ul>
	{#if $model.nextOffset !== null && !$model.error}<button
			type="button"
			disabled={$model.loading}
			onclick={() => model.load(true)}>Load more</button
		>{/if}
</section>

<style>
	.incoming {
		border-top: 1px solid var(--color-rule);
		margin-top: 1.5rem;
		padding-top: 1rem;
		min-width: 0;
	}
	h3 {
		font-size: 0.9rem;
		font-weight: 650;
	}
	.indexing {
		margin-left: 0.35em;
		color: var(--color-muted);
		font-weight: 400;
	}
	p {
		margin: 0.65rem 0;
		color: var(--color-muted);
		font-size: 0.78rem;
		line-height: 1.5;
		overflow-wrap: anywhere;
	}
	.partial {
		border-left: 2px solid var(--color-accent);
		padding-left: 0.65rem;
	}
	ul {
		padding: 0;
		list-style: none;
		margin: 0.6rem 0;
	}
	li + li {
		margin-top: 0.3rem;
	}
	button {
		display: inline-flex;
		gap: 0.5rem;
		align-items: center;
		min-height: 36px;
		max-width: 100%;
		padding: 0.4rem 0.65rem;
		border: 1px solid var(--color-rule);
		border-radius: 0.35rem;
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
		font-size: 0.8rem;
		cursor: pointer;
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	.record {
		width: 100%;
		text-align: left;
		justify-content: space-between;
	}
	.record span {
		display: flex;
		flex-direction: column;
		overflow-wrap: anywhere;
		min-width: 0;
	}
	small {
		color: var(--color-muted);
		font-size: 0.72rem;
	}
	button:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 2px;
	}
</style>
