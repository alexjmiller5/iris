<script lang="ts">
	import type { Property } from 'iris-core/client';
	import { optionColor } from './option-colors';
	let { property, value }: { property: Pick<Property, 'options'>; value: string } = $props();
</script>

<span class="option-chip" data-color={optionColor(property, value) ?? undefined}>{value}</span>
