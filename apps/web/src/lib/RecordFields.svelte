<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { Property } from 'iris-core/client';
	let { properties, field }: { properties: Property[]; field: Snippet<[Property]> } = $props();
	const active = $derived(properties.filter((p) => !p.deprecated));
	const deprecated = $derived(properties.filter((p) => p.deprecated));
</script>

{#each active as property (property.col)}{@render field(property)}{/each}
{#if deprecated.length}
	<details>
		<summary>Deprecated columns ({deprecated.length})</summary>
		<p>Historical values are preserved and read-only.</p>
		{#each deprecated as property (property.col)}{@render field(property)}{/each}
	</details>
{/if}

<style>
	details {
		margin-block: 1rem;
	}
	summary {
		cursor: pointer;
		font-weight: 600;
	}
	p {
		color: var(--color-muted);
		font-size: 0.875rem;
	}
</style>
