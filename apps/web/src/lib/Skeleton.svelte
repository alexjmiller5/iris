<script lang="ts">
	import { barWidth } from './skeleton';
	let {
		shape = 'lines',
		rows = 3,
		columns = [],
		label = 'Loading',
		announce = true
	}: {
		/** lines: text; list: list rows; grid: table rows; record: label/value property rows;
		 *  pill: one inline label; block: an image or preview area. */
		shape?: 'lines' | 'list' | 'grid' | 'record' | 'pill' | 'block';
		rows?: number;
		/** Grid column widths in pixels. */
		columns?: number[];
		/** Read by assistive technology in place of the bars. */
		label?: string;
		/** False when a nearby status line already announces the wait. */
		announce?: boolean;
	} = $props();
	const indexes = $derived(Array.from({ length: shape === 'block' ? 1 : rows }, (_, i) => i));
</script>

{#if shape === 'pill'}
	<span class="skeleton inline" role={announce ? 'status' : undefined} aria-busy="true"
		><span class="skeleton-label">{label}</span><span class="skeleton-bar pill" aria-hidden="true"
		></span></span
	>
{:else}
	<div class="skeleton {shape}" role={announce ? 'status' : undefined} aria-busy="true">
		<span class="skeleton-label">{label}</span>
		{#each indexes as i (i)}
			{#if shape === 'grid'}
				<div
					class="row"
					aria-hidden="true"
					style:grid-template-columns={columns.map((width) => `${width}px`).join(' ')}
				>
					{#each columns as _, c (c)}<span class="cell"
							><span class="skeleton-bar" style:width={`${barWidth(i + c)}%`}></span></span
						>{/each}
				</div>
			{:else if shape === 'record'}
				<div class="row" aria-hidden="true">
					<span class="skeleton-bar" style:width="40%"></span><span
						class="skeleton-bar"
						style:width={`${barWidth(i)}%`}
					></span>
				</div>
			{:else if shape === 'list'}
				<div class="row" aria-hidden="true">
					<span class="skeleton-bar" style:width={`${barWidth(i)}%`}></span>
				</div>
			{:else if shape === 'block'}
				<span class="skeleton-bar block" aria-hidden="true"></span>
			{:else}
				<span class="skeleton-bar" aria-hidden="true" style:width={`${barWidth(i)}%`}></span>
			{/if}
		{/each}
	</div>
{/if}

<style>
	.skeleton:not(.inline) {
		padding: 0.5rem 0;
	}
	.row {
		display: flex;
		align-items: center;
		min-height: 2.25rem;
	}
	.list .row {
		min-height: 2rem;
		padding: 0 0.5rem;
	}
	.grid {
		gap: 0;
		padding: 0;
	}
	.grid .row {
		display: grid;
		min-height: 44px;
		border-bottom: 1px solid var(--color-rule);
	}
	.cell {
		padding: 0 12px;
	}
	.record .row {
		display: grid;
		grid-template-columns: minmax(6rem, 30%) 1fr;
		gap: 1rem;
	}
	.block {
		width: 100%;
		height: 100%;
		min-height: 8rem;
		border-radius: 6px;
	}
</style>
