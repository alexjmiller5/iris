<script lang="ts">
	import SchemaGraph from './SchemaGraph.svelte';
	import { parseGraphInput, type GraphData, type GraphMessage } from './graph-island';

	let { onMessage }: { onMessage: (message: GraphMessage) => void } = $props();
	let catalog = $state<GraphData>({ tables: [], properties: [], groups: {} });

	export function render(input: unknown) {
		catalog = parseGraphInput(input);
	}
</script>

<main>
	<SchemaGraph
		tables={catalog.tables}
		properties={catalog.properties}
		onSelect={(table) => onMessage({ type: 'openTable', table })}
		bind:groups={
			() => catalog.groups,
			(groups) => {
				catalog.groups = groups;
				onMessage({ type: 'groups', groups });
			}
		}
	/>
</main>

<style>
	main {
		padding: 24px;
		max-width: 1440px;
		margin: 0 auto;
	}
	:global(input) {
		border: 1px solid var(--color-rule);
		border-radius: 6px;
		padding: 8px 10px;
		color: var(--color-ink);
		background: var(--color-paper);
	}
	@media (max-width: 480px) {
		main {
			padding: 16px;
		}
	}
</style>
