<script lang="ts">
	import type { Change } from './contract';
	import { displayCell } from './value';
	let { changes }: { changes: Change[] } = $props();
</script>

<!-- svelte-ignore a11y_no_noninteractive_tabindex (Focus enables keyboard scrolling of long diffs.) -->
<div class="diff" role="region" aria-label="Proposed changes" tabindex="0">
	<table>
		<thead><tr><th>Property</th><th>Current</th><th>Proposed</th></tr></thead>
		<tbody>
			{#each changes as change (change.column)}
				<tr>
					<th scope="row">{change.column}</th>
					<td class="before">{displayCell(change.before)}</td>
					<td class="after">{displayCell(change.after)}</td>
				</tr>
			{/each}
		</tbody>
	</table>
</div>

<style>
	.diff {
		overflow: auto;
		max-height: 24rem;
	}
	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 0.875rem;
	}
	th,
	td {
		padding: 0.65rem;
		text-align: left;
		vertical-align: top;
		border-bottom: 1px solid var(--color-rule);
		white-space: pre-wrap;
		overflow-wrap: anywhere;
		min-width: 7rem;
	}
	thead th {
		position: sticky;
		top: 0;
		background: var(--color-paper);
	}
	.after {
		background: var(--color-accent-soft);
	}
	.before {
		color: var(--color-muted);
	}
	.diff:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 2px;
	}
</style>
