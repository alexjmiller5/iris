<script lang="ts">
	import { onDestroy, tick } from 'svelte';
	import { IconDeviceFloppy, IconTrash } from '@tabler/icons-svelte';
	import type { SavedViewRecord } from 'life-ui-core/client';
	import { createSavedViewsModel } from './saved-views';

	// Key this component by table/workspace so even two empty lists have distinct lifetimes.
	let {
		list,
		unavailable,
		busy,
		selected = null,
		modified,
		onchoose,
		onsave,
		ondelete
	}: {
		list: SavedViewRecord[];
		unavailable: string | null;
		busy: boolean;
		selected?: string | null;
		modified: boolean;
		onchoose: (id: string | null) => Promise<boolean | void>;
		onsave: (name: string, update: boolean) => Promise<void>;
		ondelete: (id: string) => Promise<void>;
	} = $props();

	const id = $props.id();
	const model = createSavedViewsModel();
	const current = $derived(list.find((view) => view.id === selected));
	const table = $derived(current?.tbl ?? list[0]?.tbl ?? '');
	const context = $derived(JSON.stringify([table, selected]));
	const locked = $derived(busy || $model.pending !== null);
	const canDelete = $derived(!!current?.updated_at && !current.deleted_at && !unavailable);
	const canUpdate = $derived(canDelete && !!current?.view && !current.unavailable);
	let select: HTMLSelectElement;
	let input: HTMLInputElement;
	let deleteButton: HTMLButtonElement;
	let cancelButton = $state<HTMLButtonElement>();
	let mounted = true;

	$effect(() => model.setContext(context, current?.name ?? ''));
	onDestroy(() => {
		mounted = false;
		model.dispose();
	});

	async function choose(event: Event & { currentTarget: HTMLSelectElement }) {
		const target = event.currentTarget.value || null;
		const before = selected,
			sourceTable = table;
		event.currentTarget.value = selected ?? '';
		if (locked) return;
		await model.run('choose', () => onchoose(target));
		await tick();
		if (
			mounted &&
			table === sourceTable &&
			(selected === before || selected === target) &&
			!locked
		) {
			select.value = selected ?? '';
			select.focus();
		}
	}
	async function save(update: boolean) {
		if (locked || unavailable || !$model.name.trim() || (update && !canUpdate)) return;
		const name = $model.name.trim(),
			identity = context;
		await model.run(update ? 'update' : 'save', () => onsave(name, update));
		await tick();
		if (mounted && context === identity && $model.error && !locked) input.focus();
	}
	async function confirm(confirming: boolean) {
		if (locked || (confirming && !canDelete)) return;
		const identity = context;
		model.confirmDelete(confirming);
		await tick();
		if (mounted && context === identity && !locked) {
			(confirming ? cancelButton : canDelete ? deleteButton : select)?.focus();
		}
	}
	async function remove() {
		if (locked || !canDelete || !$model.confirming || !current) return;
		const target = current.id,
			sourceTable = table;
		await model.run('delete', () => ondelete(target));
		await tick();
		if (mounted && table === sourceTable && (selected === target || selected === null) && !locked) {
			if ($model.error) cancelButton?.focus();
			else select.focus();
		}
	}
	const reason = (view: SavedViewRecord) =>
		view.unavailable ||
		(view.deleted_at ? 'This view was deleted.' : !view.view ? 'This view is unavailable.' : '');
</script>

