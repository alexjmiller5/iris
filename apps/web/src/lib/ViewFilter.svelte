<script lang="ts">
	import type { Filter, Property } from 'life-ui-core/client';
	import { parseFilter } from './view-controls';
	let {
		filter,
		properties,
		onchange,
		onremove
	}: {
		filter: Filter;
		properties: Property[];
		onchange: (filter: Filter) => void;
		onremove: () => void;
	} = $props();
	let error = $state('');
	const type = $derived(properties.find((p) => p.col === filter.column)?.type ?? 'text');
	const ops: Record<Filter['op'], string> = {
		eq: 'Is',
		ne: 'Is not',
		contains: 'Contains',
		gt: 'After / greater than',
		gte: 'On or after / at least',
		lt: 'Before / less than',
		lte: 'On or before / at most',
		empty: 'Is empty',
		not_empty: 'Is not empty'
	};
	function change(
		column = filter.column,
		op = filter.op,
		text = String(filter.value ?? ''),
		today = filter.relative === 'today'
	) {
		try {
			onchange(
				parseFilter(
					column,
					op,
					text,
					properties.find((p) => p.col === column)?.type ?? 'text',
					today
				)
			);
			error = '';
		} catch (e) {
			error = (e as Error).message;
		}
	}
</script>

<div class="rule">
	<select
		aria-label="Rule property"
		value={filter.column}
		onchange={(e) => change(e.currentTarget.value, 'eq', '', false)}
		>{#each properties as p}<option value={p.col}>{p.label || p.col}</option>{/each}</select
	>
	<select
		aria-label="Rule condition"
		value={filter.op}
		onchange={(e) => change(filter.column, e.currentTarget.value as Filter['op'])}
		>{#each Object.entries(ops) as [value, label]}<option {value}>{label}</option>{/each}</select
	>
	{#if !['empty', 'not_empty'].includes(filter.op)}
		{#if ['date', 'datetime'].includes(type)}<select
				aria-label="Date comparison"
				value={filter.relative ?? 'value'}
				onchange={(e) => change(filter.column, filter.op, '', e.currentTarget.value === 'today')}
				><option value="value">Exact value</option><option value="today">Today</option></select
			>{/if}
		{#if !filter.relative}
			{#if type === 'bool'}<select
					aria-label="Rule value"
					value={String(filter.value ?? '')}
					onchange={(e) => change(filter.column, filter.op, e.currentTarget.value)}
					><option value="">Choose value</option><option value="true">True</option><option
						value="false">False</option
					></select
				>
			{:else}<input
					aria-label="Rule value"
					value={String(filter.value ?? '')}
					onchange={(e) => change(filter.column, filter.op, e.currentTarget.value)}
				/>{/if}
		{/if}
	{/if}
	<button type="button" onclick={onremove}>Remove rule</button>
	{#if error}<p role="alert">{error}</p>{/if}
</div>

<style>
	.rule {
		display: flex;
		gap: 8px;
		flex-wrap: wrap;
		align-items: center;
	}
	.rule input {
		min-width: 80px;
		width: 160px;
	}
	select,
	input,
	button {
		font: inherit;
		font-size: 13px;
		padding: 6px;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
	}
	p {
		color: var(--color-violation);
	}
</style>
