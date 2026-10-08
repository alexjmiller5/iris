<script lang="ts">
	import { onDestroy, onMount } from 'svelte';
	import { IconArrowUpRight, IconKey, IconX } from '@tabler/icons-svelte';
	import {
		DeviceEnrollment,
		type EnrollmentCore,
		type EnrollmentState,
		type HubConnection
	} from './device-enrollment';
	let {
		core,
		endpoint = $bindable(''),
		token = $bindable(''),
		pending = $bindable(false),
		disabled = false,
		onconnect
	}: {
		core: EnrollmentCore;
		endpoint?: string;
		token?: string;
		pending?: boolean;
		disabled?: boolean;
		onconnect(connection: HubConnection, current: () => boolean): Promise<void>;
	} = $props();
	let name = $state('Life UI browser');
	let enrollmentState = $state<EnrollmentState>({ phase: 'idle', message: '' });
	let model: DeviceEnrollment | undefined;
	let disposed = false;
	onMount(() => {
		model = new DeviceEnrollment({
			core,
			changed(next) {
				if (!disposed) {
					enrollmentState = next;
					pending = ['generating', 'pending', 'connecting'].includes(next.phase);
				}
			},
			install: onconnect
		});
	});
	onDestroy(() => {
		disposed = true;
		void model?.cancel();
	});
	function changedEndpoint() {
		void model?.cancel();
	}
</script>

<div class="enrollment">
	<label for="endpoint">Hub address</label>
	<input
		id="endpoint"
		type="url"
		bind:value={endpoint}
		oninput={changedEndpoint}
		placeholder="https://your-hub.example"
		{disabled}
	/>
	<label for="device-name">Device name</label>
	<input id="device-name" bind:value={name} maxlength="100" disabled={disabled || pending} />
	<button
		type="button"
		onclick={() => void model?.start(endpoint, name)}
		disabled={disabled || pending || !endpoint || !name.trim()}
		><IconKey size={16} />Approve this browser</button
	>
	{#if enrollmentState.approval && enrollmentState.phase === 'pending'}
		<p class="code">Approval code: <strong>{enrollmentState.approval.code}</strong></p>
		<a
			class="approval"
			href={enrollmentState.approval.url}
			target="_blank"
			rel="noopener noreferrer">Open approval page <IconArrowUpRight size={16} /></a
		>
		<p class="hint">Confirm the code at your hub.</p>
	{/if}
	{#if pending}<button class="secondary" type="button" onclick={() => void model?.cancel()}
			><IconX size={16} />Cancel approval</button
		>{/if}
	{#if enrollmentState.message}<p
			role={enrollmentState.phase === 'failed' ? 'alert' : 'status'}
			class="hint"
		>
			{enrollmentState.message}
		</p>{/if}
	<details>
		<summary>Use a device token</summary>
		<label for="token">Device token</label>
		<input
			id="token"
			type="password"
			bind:value={token}
			oninput={changedEndpoint}
			autocomplete="off"
			disabled={disabled || pending}
		/>
		<button
			type="button"
			onclick={() => void model?.manual({ endpoint, token })}
			disabled={disabled || pending || !endpoint || !token}>Connect</button
		>
		<p class="hint">Use a dedicated full device token. It stays in memory for this session.</p>
	</details>
</div>

<style>
	.enrollment {
		display: grid;
		gap: 0.55rem;
		min-width: 0;
	}
	label {
		font-size: 0.78rem;
		font-weight: 600;
	}
	input {
		box-sizing: border-box;
		width: 100%;
		min-width: 0;
		border: 1px solid var(--color-rule);
		border-radius: 0.4rem;
		padding: 0.55rem;
		background: var(--color-paper);
		font: inherit;
		font-size: 0.8rem;
	}
	button,
	.approval {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 0.4rem;
		padding: 0.55rem;
		border-radius: 0.4rem;
		font-size: 0.78rem;
		background: var(--color-ink);
		color: var(--color-paper);
		cursor: pointer;
	}
	.secondary {
		background: var(--color-bone);
		color: var(--color-ink);
		border: 1px solid var(--color-rule);
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	.hint {
		font-size: 0.75rem;
		color: var(--color-muted);
		line-height: 1.5;
		overflow-wrap: anywhere;
	}
	.code {
		font-size: 0.8rem;
	}
	.code strong {
		font-family: ui-monospace, monospace;
	}
	summary {
		cursor: pointer;
		font-size: 0.8rem;
		margin: 0.6rem 0;
	}
	details label {
		display: block;
		margin: 0.5rem 0;
	}
	input:focus-visible,
	button:focus-visible,
	a:focus-visible,
	summary:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 2px;
	}
</style>
