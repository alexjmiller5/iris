<script lang="ts">
	import { onDestroy, onMount, tick } from 'svelte';
	import { focusReturn } from './popover';
	import { IconAlertTriangle, IconLoader2, IconSearch, IconX } from '@tabler/icons-svelte';
	import type { SearchHit } from 'life-ui-core/client';
	import { createSearchModel, type Search } from './search-dialog';
	import {
		entryKey,
		paletteEntries,
		selectEntry,
		type PaletteDestination,
		type PaletteEntry
	} from './command-palette';

	let {
		search,
		onchoose,
		onclose,
		incomplete,
		destinations = [],
		navigationLoading = false,
		navigationError = '',
		onnavigate = () => false
	}: {
		/** Return up to 50 hits at the supplied offset. */
		search: Search;
		/** Return false to keep the dialog open, for example after cancelled discard. */
		onchoose: (hit: SearchHit) => boolean | void | Promise<boolean | void>;
		onclose: () => void;
		incomplete: boolean;
		destinations?: PaletteDestination[];
		navigationLoading?: boolean;
		navigationError?: string;
		onnavigate?: (destination: PaletteDestination) => boolean | void | Promise<boolean | void>;
	} = $props();

	const id = $props.id();
	const model = createSearchModel((text, offset) => search(text, offset));
	let dialog: HTMLDialogElement;
	let input: HTMLInputElement;
	let opening = $state(false);
	let openError = $state('');
	let closed = false;
	let activeKey = $state<string | null>(null);
	const entries = $derived(paletteEntries($model.text, destinations, $model.hits));
	const groups = [
		{ kind: 'table', label: 'Tables' },
		{ kind: 'view', label: 'Saved views' },
		{ kind: 'record', label: 'Records' }
	] as const;
	$effect(() => {
		activeKey = selectEntry(entries, activeKey);
	});
	const optionId = (index: number) => `${id}-result-${index}`;
	const activeIndex = $derived(entries.findIndex((entry) => entryKey(entry) === activeKey));
	const activeId = $derived(activeIndex < 0 ? undefined : optionId(activeIndex));
	const status = $derived(
		opening
			? 'Opening…'
			: $model.loading
				? $model.hits.length
					? 'Loading more results…'
					: 'Searching…'
				: $model.error
					? 'Could not search records.'
					: entries.length
						? `${entries.length} ${entries.length === 1 ? 'result' : 'results'}`
						: $model.searched
							? 'No matches. Try different words.'
							: 'Find a table, saved view or record.'
	);

	function close() {
		if (closed) return;
		closed = true;
		model.dispose();
		dialog.close();
		onclose();
	}
	async function focusInput() {
		await tick();
		if (!closed && !opening) input.focus();
	}
	async function choose(entry: PaletteEntry) {
		if (closed || opening || ('unavailable' in entry && entry.unavailable)) return;
		opening = true;
		openError = '';
		try {
			const accepted = await (entry.kind === 'record' ? onchoose(entry) : onnavigate(entry));
			if (!closed && accepted !== false) close();
		} catch (error) {
			if (!closed)
				openError = error instanceof Error ? error.message : 'Could not open this result.';
		} finally {
			if (!closed) {
				opening = false;
				await focusInput();
			}
		}
	}
	async function keydown(event: KeyboardEvent) {
		if (event.isComposing || opening) return;
		if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
			event.preventDefault();
			activeKey = selectEntry(entries, activeKey, event.key === 'ArrowDown' ? 1 : -1);
			await tick();
			if (activeId) document.getElementById(activeId)?.scrollIntoView({ block: 'nearest' });
		} else if (event.key === 'Enter' && activeIndex >= 0) {
			event.preventDefault();
			void choose(entries[activeIndex]);
		}
	}
	onDestroy(focusReturn());
	onMount(() => {
		// showModal supplies the native focus trap and Escape; focusReturn hands focus
		// back because the host unmounts the dialog instead of closing it.
		dialog.showModal();
		input.focus();
		return () => {
			closed = true;
			model.dispose();
			if (dialog.open) dialog.close();
		};
	});
