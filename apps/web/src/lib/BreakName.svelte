<script lang="ts">
	/** Snake_case identifiers wrap after underscores instead of mid-word. */
	let { name }: { name: string } = $props();
</script>

{#each name.split('_') as part, index (index)}{#if index}_<wbr />{/if}{part}{/each}
