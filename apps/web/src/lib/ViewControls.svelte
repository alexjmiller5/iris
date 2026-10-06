<script lang="ts">
	import type {
		Property,
		Sort,
		FilterGroup,
		RowAction,
		ViewLayoutItem,
		Filter
	} from 'life-ui-core/client';
	import ViewFilter from './ViewFilter.svelte';
	import FieldEditor from './FieldEditor.svelte';
	import { editSort, parseDayStart } from './view-controls';
	import { cellPatch, rawValue } from './record-grid';
	let {
		properties,
		sorts,
		filters = [],
		groups,
		actions,
		layout,
		timeZone,
		dayStartMinutes = 0,
		columns,
		actionOptions = {},
		actionReferences = {},
		onactionsearch,
		disabled = false,
		onchange
	}: {
		properties: Property[];
		sorts: Sort[];
		filters?: Filter[];
		groups: FilterGroup[];
		actions: RowAction[];
		layout?: ViewLayoutItem[];
		timeZone: string;
		dayStartMinutes?: number;
		columns: string[];
		actionOptions?: Record<string, string[]>;
		actionReferences?: Record<string, { id: string; label: string }[]>;
		onactionsearch?: (action: RowAction, property: Property, query: string) => void;
		disabled?: boolean;
		onchange: (patch: {
			sorts?: Sort[];
			groups?: FilterGroup[];
			filters?: Filter[];
			actions?: RowAction[];
			layout?: ViewLayoutItem[];
			timeZone?: string;
			dayStartMinutes?: number;
		}) => void;
	} = $props();
	let error = $state('');
	const writable = $derived(
		properties.filter(
			(p) =>
				!['id', 'created_at', 'updated_at', 'hub_at', 'deleted_at'].includes(p.col) &&
				!p.derived_by &&
				!p.immutable &&
				!p.deprecated
		)
	);
	const items = $derived(
		layout ?? [
			...columns.map((id) => ({ kind: 'column' as const, id })),
			...actions.map((a) => ({ kind: 'action' as const, id: a.id }))
		]
	);
	const label = (id: string) => properties.find((p) => p.col === id)?.label || id;
	function move<T>(list: T[], index: number, delta: number): T[] {
		const next = [...list];
		[next[index], next[index + delta]] = [next[index + delta], next[index]];
		return next;
	}
	function group(index: number, patch: Partial<FilterGroup>) {
		onchange({ groups: groups.map((g, i) => (i === index ? { ...g, ...patch } : g)) });
	}
	function action(index: number, patch: Partial<RowAction>) {
		onchange({ actions: actions.map((a, i) => (i === index ? { ...a, ...patch } : a)) });
	}
	function actionValue(index: number, p: Property, raw: string) {
		try {
			const patch = cellPatch(p, { cell: { rowId: 'unused', column: p.col }, baseline: {}, raw });
			delete patch.id;
			action(index, { values: { ...actions[index].values, ...patch } });
			error = '';
		} catch (e) {
			error = (e as Error).message;
		}
	}
	function newRule() {
		return { column: properties[0]?.col ?? 'id', op: 'empty' as const };
	}
</script>

