<script lang="ts">
	import type { ApprovalReceipt, Target } from './contract';
	import type { ApprovalJournal, ApprovalScope, GovernanceAPI } from './api';
	import GovernancePanelBody from './GovernancePanelBody.svelte';
	let {
		api,
		scope,
		target,
		journal,
		online,
		onApplied = () => {}
	}: {
		api: GovernanceAPI | null;
		scope: ApprovalScope;
		target: Target;
		journal: ApprovalJournal | null;
		online: boolean;
		onApplied?: (receipt: ApprovalReceipt) => void;
	} = $props();
</script>

{#key api}
	{#key journal}
		{#key JSON.stringify( [scope.deploymentId, scope.sessionId, scope.principalId, target.table, target.rowId] )}
			<GovernancePanelBody {api} {scope} {target} {journal} {online} {onApplied} />
		{/key}
	{/key}
{/key}
