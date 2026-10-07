<script lang="ts">
	import type { Property, ViewPresentation } from 'life-ui-core/client';
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
	<label
		>Layout<select
			aria-label="View layout"
			{disabled}
			value={value.kind}
			onchange={(e) => kind(e.currentTarget.value as ViewPresentation['kind'])}
		>
			<option value="table">Table</option><option value="calendar" disabled={!dates.length}
				>Calendar</option
			>
			<option value="gallery">Gallery</option><option value="board" disabled={!groups.length}
				>Board</option
			>
		</select></label
	>
	{#if value.kind === 'calendar'}
		<label
			>Date<select
				aria-label="Calendar date property"
				{disabled}
				value={value.dateColumn}
				onchange={(e) => onchange({ ...value, dateColumn: e.currentTarget.value })}
				>{#each dates as p}<option value={p.col}>{label(p)}</option>{/each}</select
			></label
		>
		<label
			>End date<select
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
				<option value="">Single date</option>{#each dates as p}<option value={p.col}
						>{label(p)}</option
					>{/each}
			</select></label
		>
	{:else if value.kind === 'gallery'}
		<label
			>Cover<select
				aria-label="Gallery cover property"
				{disabled}
				value={value.coverColumn ?? ''}
				onchange={(e) => {
					const { coverColumn, ...rest } = value;
					onchange(e.currentTarget.value ? { ...rest, coverColumn: e.currentTarget.value } : rest);
				}}
			>
				<option value="">No cover</option>{#each covers as p}<option value={p.col}
						>{label(p)}</option
					>{/each}
			</select></label
		>
	{:else if value.kind === 'board'}
		<label
			>Group by<select
				aria-label="Board group property"
				{disabled}
				value={value.groupColumn}
				onchange={(e) => onchange({ ...value, groupColumn: e.currentTarget.value })}
				>{#each groups as p}<option value={p.col}>{label(p)}</option>{/each}</select
			></label
		>
	{/if}
</div>

<style>
	.controls {
		display: flex;
		gap: 12px;
		flex-wrap: wrap;
		margin: 12px 0;
	}
	label {
		display: grid;
		gap: 4px;
		font-size: 0.8rem;
	}
	select {
		min-width: 140px;
	}
</style>
