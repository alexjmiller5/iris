<script lang="ts">
	import type { Property, Row } from 'life-ui-core/client';
	import type { BulkRecordResult } from './bulk-records';
	let { selectedIds, properties, onrun }: {
		selectedIds: string[]; properties: Property[];
		onrun: (patch: Row, signal: AbortSignal, progress: (results: BulkRecordResult[]) => void) => Promise<BulkRecordResult[]>;
	} = $props();
</script>
<details><summary>Selection</summary></details>
