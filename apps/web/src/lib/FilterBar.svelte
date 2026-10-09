<script lang="ts">
	import { tick, type Snippet } from 'svelte';
	import type { Filter, FilterGroup, Property } from 'iris-core/client';
	import { IconFilter, IconPlus, IconStack2, IconTrash, IconX } from '@tabler/icons-svelte';
	import ViewFilter from './ViewFilter.svelte';
	import { anchored } from './popover';
	import { propertyIcon } from './property-icons';
	import {
		chipsOf,
		defaultRule,
		describeRule,
		groupDraft,
		placeGroup,
		placeRule,
		removeChip,
		type ChipRef,
		type FilterState,
		type GroupDraft,
		type Rule
	} from './filter-bar';

	// Notion-style filters: chips apply as you edit them. The parent applies each
	// change to the query and saves the view after the popover closes.
	let {
		filters,
		groups,
		properties,
		disabled = false,
		options = {},
		references = () => [],
		onsearch,
		onchange,
		ontoggle,
		leading
	}: {
		filters: Filter[];
		groups: FilterGroup[];
		properties: Property[];
		disabled?: boolean;
		options?: Record<string, string[]>;
		references?: (p: Property) => { id: string; label: string }[];
		onsearch?: (p: Property, query: string) => void;
		/** Returns false when the change was refused (e.g. an unsaved record). */
		onchange: (next: FilterState) => boolean;
		ontoggle?: (open: boolean) => void;
		/** Chips shown before the filter chips (the sort summary). */
		leading?: Snippet;
	} = $props();
	const id = $props.id();
	const current = $derived({ filters, groups });
	const chips = $derived(chipsOf(current));
	const typeOf = (column: string) => properties.find((p) => p.col === column)?.type ?? 'text';
	const label = (column: string) => {
		const p = properties.find((p) => p.col === column);
		return p?.label || column;
	};
	const count = $derived(filters.length + groups.length);

	let addButton = $state<HTMLButtonElement>(),
		addAnchor = $state<HTMLElement>(),
		addPopover = $state<HTMLElement>(),
		editPopover = $state<HTMLElement>(),
		row = $state<HTMLElement>(),
		search = $state<HTMLInputElement>();
	let query = $state('');
	const matches = $derived(
		properties.filter((p) => {
			const q = query.trim().toLowerCase();
			return !q || label(p.col).toLowerCase().includes(q) || p.col.toLowerCase().includes(q);
		})
	);
	/** The chip whose editor is open; ref is null until its rule is complete. */
	let rule = $state<{ ref: ChipRef | null; value: Rule; error: string } | null>(null);
	let group = $state<{ ref: ChipRef | null; draft: GroupDraft } | null>(null);
	let editAnchor = $state<HTMLElement>();
	let reopening: ChipRef | null = null;
	const same = (a: ChipRef | null | undefined, b: ChipRef | null | undefined) =>
		!!a && !!b && a.kind === b.kind && a.index === b.index;
	const editing = (ref: ChipRef) => same(rule?.ref, ref) || same(group?.ref, ref);

	function apply(next: FilterState) {
		return onchange(next);
	}
	function editRule(value: Rule) {
		if (!rule) return;
		const placed = placeRule(current, rule.ref, value, typeOf);
		if (placed.state !== current && !apply(placed.state)) return;
		rule = { ref: placed.ref, value, error: placed.error };
	}
	function editGroup(draft: GroupDraft) {
		if (!group) return;
		const placed = placeGroup(current, group.ref, draft, typeOf);
		if (placed.state !== current && !apply(placed.state)) return;
		group = { ref: placed.ref, draft };
	}
	async function openEditor() {
		await tick();
		editAnchor = row?.querySelector<HTMLElement>('[data-editing] .chip-main') ?? addButton;
		editPopover?.showPopover();
		await tick();
		(
			editPopover?.querySelector<HTMLElement>(
				'input[type=text], input[type=number], input[type=search], input[type=date], input[type=datetime-local]'
			) ?? editPopover?.querySelector<HTMLElement>('input, select')
		)?.focus();
	}
	function openChip(ref: ChipRef, value: Rule | null) {
		if (disabled) return;
		if (reopening && same(reopening, ref)) {
			// The press that light-dismissed this chip's editor only closes it.
			reopening = null;
			return;
		}
		if (value) {
			rule = { ref, value: { ...value, values: [...value.values] }, error: '' };
			group = null;
		} else {
			group = { ref, draft: groupDraft(groups[ref.index]) };
			rule = null;
		}
		void openEditor();
	}
	function add(p: Property) {
		addPopover?.hidePopover();
		query = '';
		rule = { ref: null, value: defaultRule(p.col, p.type ?? 'text'), error: '' };
		group = null;
		editRule(rule.value);
		void openEditor();
	}
	function addGroup() {
		addPopover?.hidePopover();
		query = '';
		const first = properties[0];
		if (!first) return;
		rule = null;
		group = {
			ref: null,
			draft: { match: 'all', rules: [defaultRule(first.col, first.type ?? 'text')] }
		};
		editGroup(group.draft);
		void openEditor();
	}
	function remove(ref: ChipRef) {
		if (disabled || !apply(removeChip(current, ref))) return;
		if (editing(ref)) editPopover?.hidePopover();
		rule = null;
		group = null;
	}
	function removeEditing() {
		const ref = rule?.ref ?? group?.ref;
		editPopover?.hidePopover();
		if (ref) remove(ref);
	}
	function closed() {
		// An unfinished chip has nothing to save; it disappears with its editor,
		// and focus it held goes back to Filter.
		const unfinished = (rule && !rule.ref) || (group && !group.ref);
		rule = null;
		group = null;
		if (unfinished)
			void tick().then(() => {
				if (!document.activeElement || document.activeElement === document.body) addButton?.focus();
			});
	}
