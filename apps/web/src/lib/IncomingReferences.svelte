<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import { IconArrowUpRight, IconRefresh } from '@tabler/icons-svelte';
	import type { WorkspaceDatabase } from './database';
	import { calendarContext } from './calendar-context';
	import { createIncomingReferences } from './incoming-references';
	let {
		core,
		table,
		rowId,
		disabled = false,
		onopen
	}: {
		core: Pick<WorkspaceDatabase, 'request'>;
		table: string;
		rowId: string;
		disabled?: boolean;
		onopen(target: { table: string; id: string }, button: HTMLButtonElement): Promise<void>;
	} = $props();
	const model = createIncomingReferences(
		() => core.request('referenceSources', { table }),
		async (source, offset) => {
			const preference = await core.request('getRelatedViewDefault', { table: source.table });
			const definition = preference.view?.definition;
			return core.request('referencedBy', {
				table,
				rowId,
				sourceTable: source.table,
				column: source.column,
				limit: 20,
				offset,
				expectedViewUpdatedAt: preference.view?.updated_at ?? undefined,
				calendar: definition?.timeZone
					? calendarContext(definition.timeZone, new Date(), definition.dayStartMinutes ?? 0)
					: undefined
			});
		}
	);
	onMount(() => {
		void model.refresh();
	});
	onDestroy(() => model.dispose());
</script>

<section aria-label="Referenced by" class="incoming">
	<header>
		<h3>Referenced by</h3>
		<button
			type="button"
			aria-label="Refresh relationships"
			disabled={$model.loading}
			onclick={() => model.refresh()}><IconRefresh size={16} /></button
		>
	</header>
	{#if $model.loading}<p role="status">Loading relationships…</p>
	{:else if $model.error}<p role="alert">{$model.error}</p>
		<button type="button" onclick={() => model.refresh()}>Retry</button>
	{:else if !$model.groups.length}<p>No incoming relationship fields.</p>{/if}
	{#each $model.groups as group (group.key)}
		<details
			aria-label={`${group.source.table} / ${group.source.label}`}
			ontoggle={(event) => {
				if (event.currentTarget.open) void model.load(group.key);
			}}
		>
			<summary><span>{group.source.table} / {group.source.label}</span></summary>
			{#if group.source.incomplete}<p class="partial" role="status">
					Local relationships may be incomplete. Some tables are not fully downloaded.
				</p>{/if}
			{#if group.viewUnavailable}<p role="status">{group.viewUnavailable}</p>{/if}
			{#if group.error}<p role="alert">{group.error}</p>
				<button
					type="button"
					disabled={group.loading}
					onclick={() => model.load(group.key, group.loaded)}>Retry</button
				>{/if}
			<ul>
				{#each group.rows as row (row.record.id)}
					<li>
						<button
							type="button"
							class="record"
							aria-label={`Open ${row.label}`}
							{disabled}
							onclick={(event) =>
								onopen(
									{ table: group.source.table, id: String(row.record.id) },
									event.currentTarget
								)}><span>{row.label}</span><IconArrowUpRight size={16} /></button
						>
					</li>
				{/each}
			</ul>
			{#if group.loading}<p role="status">Loading records…</p>
			{:else if group.loaded && !group.rows.length}<p>
					No local records reference this record.
				</p>{/if}
			{#if group.loaded && group.nextOffset !== null && !group.error}<button
					type="button"
					disabled={group.loading}
					onclick={() => model.load(group.key, true)}>Load more</button
				>{/if}
		</details>
	{/each}
</section>

<style>
	.incoming {
		border-top: 1px solid var(--color-rule);
		margin-top: 1.5rem;
		padding-top: 1rem;
		min-width: 0;
	}
	header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 1rem;
	}
	h3 {
		font-size: 0.9rem;
		font-weight: 650;
	}
	details {
		border-bottom: 1px solid var(--color-rule);
		padding: 0.75rem 0;
	}
	summary {
		cursor: pointer;
		font-size: 0.82rem;
		overflow-wrap: anywhere;
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
		overflow-wrap: anywhere;
		min-width: 0;
	}
	button:focus-visible,
	summary:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 2px;
	}
</style>