<div class="saved-views" role="group" aria-label="Saved views" aria-busy={locked}>
	<div class="fields">
		<label class="view">
			View
			<select
				bind:this={select}
				aria-label="View"
				value={selected ?? ''}
				disabled={locked}
				onchange={choose}
			>
				<option value="">All records</option>
				{#if selected && !current}<option value={selected} disabled>Unavailable view</option>{/if}
				{#each list as view (view.id)}
					<option value={view.id} disabled={!!reason(view)}
						>{view.name}{reason(view) ? ` (${reason(view)})` : ''}</option
					>
				{/each}
			</select>
		</label>
		<label class="name">
			View name
			<input
				bind:this={input}
				aria-label="View name"
				placeholder="Name this view"
				value={$model.name}
				disabled={locked || !!unavailable}
				oninput={(event) => model.setName(event.currentTarget.value)}
			/>
		</label>
		<div class="actions">
			<button
				type="button"
				disabled={locked || !!unavailable || !$model.name.trim()}
				onclick={() => save(false)}
			>
				<IconDeviceFloppy size={16} aria-hidden="true" />Save as
			</button>
			<button
				type="button"
				disabled={locked || !canUpdate || !$model.name.trim()}
				onclick={() => save(true)}>Update selected</button
			>
			<button
				bind:this={deleteButton}
				type="button"
				disabled={locked || !canDelete}
				onclick={() => confirm(true)}
			>
				<IconTrash size={16} aria-hidden="true" />Delete view
			</button>
		</div>
	</div>
	{#if modified}<span class="modified">Modified</span>{/if}
	{#if unavailable}<p class="hint">Saved views are unavailable. {unavailable}</p>{/if}
	{#if selected && !current}<p class="hint">
			This view is no longer available. Choose All records or another view.
		</p>
	{:else if current && reason(current)}<p class="hint">{reason(current)}</p>{/if}
	{#if $model.confirming && current}
		<div
			class="confirmation"
			role="group"
			aria-label="Confirm deletion"
			aria-describedby={`${id}-delete-help`}
		>
			<p id={`${id}-delete-help`}>Delete “{current.name}”? Your records will be kept.</p>
			<div class="actions">
				<button
					bind:this={cancelButton}
					type="button"
					disabled={locked}
					onclick={() => confirm(false)}>Cancel deletion</button
				>
				<button class="danger" type="button" disabled={locked || !canDelete} onclick={remove}
					>Confirm delete</button
				>
			</div>
		</div>
	{/if}
	{#if $model.error}<p class="error" role="alert">{$model.error}</p>{/if}
	<p class="status" role="status">
		{$model.pending === 'choose'
			? 'Opening view…'
			: $model.pending === 'delete'
				? 'Deleting view…'
				: $model.pending
					? 'Saving view…'
					: ''}
	</p>
</div>

<style>
	.saved-views {
		position: relative;
		min-width: 0;
		color: var(--color-ink);
		font-size: 0.8125rem;
	}
	.fields {
		display: flex;
		flex-wrap: wrap;
		align-items: flex-end;
		gap: 0.75rem;
	}
	label {
		display: grid;
		gap: 0.375rem;
		min-width: 0;
		font-weight: 500;
	}
	.view,
	.name {
		flex: 1 1 12rem;
	}
	input,
	select {
		width: 100%;
		min-width: 0;
		min-height: 2.25rem;
		padding: 0.375rem 0.5rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
		font-weight: 400;
	}
	.actions {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
	}
	button {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 0.375rem;
		min-height: 2.25rem;
		padding: 0.375rem 0.625rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
		cursor: pointer;
	}
	button:not(:disabled):hover {
		background: var(--color-bone);
	}
	button:disabled,
	input:disabled,
	select:disabled {
		opacity: 0.5;
		cursor: default;
	}
	.modified {
		display: inline-block;
		margin-top: 0.5rem;
		padding: 0.125rem 0.5rem;
		border-radius: var(--radius-field);
		color: var(--color-accent);
		background: var(--color-accent-soft);
	}
	.hint,
	.error {
		margin: 0.5rem 0 0;
		overflow-wrap: anywhere;
		line-height: 1.5;
	}
	.hint {
		color: var(--color-muted);
	}
	.error,
	.danger {
		color: var(--color-violation);
	}
	.confirmation {
		margin-top: 0.75rem;
		padding: 0.75rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
	}
	.confirmation p {
		margin: 0 0 0.75rem;
		overflow-wrap: anywhere;
	}
	.status {
		position: absolute;
		width: 1px;
		height: 1px;
		padding: 0;
		overflow: hidden;
		clip-path: inset(50%);
		white-space: nowrap;
	}
</style>