</script>

<button
	bind:this={addButton}
	type="button"
	class="tool"
	class:active={count > 0}
	popovertarget={`${id}-add`}
	{disabled}
	onclick={() => (addAnchor = addButton)}
	><IconFilter size={16} aria-hidden="true" />Filter{#if count}
		<span class="count">{count}</span><span class="sr-only"> active</span>{/if}</button
>

{#if count || leading || rule || group}
	<div class="chips" bind:this={row} role="group" aria-label="Sort and filters">
		{@render leading?.()}
		{#each chips as chip (`${chip.ref.kind}:${chip.ref.index}`)}
			{@const shown = editing(chip.ref) && rule ? rule.value : chip.rule}
			{@const text = shown
				? describeRule(shown, typeOf(shown.column), label)
				: `${groups[chip.ref.index].match === 'any' ? 'Any' : 'All'} of ${groups[chip.ref.index].filters.length} rules`}
			{@const Icon = shown ? propertyIcon(typeOf(shown.column)) : IconStack2}
			<span class="chip" data-editing={editing(chip.ref) || undefined}>
				<button
					type="button"
					class="chip-main"
					{disabled}
					aria-haspopup="dialog"
					aria-expanded={editing(chip.ref)}
					onpointerdown={() => (reopening = editing(chip.ref) ? chip.ref : null)}
					onclick={() => openChip(chip.ref, chip.rule)}
					><Icon size={14} aria-hidden="true" /><span>{text}</span></button
				><button
					type="button"
					class="chip-x"
					{disabled}
					aria-label={`Remove filter: ${text}`}
					onclick={() => remove(chip.ref)}><IconX size={14} aria-hidden="true" /></button
				>
			</span>
		{/each}
		{#if rule && !rule.ref}
			{@const Icon = propertyIcon(typeOf(rule.value.column))}
			<span class="chip draft" data-editing>
				<button type="button" class="chip-main" aria-haspopup="dialog" aria-expanded="true"
					><Icon size={14} aria-hidden="true" /><span
						>{describeRule(rule.value, typeOf(rule.value.column), label)}</span
					></button
				>
			</span>
		{:else if group && !group.ref}
			<span class="chip draft" data-editing>
				<button type="button" class="chip-main" aria-haspopup="dialog" aria-expanded="true"
					><IconStack2 size={14} aria-hidden="true" /><span>New group</span></button
				>
			</span>
		{/if}
		{#if count}
			<button
				type="button"
				class="add"
				popovertarget={`${id}-add`}
				{disabled}
				onclick={(e) => (addAnchor = e.currentTarget)}
				><IconPlus size={14} aria-hidden="true" />Add filter</button
			>
		{/if}
	</div>
{/if}

<div
	id={`${id}-add`}
	popover="auto"
	class="popover picker"
	bind:this={addPopover}
	use:anchored={{
		anchor: () => addAnchor ?? addButton,
		ontoggle: (open) => {
			if (open) search?.focus();
			else query = '';
		}
	}}
>
	<input
		bind:this={search}
		type="search"
		aria-label="Filter by property"
		placeholder="Filter by…"
		bind:value={query}
		onkeydown={(e) => {
			if (e.key === 'Enter' && matches[0]) {
				e.preventDefault();
				add(matches[0]);
			}
		}}
	/>
	<div class="list" role="group" aria-label="Properties">
		{#each matches as p (p.col)}
			{@const Icon = propertyIcon(p.type)}
			<button type="button" class="item" onclick={() => add(p)}
				><Icon size={16} aria-hidden="true" /><span>{label(p.col)}</span></button
			>
		{:else}
			<p class="hint">No matching properties</p>
		{/each}
	</div>
	<hr />
	<button type="button" class="item" disabled={!properties.length} onclick={addGroup}
		><IconStack2 size={16} aria-hidden="true" /><span>Add filter group</span></button
	>
</div>

<div
	popover="auto"
	class="popover editor"
	role="dialog"
	aria-label="Edit filter"
	bind:this={editPopover}
	use:anchored={{
		// The edited chip re-renders once its rule completes; find the live one.
		anchor: () => row?.querySelector<HTMLElement>('[data-editing] .chip-main') ?? editAnchor,
		ontoggle: (open) => {
			ontoggle?.(open);
			if (!open) closed();
		}
	}}
>
	{#if rule}
		{@const Icon = propertyIcon(typeOf(rule.value.column))}
		<div class="head">
			<span class="title"><Icon size={16} aria-hidden="true" />{label(rule.value.column)}</span>
			<button type="button" class="icon" aria-label="Remove filter" onclick={removeEditing}
				><IconTrash size={16} aria-hidden="true" /></button
			>
		</div>
		<ViewFilter
			rule={rule.value}
			{properties}
			error={rule.error}
			{options}
			{references}
			{onsearch}
			onchange={editRule}
		/>
	{:else if group}
		{@const draft = group.draft}
		<div class="head">
			<label class="match"
				>Match <select
					aria-label="Group match"
					value={draft.match}
					onchange={(e) =>
						editGroup({ ...draft, match: e.currentTarget.value as GroupDraft['match'] })}
					><option value="all">all</option><option value="any">any</option></select
				> of these rules</label
			>
			<button type="button" class="icon" aria-label="Remove group" onclick={removeEditing}
				><IconTrash size={16} aria-hidden="true" /></button
			>
		</div>
		<ol class="rules">
			{#each draft.rules as item, index (index)}
				<li>
					<ViewFilter
						rule={item}
						{properties}
						pick
						single
						{options}
						{references}
						{onsearch}
						onchange={(value) =>
							editGroup({ ...draft, rules: draft.rules.map((r, i) => (i === index ? value : r)) })}
						onremove={() =>
							editGroup({ ...draft, rules: draft.rules.filter((_, i) => i !== index) })}
					/>
				</li>
			{/each}
		</ol>
		<button
			type="button"
			class="item"
			disabled={draft.rules.length >= 64 || !properties.length}
			onclick={() =>
				editGroup({
					...draft,
					rules: [...draft.rules, defaultRule(properties[0].col, properties[0].type ?? 'text')]
				})}><IconPlus size={16} aria-hidden="true" /><span>Add rule</span></button
		>
		<p class="hint">Rules without a value are not applied.</p>
	{/if}
</div>

<style>
	.tool {
		display: inline-flex;
		align-items: center;
		gap: 0.375rem;
		min-height: 2.25rem;
		padding: 0 0.625rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
		font-size: 0.8125rem;
		cursor: pointer;
	}
	.tool:hover:not(:disabled) {
		background: var(--color-bone);
	}
	.tool.active,
	.tool.active:hover:not(:disabled) {
		border-color: var(--color-accent);
		background: var(--color-accent);
		color: var(--color-on-accent);
	}
	.tool.active:hover:not(:disabled) {
		background: color-mix(in srgb, var(--color-accent) 86%, var(--color-ink));
	}
	.tool:disabled {
		opacity: 0.5;
		cursor: default;
	}
	.count {
		min-width: 1.125rem;
		padding: 0 0.3125rem;
		border-radius: 999px;
		background: color-mix(in srgb, var(--color-on-accent) 22%, transparent);
		font-size: 0.6875rem;
		font-weight: 600;
		line-height: 1.125rem;
		text-align: center;
	}
	.chips {
		order: 1;
		flex: 1 0 calc(100% + 8px);
		display: flex;
		gap: 0.375rem;
		align-items: center;
		min-width: 0;
		overflow-x: auto;
		scrollbar-width: thin;
		/* Room for focus rings inside the scroller without shifting the row. */
		margin: -4px -4px -10px;
		padding: 4px 4px 10px;
	}
	.chip-main:focus-visible,
	.chip-x:focus-visible {
		outline-offset: -2px;
	}
	.chip {
		display: inline-flex;
		flex: none;
		align-items: stretch;
		border: 1px solid color-mix(in srgb, var(--color-accent) 35%, var(--color-rule));
		border-radius: 999px;
		background: var(--color-accent-soft);
		color: var(--color-ink);
		font-size: 0.8125rem;
	}
	.chip[data-editing] {
		border-color: var(--color-accent);
	}
	.chip.draft {
		border-style: dashed;
		background: var(--color-paper);
	}
	.chip-main,
	.chip-x {
		display: inline-flex;
		align-items: center;
		gap: 0.3125rem;
		min-height: 1.875rem;
		border: 0;
		background: transparent;
		color: inherit;
		font: inherit;
		cursor: pointer;
	}
	.chip-main {
		padding: 0 0.375rem 0 0.625rem;
		max-width: 18rem;
		border-radius: 999px 0 0 999px;
	}
	.chip.draft .chip-main {
		padding-right: 0.625rem;
		border-radius: 999px;
	}
	.chip-main span {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.chip-x {
		padding: 0 0.5rem 0 0.25rem;
		border-radius: 0 999px 999px 0;
		color: var(--color-muted);
	}
	.chip-x:hover {
		color: var(--color-ink);
	}
	.chips > :global(button),
	.add {
		flex: none;
	}
	.add {
		display: inline-flex;
		align-items: center;
		gap: 0.25rem;
		min-height: 1.875rem;
		padding: 0 0.5rem;
		border: 0;
		border-radius: var(--radius-field);
		background: transparent;
		color: var(--color-muted);
		font: inherit;
		font-size: 0.8125rem;
		cursor: pointer;
	}
	.add:hover {
		background: var(--color-paper);
		color: var(--color-ink);
	}
	.popover {
		position: fixed;
		inset: auto;
		margin: 0;
		width: min(20rem, calc(100vw - 1rem));
		max-width: calc(100vw - 1rem);
		overflow-y: auto;
		padding: 0.5rem;
		border: 1px solid var(--color-rule);
		border-radius: 0.5rem;
		background: var(--color-paper);
		color: var(--color-ink);
		box-shadow:
			0 12px 32px -12px rgb(21 24 28 / 0.28),
			0 2px 6px rgb(21 24 28 / 0.08);
		font-size: 0.8125rem;
	}
	.editor {
		width: min(22rem, calc(100vw - 1rem));
		display: grid;
		gap: 0.625rem;
		padding: 0.75rem;
	}
	.editor:not(:popover-open) {
		display: none;
	}
	.picker input {
		width: 100%;
		min-height: 2.25rem;
		margin-bottom: 0.375rem;
		padding: 0.375rem 0.5rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
	}
	.list {
		display: grid;
	}
	.item {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		width: 100%;
		min-height: 2.25rem;
		padding: 0 0.5rem;
		border: 0;
		border-radius: var(--radius-field);
		background: transparent;
		color: var(--color-ink);
		font: inherit;
		text-align: left;
		cursor: pointer;
	}
	.item :global(svg) {
		flex: none;
		color: var(--color-muted);
	}
	.item:hover:not(:disabled),
	.item:focus-visible {
		background: var(--color-bone);
	}
	.item:disabled {
		opacity: 0.5;
		cursor: default;
	}
	hr {
		margin: 0.375rem 0;
		border: 0;
		border-top: 1px solid var(--color-rule);
	}
	.head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 0.5rem;
	}
	.title {
		display: inline-flex;
		align-items: center;
		gap: 0.375rem;
		font-weight: 600;
		min-width: 0;
		overflow-wrap: anywhere;
	}
	.title :global(svg) {
		color: var(--color-muted);
		flex: none;
	}
	.match {
		display: flex;
		align-items: center;
		gap: 0.375rem;
		flex-wrap: wrap;
	}
	.match select {
		min-height: 2rem;
		padding: 0.25rem 0.375rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
	}
	.icon {
		display: inline-grid;
		place-items: center;
		flex: none;
		width: 2rem;
		height: 2rem;
		border: 0;
		border-radius: var(--radius-field);
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}
	.icon:hover {
		background: var(--color-bone);
		color: var(--color-violation);
	}
	.rules {
		display: grid;
		gap: 0.75rem;
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.rules li + li {
		padding-top: 0.75rem;
		border-top: 1px solid var(--color-rule);
	}
	.hint {
		margin: 0;
		padding: 0.25rem 0.5rem;
		color: var(--color-muted);
		font-size: 0.75rem;
	}
</style>
