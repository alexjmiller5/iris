<script lang="ts">
	import type { Property, ViewPresentation } from 'iris-core/client';
	import {
		IconCalendar,
		IconCalendarDue,
		IconCalendarMonth,
		IconLayoutColumns,
		IconLayoutGrid,
		IconPhoto,
		IconTable
	} from '@tabler/icons-svelte';
	let {
		value,
		properties,
		disabled = false,
		onchange
	}: {
		value: ViewPresentation;
		properties: Property[];
		disabled?: boolean;
		onchange: (value: ViewPresentation) => void;
	} = $props();
	const dates = $derived(
		properties.filter(
			(p) => ['date', 'datetime', 'date_or_datetime'].includes(p.type ?? '') && !p.deprecated
		)
	);
	const covers = $derived(
		properties.filter((p) => ['text', 'url', 'json'].includes(p.type ?? '') && !p.deprecated)
	);
	const groups = $derived(properties.filter((p) => p.type === 'select' && !p.deprecated));
	const label = (p: Property) => p.label || p.col;
	const LayoutIcon = $derived(
		{
			table: IconTable,
			calendar: IconCalendarMonth,
			gallery: IconLayoutGrid,
			board: IconLayoutColumns
		}[value.kind]
	);
	function kind(kind: ViewPresentation['kind']) {
		onchange(
			kind === 'calendar'
				? { kind, dateColumn: dates[0]?.col }
				: kind === 'board'
					? { kind, groupColumn: groups[0]?.col }
					: { kind }
		);
	}
</script>

<div class="controls">
	<span class="select"
		><LayoutIcon size={16} aria-hidden="true" /><select
			aria-label="View layout"
			{disabled}
			value={value.kind}
			onchange={(e) => kind(e.currentTarget.value as ViewPresentation['kind'])}
		>
			<option value="table">Table</option>
			<option value="calendar" disabled={!dates.length}>Calendar</option>
			<option value="gallery">Gallery</option>
			<option value="board" disabled={!groups.length}>Board</option>
		</select></span
	>
	{#if value.kind === 'calendar'}
		<span class="select"
			><IconCalendar size={16} aria-hidden="true" /><select
				aria-label="Calendar date property"
				{disabled}
				value={value.dateColumn}
				onchange={(e) => onchange({ ...value, dateColumn: e.currentTarget.value })}
				>{#each dates as p}<option value={p.col}>{label(p)}</option>{/each}</select
			></span
		>
		<span class="select"
			><IconCalendarDue size={16} aria-hidden="true" /><select
				aria-label="Calendar end date property"
				{disabled}
				value={value.endDateColumn ?? ''}
				onchange={(e) => {
					const { endDateColumn, ...rest } = value;
					onchange(
						e.currentTarget.value ? { ...rest, endDateColumn: e.currentTarget.value } : rest
					);
				}}
			>
				<option value="">No end date</option>{#each dates as p}<option value={p.col}
						>Ends {label(p)}</option
					>{/each}
			</select></span
		>
	{:else if value.kind === 'gallery'}
		<span class="select"
			><IconPhoto size={16} aria-hidden="true" /><select
				aria-label="Gallery cover property"
				{disabled}
				value={value.coverColumn ?? ''}
				onchange={(e) => {
					const { coverColumn, ...rest } = value;
					onchange(e.currentTarget.value ? { ...rest, coverColumn: e.currentTarget.value } : rest);
				}}
			>
				<option value="">No cover</option>{#each covers as p}<option value={p.col}
						>Cover: {label(p)}</option
					>{/each}
			</select></span
		>
	{:else if value.kind === 'board'}
		<span class="select"
			><IconLayoutColumns size={16} aria-hidden="true" /><select
				aria-label="Board group property"
				{disabled}
				value={value.groupColumn}
				onchange={(e) => onchange({ ...value, groupColumn: e.currentTarget.value })}
				>{#each groups as p}<option value={p.col}>Group by {label(p)}</option>{/each}</select
			></span
		>
	{/if}
</div>

<style>
	.controls {
		display: contents;
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
	select {
		min-height: 2.25rem;
		max-width: 12rem;
		padding: 0 0.5rem 0 1.875rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
		font-size: 0.8125rem;
		cursor: pointer;
	}
	select:disabled {
		opacity: 0.5;
		cursor: default;
	}
</style>
