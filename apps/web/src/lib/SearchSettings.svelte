<script lang="ts">
	import { IconListSearch, IconX } from '@tabler/icons-svelte';
	import type { SearchTable } from 'iris-core/client';
	import BreakName from './BreakName.svelte';
	import Skeleton from './Skeleton.svelte';
	import type { WorkspaceDatabase } from './database';
	import { searchChoice, searchTableDetail } from './search-settings';

	let { database }: { database: WorkspaceDatabase } = $props();

	let dialog: HTMLDialogElement;
	let tables = $state<SearchTable[] | null>(null);
	let sizeLimit = $state(0);
	let busy = $state('');
	let failure = $state('');

	async function open() {
		failure = '';
		tables = null;
		dialog.showModal();
		const db = database;
		try {
			const list = await db.request('searchTables');
			if (db !== database) return;
			tables = list.tables;
			sizeLimit = list.sizeLimit;
		} catch (error) {
			if (db === database) failure = (error as Error).message;
		}
	}

	async function choose(table: SearchTable, input: HTMLInputElement) {
		const db = database;
		busy = table.table;
		failure = '';
		try {
			// The worker runs the index step next: it backfills or removes this table's entries.
			const list = await db.request('setSearchTable', {
				table: table.table,
				indexed: searchChoice(table, input.checked)
			});
			if (db !== database) return;
			tables = list.tables;
			sizeLimit = list.sizeLimit;
		} catch (error) {
			input.checked = table.indexed;
			if (db === database) failure = (error as Error).message;
		} finally {
			busy = '';
		}
	}
</script>

<button class="open" onclick={() => open()}><IconListSearch size={17} /> Search index</button>

<dialog
	bind:this={dialog}
	aria-labelledby="search-settings-title"
	aria-describedby="search-settings-description"
>
	<header>
		<div>
			<h2 id="search-settings-title">Search index</h2>
			<p class="muted" id="search-settings-description">
				Tables that Find and ⌘K search on this device. Turning one on indexes its text in the
				background; turning one off removes it from results.
			</p>
		</div>
		<button aria-label="Close" onclick={() => dialog.close()}><IconX size={20} /></button>
	</header>
	<div class="status" aria-live="polite">
		{#if !tables && !failure}<Skeleton shape="list" rows={4} label="Reading tables" />{/if}
		{#if failure}<p role="alert" class="failure">{failure}</p>{/if}
	</div>
	{#if tables}
		{#if !tables.length}<p class="muted">No table has text to search.</p>{/if}
		<ul class="list">
			{#each tables as table (table.table)}
				<li>
					<label>
						<input
							type="checkbox"
							checked={table.indexed}
							disabled={!!busy}
							onchange={(event) => choose(table, event.currentTarget)}
						/>
						<span>
							<span class="name"><BreakName name={table.table} /></span>
							<small>{searchTableDetail(table, sizeLimit)}</small>
						</span>
					</label>
				</li>
			{/each}
		</ul>
	{/if}
</dialog>

<style>
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
		white-space: nowrap;
	}
	/* Matches the sidebar's other secondary buttons (Table graph, Backup). */
	.open {
		width: 100%;
		justify-content: center;
		font-size: 13px;
		font-weight: 600;
	}
	dialog {
		width: min(640px, calc(100vw - 2rem));
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
	p {
		margin: 0.4rem 0;
		line-height: 1.5;
	}
	.muted,
	small {
		color: var(--color-muted);
		font-size: 0.85rem;
	}
	.failure {
		color: var(--color-violation);
	}
	.list {
		list-style: none;
		margin: 0.75rem 0 0;
		padding: 0;
	}
	.list li {
		border-bottom: 1px solid var(--color-rule);
	}
	label {
		display: flex;
		align-items: start;
		gap: 0.75rem;
		padding: 0.6rem 0;
		cursor: pointer;
	}
	input {
		flex: none;
		width: 1.1rem;
		height: 1.1rem;
		margin: 0.15rem 0 0;
		accent-color: var(--color-accent);
	}
	label > span {
		display: grid;
		gap: 0.15rem;
		min-width: 0;
	}
	.name {
		font-weight: 600;
		overflow-wrap: anywhere;
	}
	small {
		font-variant-numeric: tabular-nums;
	}
</style>