</script>

<dialog
	bind:this={dialog}
	aria-labelledby={`${id}-title`}
	onclose={close}
	oncancel={(event) => {
		event.preventDefault();
		close();
	}}
>
	<header>
		<h2 id={`${id}-title`}>Find records</h2>
		<button type="button" class="close" aria-label="Close search" onclick={close}>
			<IconX size={20} aria-hidden="true" />
		</button>
	</header>
	<div class="search-field">
		<IconSearch size={20} aria-hidden="true" />
		<input
			bind:this={input}
			role="combobox"
			aria-label="Search records"
			aria-autocomplete="list"
			aria-expanded={entries.length > 0}
			aria-controls={`${id}-results`}
			aria-activedescendant={activeId}
			aria-describedby={`${id}-help`}
			placeholder="Tables, saved views and records…"
			autocomplete="off"
			spellcheck="false"
			value={$model.text}
			disabled={opening}
			oninput={(event) => {
				openError = '';
				activeKey = null;
				model.setQuery(event.currentTarget.value);
			}}
			onkeydown={keydown}
		/>
	</div>
	{#if incomplete}
		<p class="incomplete">
			<IconAlertTriangle size={17} aria-hidden="true" />
			Results may be incomplete because some tables are skipped.
		</p>
	{/if}
	<p class="status" role="status">
		{#if $model.loading || opening}<span class="spinner"
				><IconLoader2 size={16} aria-hidden="true" /></span
			>{/if}
		{status}
	</p>
	{#if navigationLoading}<p class="status" role="status">Loading saved views…</p>{/if}
	{#if navigationError}<p class="failure" role="alert">
			Some saved views could not be loaded: {navigationError}
		</p>{/if}
	{#if $model.error}
		<div class="failure" role="alert">
			<p>{$model.error}</p>
			<button
				type="button"
				disabled={opening}
				onclick={async () => {
					await model.retry();
					await focusInput();
				}}>Retry search</button
			>
		</div>
	{/if}
	{#if openError}<p class="failure" role="alert">Could not open this result: {openError}</p>{/if}
	<div
		id={`${id}-results`}
		class="results"
		role="listbox"
		aria-label="Search results"
		aria-busy={$model.loading || navigationLoading}
	>
		{#each groups as group (group.kind)}
			{#if entries.some((entry) => entry.kind === group.kind)}
				<div role="group" aria-label={group.label}>
					<!-- The group carries the name; a listbox may only contain options. -->
					<div class="group-label" aria-hidden="true">{group.label}</div>
					{#each entries as entry, index (entryKey(entry))}
						{#if entry.kind === group.kind}
							<button
								type="button"
								role="option"
								id={optionId(index)}
								aria-selected={entryKey(entry) === activeKey}
								class="result"
								tabindex="-1"
								disabled={opening || !!('unavailable' in entry && entry.unavailable)}
								onclick={() => {
									activeKey = entryKey(entry);
									void choose(entry);
								}}
								onkeydown={keydown}
							>
								<span class="result-heading"
									><strong
										>{entry.label || (entry.kind === 'table' ? entry.table : entry.id)}</strong
									>{#if entry.kind === 'record' && entry.status}<span
											class="lifecycle"
											title={entry.status.d}>{entry.status.v}</span
										>{/if}{#if entry.kind !== 'table'}<span class="table">{entry.table}</span
										>{/if}</span
								>
								{#if entry.kind === 'record' && entry.excerpt}<span class="excerpt"
										>{entry.excerpt}</span
									>{/if}
								{#if 'unavailable' in entry && entry.unavailable}<span class="excerpt"
										>{entry.unavailable}</span
									>{/if}
							</button>
						{/if}
					{/each}
				</div>
			{/if}
		{/each}
	</div>
	{#if $model.hasMore}
		<button
			class="more"
			type="button"
			disabled={$model.loading || opening}
			onclick={async () => {
				await model.more();
				await focusInput();
			}}>More results</button
		>
	{/if}
	<p id={`${id}-help`} class="help">Use the arrow keys to move, Enter to open, or Esc to close.</p>
</dialog>

<style>
	dialog {
		width: min(680px, calc(100vw - 2rem));
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
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
		margin-bottom: 1rem;
	}
	h2 {
		margin: 0;
		font-size: 1.5rem;
		font-weight: 650;
	}
	.group-label {
		margin: 0.8rem 0.8rem 0.25rem;
		font-size: 0.75rem;
		font-weight: 600;
		color: var(--color-muted);
	}
	button {
		color: var(--color-ink);
		background: var(--color-paper);
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		padding: 0.5rem 0.75rem;
		min-height: 40px;
		cursor: pointer;
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	.close {
		display: grid;
		place-items: center;
		padding: 0.5rem;
	}
	.search-field {
		display: flex;
		align-items: center;
		gap: 0.7rem;
		padding: 0.7rem 0.8rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		color: var(--color-muted);
	}
	.search-field:focus-within {
		border-color: var(--color-accent);
		outline: 2px solid var(--color-accent);
		outline-offset: 2px;
	}
	input {
		width: 100%;
		min-width: 0;
		border: 0;
		outline: none;
		color: var(--color-ink);
		background: transparent;
		font-size: 1rem;
	}
	input::placeholder {
		color: var(--color-muted);
	}
	.status,
	.incomplete,
	.help {
		color: var(--color-muted);
		font-size: 0.85rem;
		line-height: 1.5;
	}
	.status,
	.incomplete {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		margin: 0.85rem 0;
	}
	.incomplete {
		align-items: start;
	}
	.incomplete :global(svg) {
		flex-shrink: 0;
		margin-top: 0.1rem;
	}
	.spinner {
		display: inline-flex;
		animation: spin 1s linear infinite;
	}
	@keyframes spin {
		to {
			transform: rotate(360deg);
		}
	}
	.results {
		display: grid;
		gap: 0.25rem;
		max-height: 50dvh;
		overflow-y: auto;
		padding: 0.2rem;
		margin: 0 -0.2rem;
	}
	.result {
		width: 100%;
		padding: 0.8rem;
		text-align: left;
		border-color: transparent;
	}
	.result:hover,
	.result[aria-selected='true'] {
		background: var(--color-accent-soft);
	}
	.result[aria-selected='true'] {
		border-color: var(--color-accent);
	}
	.result-heading {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 1rem;
	}
	strong {
		min-width: 0;
		font-weight: 600;
		overflow-wrap: anywhere;
	}
	.lifecycle {
		flex-shrink: 0;
		border: 1px solid var(--color-rule);
		border-radius: 999px;
		padding: 0 0.4rem;
		color: var(--color-muted);
		font-size: 0.75rem;
	}
	.table {
		flex-shrink: 0;
		max-width: 40%;
		color: var(--color-muted);
		font-size: 0.75rem;
		overflow-wrap: anywhere;
	}
	.excerpt {
		display: -webkit-box;
		-webkit-box-orient: vertical;
		-webkit-line-clamp: 2;
		line-clamp: 2;
		overflow: hidden;
		margin-top: 0.3rem;
		color: var(--color-muted);
		font-size: 0.85rem;
		line-height: 1.5;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
	}
	.failure {
		color: var(--color-violation);
		font-size: 0.9rem;
		overflow-wrap: anywhere;
	}
	.failure p {
		margin: 0.5rem 0;
	}
	.more {
		width: 100%;
		margin-top: 0.8rem;
	}
	.help {
		padding-top: 0.9rem;
		margin: 0.8rem 0 0;
		border-top: 1px solid var(--color-rule);
		font-size: 0.75rem;
	}
	@media (max-width: 540px) {
		dialog {
			padding: 1rem;
		}
	}
	@media (prefers-reduced-motion: reduce) {
		.spinner {
			animation: none;
		}
	}
</style>