<fieldset {disabled} class="view-controls">
	<legend>View options</legend>
	<details>
		<summary>Sort order ({sorts.length})</summary>
		<div class="sorts" aria-label="Sort order">
			{#each sorts as sort, index}
				<div class="line">
					<select
						aria-label={index === 0 ? 'Sort by' : `Sort by ${index + 1}`}
						value={sort.column}
						onchange={(e) =>
							onchange({
								sorts: editSort(sorts, index, { column: e.currentTarget.value, mode: undefined })
							})}
						>{#each properties as p}<option value={p.col}>Sort by {p.label || p.col}</option
							>{/each}</select
					>
					<button
						type="button"
						onclick={() =>
							onchange({
								sorts: editSort(sorts, index, {
									direction: sort.direction === 'asc' ? 'desc' : 'asc'
								})
							})}>{sort.direction === 'asc' ? 'Ascending' : 'Descending'}</button
					>
					{#if ['select', 'multi_select'].includes(properties.find((p) => p.col === sort.column)?.type ?? '')}<select
							aria-label={`Sort comparison ${index + 1}`}
							value={sort.mode ?? 'value'}
							onchange={(e) =>
								onchange({
									sorts: editSort(sorts, index, { mode: e.currentTarget.value as Sort['mode'] })
								})}
							><option value="value">Value order</option><option value="options"
								>Option order</option
							></select
						>{/if}
					<button
						type="button"
						aria-label={`Move sort ${index + 1} up`}
						disabled={index === 0}
						onclick={() => onchange({ sorts: move(sorts, index, -1) })}>Move up</button
					>
					<button
						type="button"
						aria-label={`Remove sort ${index + 1}`}
						onclick={() => onchange({ sorts: sorts.filter((_, i) => i !== index) })}>Remove</button
					>
				</div>
			{/each}
			<button
				type="button"
				disabled={sorts.length >= 16}
				onclick={() =>
					onchange({
						sorts: [
							...sorts,
							{
								column: properties.find((p) => !sorts.some((s) => s.column === p.col))?.col ?? 'id',
								direction: 'asc'
							}
						]
					})}>Add sort</button
			>
		</div>
	</details>
	<details>
		<summary>Filter groups{groups.length ? ` (${groups.length})` : ''}</summary>
		<p>Match every group, together with the individual filters below.</p>
		{#if filters.length}<fieldset>
				<legend>Match all individual filters</legend>{#each filters as filter, index}<ViewFilter
						{filter}
						{properties}
						onchange={(f) => onchange({ filters: filters.map((v, i) => (i === index ? f : v)) })}
						onremove={() => onchange({ filters: filters.filter((_, i) => i !== index) })}
					/>{/each}
			</fieldset>{/if}
		{#each groups as g, index}
			<fieldset>
				<legend>Group {index + 1}</legend>
				<select
					aria-label={`Group ${index + 1} match`}
					value={g.match}
					onchange={(e) => group(index, { match: e.currentTarget.value as FilterGroup['match'] })}
					><option value="all">Match all</option><option value="any">Match any</option></select
				>
				{#each g.filters as filter, rule}<ViewFilter
						{filter}
						{properties}
						onchange={(f) =>
							group(index, { filters: g.filters.map((v, i) => (i === rule ? f : v)) })}
						onremove={() => group(index, { filters: g.filters.filter((_, i) => i !== rule) })}
					/>{/each}
				<button
					type="button"
					disabled={g.filters.length >= 64}
					onclick={() => group(index, { filters: [...g.filters, newRule()] })}>Add rule</button
				>
				<button
					type="button"
					onclick={() => onchange({ groups: groups.filter((_, i) => i !== index) })}
					>Remove group</button
				>
			</fieldset>
		{/each}
		<button
			type="button"
			disabled={groups.length >= 16}
			onclick={() => onchange({ groups: [...groups, { match: 'any', filters: [newRule()] }] })}
			>Add filter group</button
		>
		<label
			>Today timezone <input
				aria-label="Today timezone"
				value={timeZone}
				placeholder="Area/City"
				onchange={(e) => onchange({ timeZone: e.currentTarget.value })}
			/></label
		>
		<label
			>Day starts at <input
				type="time"
				aria-label="Day starts at"
				value={`${String(Math.floor(dayStartMinutes / 60)).padStart(2, '0')}:${String(dayStartMinutes % 60).padStart(2, '0')}`}
				onchange={(e) => {
					try {
						onchange({ dayStartMinutes: parseDayStart(e.currentTarget.value) });
						error = '';
					} catch (e) {
						error = (e as Error).message;
					}
				}}
			/></label
		>
		<p>Today starts at this time in the selected timezone.</p>
	</details>
	<details>
		<summary>Row actions{actions.length ? ` (${actions.length})` : ''}</summary>
		<p>Save the view to use these buttons. Each button applies its saved values to one record.</p>
		{#each actions as a, index (a.id)}
			<fieldset>
				<legend>Action {index + 1}</legend>
				<label
					>Button label <input
						value={a.label}
						onchange={(e) => action(index, { label: e.currentTarget.value })}
					/></label
				>
				{#each Object.entries(a.values) as [col, value]}
					{@const p = writable.find((p) => p.col === col)}
					{#if p}<label for={`action-${a.id}-${col}`}>{label(col)}</label><FieldEditor
							id={`action-${a.id}-${col}`}
							property={p}
							value={rawValue(value)}
							options={actionOptions[p.col] ?? []}
							references={actionReferences[JSON.stringify([a.id, p.col])] ?? []}
							onsearch={(query) => onactionsearch?.(a, p, query)}
							onchange={(raw) => actionValue(index, p, raw)}
						/>{:else}<p role="alert">Unavailable property: {col}</p>{/if}
					<button
						type="button"
						onclick={() => {
							const values = { ...a.values };
							delete values[col];
							action(index, { values });
						}}>Remove value</button
					>
				{/each}
				<select
					aria-label={`Add value to action ${index + 1}`}
					value=""
					onchange={(e) => {
						if (e.currentTarget.value)
							action(index, { values: { ...a.values, [e.currentTarget.value]: null } });
						e.currentTarget.value = '';
					}}
					><option value="">Add property value</option
					>{#each writable.filter((p) => !Object.hasOwn(a.values, p.col)) as p}<option value={p.col}
							>{p.label || p.col}</option
						>{/each}</select
				>
				<button
					type="button"
					onclick={() =>
						onchange({
							actions: actions.filter((_, i) => i !== index),
							layout: items.filter((item) => item.kind !== 'action' || item.id !== a.id)
						})}>Remove action</button
				>
			</fieldset>
		{/each}
		<button
			type="button"
			disabled={actions.length >= 32 || !writable.length}
			onclick={() => {
				const id = crypto.randomUUID();
				onchange({
					actions: [...actions, { id, label: 'New action', values: { [writable[0].col]: null } }],
					layout: [...items, { kind: 'action', id }]
				});
			}}>Add action</button
		>
		{#if actions.length}<fieldset>
				<legend>Column and button order</legend>{#each items as item, index}<div class="line">
						<span
							>{item.kind === 'action'
								? actions.find((a) => a.id === item.id)?.label
								: label(item.id)}</span
						><button
							type="button"
							disabled={index === 0}
							aria-label={`Move ${item.kind} ${item.id} up`}
							onclick={() => onchange({ layout: move(items, index, -1) })}>Move up</button
						><button
							type="button"
							disabled={index === items.length - 1}
							aria-label={`Move ${item.kind} ${item.id} down`}
							onclick={() => onchange({ layout: move(items, index, 1) })}>Move down</button
						>
					</div>{/each}
			</fieldset>{/if}
	</details>
	{#if error}<p role="alert">{error}</p>{/if}
</fieldset>

<style>
	.view-controls {
		border: 0;
		padding: 0;
		margin: 12px 0;
		min-width: 0;
	}
	legend {
		font-size: 12px;
		color: var(--color-muted);
	}
	.line {
		display: flex;
		gap: 8px;
		flex-wrap: wrap;
		align-items: center;
		margin: 6px 0;
	}
	.sorts {
		display: grid;
		gap: 6px;
		justify-items: start;
	}
	details {
		border: 1px solid var(--color-rule);
		border-radius: 6px;
		margin-top: 8px;
		padding: 10px;
	}
	summary {
		cursor: pointer;
		font-size: 13px;
	}
	fieldset fieldset {
		border: 1px solid var(--color-rule);
		padding: 10px;
		margin: 10px 0;
		display: grid;
		gap: 8px;
		min-width: 0;
	}
	label {
		display: flex;
		gap: 8px;
		align-items: center;
	}
	input,
	select,
	button {
		font: inherit;
		font-size: 13px;
		padding: 6px 8px;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		max-width: 100%;
	}
	button {
		cursor: pointer;
	}
	button:disabled {
		opacity: 0.45;
		cursor: default;
	}
	p {
		font-size: 12px;
		color: var(--color-muted);
	}
	[role='alert'] {
		color: var(--color-violation);
	}
</style>
