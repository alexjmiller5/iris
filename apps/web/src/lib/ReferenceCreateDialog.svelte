<script lang="ts">
	import { untrack } from 'svelte';
	import type { Property } from 'life-ui-core/client';
	import FieldEditor from './FieldEditor.svelte';
	import type { CreationPlan } from './reference-create';
	let {
		plan,
		error = '',
		busy = false,
		onsave,
		oncancel
	}: {
		plan: CreationPlan;
		error?: string;
		busy?: boolean;
		onsave(plan: CreationPlan): void;
		oncancel(): void;
	} = $props();
	// The dialog owns this draft; Cancel drops it without touching the source record.
	let values = $state(untrack(() => ({ ...plan.values })));
	const explicit = untrack(() => new Set(plan.explicit));
	let dialog: HTMLDialogElement;
	$effect(() => {
		dialog?.showModal();
		// Start where the user has work to do: the first required field without a value.
		const first = untrack(() => plan.missing[0]?.col);
		if (first) dialog?.querySelector<HTMLElement>(`#${CSS.escape(`create-${first}`)}`)?.focus();
	});
	const label = (p: Property) =>
		p.label || p.col.charAt(0).toUpperCase() + p.col.slice(1).replaceAll('_', ' ');
	const missing = (p: Property) => plan.missing.some((m) => m.col === p.col);
</script>

<dialog
	bind:this={dialog}
	aria-labelledby="reference-create-title"
	oncancel={(event) => {
		event.preventDefault();
		if (!busy) oncancel();
	}}
>
	<form
		novalidate
		onsubmit={(event) => {
			event.preventDefault();
			onsave({ ...plan, values: $state.snapshot(values), explicit });
		}}
	>
		<header>
			<p class="eyebrow">{plan.table}</p>
			<h2 id="reference-create-title">New record</h2>
		</header>
		<p class="hint">Complete the required fields. Saving adds this record to the relation.</p>
		{#each plan.properties as p (p.col)}
			<div class="field">
				<label for={`create-${p.col}`}
					>{label(p)}{#if p.required}<span class="required" class:missing={missing(p)}
							>Required</span
						>{/if}</label
				>
				<FieldEditor
					id={`create-${p.col}`}
					property={p}
					bind:value={values[p.col]}
					onchange={() => explicit.add(p.col)}
					disabled={busy}
				/>
			</div>
		{/each}
		{#if error}<p role="alert">{error}</p>{/if}
		<footer>
			<button type="button" class="secondary" onclick={oncancel} disabled={busy}>Cancel</button>
			<button type="submit" disabled={busy}>Save record</button>
		</footer>
	</form>
</dialog>

<style>
	dialog {
		margin: auto;
		width: min(32rem, calc(100vw - 32px));
		max-height: 90vh;
		padding: 0;
		border: 1px solid var(--color-rule);
		border-radius: 0.5rem;
		background: var(--color-paper);
		color: var(--color-ink);
	}
	dialog::backdrop {
		background: rgb(0 0 0 / 0.35);
	}
	form {
		display: grid;
		gap: 0.9rem;
		padding: 1.25rem;
	}
	h2 {
		margin: 0;
	}
	.eyebrow,
	.hint {
		margin: 0;
		color: var(--color-muted);
		font-size: 0.875rem;
	}
	.field {
		display: grid;
		gap: 0.3rem;
	}
	label {
		font-size: 0.875rem;
		font-weight: 600;
	}
	.required {
		margin-left: 0.5rem;
		color: var(--color-muted);
		font-size: 0.75rem;
		font-weight: 400;
	}
	.required.missing {
		color: var(--color-ink);
	}
	[role='alert'] {
		margin: 0;
		color: var(--color-violation);
	}
	footer {
		display: flex;
		justify-content: flex-end;
		gap: 0.5rem;
	}
	footer button {
		min-height: 38px;
		border: 1px solid transparent;
		border-radius: 6px;
		background: var(--color-accent);
		color: var(--color-on-accent);
		padding: 8px 13px;
		font: inherit;
		font-size: 13px;
		font-weight: 600;
		cursor: pointer;
	}
	footer .secondary {
		color: var(--color-ink);
		background: var(--color-paper);
		border-color: var(--color-rule);
	}
	footer button:disabled {
		opacity: 0.45;
		cursor: default;
	}
</style>
