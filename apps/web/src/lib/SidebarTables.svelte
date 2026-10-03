<script lang="ts">
	import { IconDatabase } from '@tabler/icons-svelte';
	import type { Row } from 'life-ui-core/client';
	let {
		tables,
		current,
		disabled,
		onchoose
	}: { tables: Row[]; current: string; disabled: boolean; onchoose: (table: string) => unknown } =
		$props();
	const ordinary = $derived(tables.filter((table) => table.readOnly !== true));
	const system = $derived(tables.filter((table) => table.readOnly === true));
</script>

{#snippet choices(items: Row[])}
	{#each items as table (table.id)}
		<button
			type="button"
			class:active={String(table.id) === current}
			aria-current={String(table.id) === current ? 'page' : undefined}
			{disabled}
			onclick={() => onchoose(String(table.id))}
			><IconDatabase size={16} /><span>{String(table.id)}</span></button
		>
	{/each}
{/snippet}
<div class="table-groups">
	<nav aria-label="Tables">{@render choices(ordinary)}</nav>
	{#if system.length}
		<details open={system.some((table) => String(table.id) === current)}>
			<summary>System tables</summary>
			<nav aria-label="System tables">{@render choices(system)}</nav>
		</details>
	{/if}
</div>

<style>
	.table-groups {
		min-width: 0;
		display: grid;
		gap: 12px;
	}
	nav {
		display: grid;
		gap: 3px;
		max-height: 40vh;
		overflow: auto;
		padding: 3px;
	}
	button {
		display: flex;
		align-items: center;
		gap: 8px;
		min-width: 0;
		border: 0;
		border-radius: var(--radius-field);
		padding: 10px 12px;
		justify-content: start;
		background: none;
		color: var(--color-muted);
		font-size: 13px;
		font-weight: 500;
		text-align: left;
		cursor: pointer;
	}
	button span {
		overflow-wrap: anywhere;
	}
	button :global(svg) {
		flex: none;
	}
	button.active {
		color: var(--color-accent);
		background: var(--color-accent-soft);
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	summary {
		font-size: 12px;
		color: var(--color-muted);
		cursor: pointer;
		padding: 6px 8px;
	}
	@media (max-width: 700px) {
		nav {
			display: flex;
		}
		button {
			flex: none;
			max-width: 220px;
		}
		details nav {
			max-height: 160px;
			flex-wrap: wrap;
		}
	}
</style>
