<script lang="ts">
	import { onDestroy, tick, type Snippet } from 'svelte';
	import {
		IconCopyPlus,
		IconDots,
		IconForms,
		IconLayoutList,
		IconTrash
	} from '@tabler/icons-svelte';
	import type { SavedViewRecord } from 'life-ui-core/client';
	import { createSavedViewsModel } from './saved-views';
	import { anchored } from './popover';

	// Key this component by table/workspace so even two empty lists have distinct lifetimes.
	let {
		list,
		unavailable,
		busy,
		selected = null,
		modified,
		onchoose,
		onsave,
		ondelete,
		children
	}: {
		list: SavedViewRecord[];
		unavailable: string | null;
		busy: boolean;
		selected?: string | null;
		/** Changes are waiting to be saved. */
		modified: boolean;
		onchoose: (id: string | null) => Promise<boolean | void>;
		/** update renames the selected view; otherwise a new view is created. */
		onsave: (name: string, update: boolean) => Promise<void>;
		ondelete: (id: string) => Promise<void>;
		/** More settings shown in the view menu. */
		children?: Snippet;
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
	let menuButton = $state<HTMLButtonElement>();
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
	<span class="select"
		><IconLayoutList size={16} aria-hidden="true" /><select
			bind:this={select}
			aria-label="View"
			value={selected ?? ''}
			disabled={locked}
			onchange={choose}
		>
			{#if !selected}<option value="">All records</option>{/if}
			{#if selected && !current}<option value={selected} disabled>Unavailable view</option>{/if}
			{#each list as view (view.id)}
				<option value={view.id} disabled={!!reason(view)}
					>{view.name}{reason(view) ? ` (${reason(view)})` : ''}</option
				>
			{/each}
		</select></span
	>
	<button
		bind:this={menuButton}
		type="button"
		class="menu-button"
		popovertarget={`${id}-menu`}
		aria-label="View settings"><IconDots size={16} aria-hidden="true" /></button
	>
	{#if modified}<span class="modified" aria-hidden="true">Saving…</span>{/if}
	<div
		id={`${id}-menu`}
		popover="auto"
		class="menu"
		role="dialog"
		aria-label="View settings"
		use:anchored={{ anchor: () => menuButton }}
	>
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
				disabled={locked || !canUpdate || !$model.name.trim() || $model.name.trim() === current?.name}
				onclick={() => save(true)}><IconForms size={16} aria-hidden="true" />Rename</button
			>
			<button
				type="button"
				disabled={locked || !!unavailable || !$model.name.trim()}
				onclick={() => save(false)}
			>
				<IconCopyPlus size={16} aria-hidden="true" />Save as new view
			</button>
			<button
				bind:this={deleteButton}
				type="button"
				disabled={locked || !canDelete}
				onclick={() => confirm(true)}
			>
				<IconTrash size={16} aria-hidden="true" />Delete view
			</button>
		</div>
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
		{@render children?.()}
	</div>
	{#if unavailable}<p class="hint">Saved views are unavailable. {unavailable}</p>{/if}
	{#if selected && !current}<p class="hint">
			This view is no longer available. Choose another saved view.
		</p>
	{:else if current && reason(current)}<p class="hint">{reason(current)}</p>{/if}
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
		display: inline-flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.25rem;
		min-width: 0;
		color: var(--color-ink);
		font-size: 0.8125rem;
	}
	.select {
		position: relative;
		display: inline-flex;
		align-items: center;
		min-width: 0;
	}
	.select :global(svg) {
		position: absolute;
		left: 0.5625rem;
		color: var(--color-muted);
		pointer-events: none;
	}
	.select select {
		max-width: 14rem;
		padding-left: 1.875rem;
		font-weight: 600;
		cursor: pointer;
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
	.menu-button {
		display: inline-grid;
		place-items: center;
		width: 2.25rem;
		height: 2.25rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		cursor: pointer;
	}
	.menu-button:hover {
		background: var(--color-bone);
	}
	.menu {
		position: fixed;
		inset: auto;
		margin: 0;
		width: min(28rem, calc(100vw - 1rem));
		overflow-y: auto;
		padding: 0.75rem;
		border: 1px solid var(--color-rule);
		border-radius: 0.5rem;
		background: var(--color-paper);
		color: var(--color-ink);
		box-shadow:
			0 12px 32px -12px rgb(21 24 28 / 0.28),
			0 2px 6px rgb(21 24 28 / 0.08);
		font-size: 0.8125rem;
	}
	.menu:popover-open {
		display: grid;
		gap: 0.75rem;
	}
	label {
		display: grid;
		gap: 0.375rem;
		min-width: 0;
		font-weight: 500;
	}
	.actions {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
	}
	.actions button {
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
	.actions button:not(:disabled):hover {
		background: var(--color-bone);
	}
	button:disabled,
	input:disabled,
	select:disabled {
		opacity: 0.5;
		cursor: default;
	}
	.modified {
		padding: 0 0.25rem;
		color: var(--color-muted);
		font-size: 0.75rem;
	}
	.hint,
	.error {
		flex-basis: 100%;
		margin: 0;
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
		padding: 0.75rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-bone);
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
