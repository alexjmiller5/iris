<script lang="ts">
	import type { Property } from 'life-ui-core/client';
	import MarkdownEditor from './components/MarkdownEditor.svelte';
	import { IconX } from '@tabler/icons-svelte';
	let {
		id,
		property,
		value = $bindable(''),
		disabled = false,
		options = [],
		references = [],
		showReferenceSelections = true,
		onsearch,
		onchange
	}: {
		id: string;
		property: Property;
		value?: string;
		disabled?: boolean;
		options?: string[];
		references?: { id: string; label: string }[];
		showReferenceSelections?: boolean;
		onsearch?(query: string): void;
		onchange?(value: string): void;
	} = $props();
	const label = $derived(
		property.label ||
			property.col.charAt(0).toUpperCase() + property.col.slice(1).replaceAll('_', ' ')
	);
	function list(raw: string): string[] {
		try {
			const values = JSON.parse(raw);
			return Array.isArray(values) ? values.map(String) : [];
		} catch {
			return [];
		}
	}
	const multi = $derived(property.type === 'multi_select' || property.type === 'multi_ref');
	const choices = $derived([
		...new Set([
			...options,
			...(property.options ?? []).map((o) => o.v),
			...(multi ? list(value) : [value].filter(Boolean))
		])
	]);
	const selected = $derived(
		property.type === 'multi_ref' ? [...new Set(list(value))] : [value].filter(Boolean)
	);
	function change(raw: string) {
		value = raw;
		onchange?.(raw);
	}
	function dateTime(raw: string) {
		const date = new Date(raw + 'Z');
		change(!raw ? '' : Number.isFinite(date.getTime()) ? date.toISOString() : raw);
	}
	function openLink(type: Property['type'], raw: string): string | null {
		if (!raw || /[\u0000-\u001f\u007f]/.test(raw)) return null;
		if (type === 'url') {
			if (!/^https?:\/\/[^/\\\s]/i.test(raw)) return null;
			try {
				const url = new URL(raw);
				return url.hostname ? url.href : null;
			} catch {
				return null;
			}
		}
		if (type === 'email') {
			try {
				return raw.includes('@') && !/\s/.test(raw)
					? 'mailto:' + encodeURIComponent(raw).replaceAll('%40', '@')
					: null;
			} catch {
				return null;
			}
		}
		if (type === 'phone') {
			const number = raw.replace(/[ ()\-.]/g, '');
			return /^\+?[0-9]+$/.test(number) ? 'tel:' + number : null;
		}
		return null;
	}
	const link = $derived(openLink(property.type, value));
</script>

<div class="field-control">
	{#if property.type === 'ref' || property.type === 'multi_ref'}
		<input
			aria-label={`Search ${label}`}
			placeholder="Search related records"
			{disabled}
			oninput={(event) => onsearch?.(event.currentTarget.value)}
		/>
		{#if property.type === 'ref'}
			<select
				{id}
				aria-label={label}
				aria-required={!!property.required}
				{disabled}
				{value}
				onchange={(event) => change(event.currentTarget.value)}
			>
				<option value="">No related record</option>
				{#if value && !references.some((row) => row.id === value)}<option {value}
						>{value} (not available locally)</option
					>{/if}
				{#each references as row (row.id)}<option value={row.id}>{row.label}</option>{/each}
			</select>
		{:else}
			<select
				{id}
				aria-label={label}
				{disabled}
				value=""
				onchange={(event) => {
					const id = event.currentTarget.value;
					if (id) change(JSON.stringify([...new Set([...selected, id])]));
					event.currentTarget.value = '';
				}}
			>
				<option value="">Add related record</option>
				{#each references as row (row.id)}<option value={row.id}>{row.label}</option>{/each}
			</select>
			{#if showReferenceSelections}<div class="chips" aria-label={`${label} selected records`}>
					{#each selected as chosen (chosen)}<span class="chip"
							>{references.find((row) => row.id === chosen)?.label ?? chosen}<button
								type="button"
								{disabled}
								aria-label={`Remove ${references.find((row) => row.id === chosen)?.label ?? chosen}`}
								onclick={() => change(JSON.stringify(selected.filter((id) => id !== chosen)))}
								><IconX size={14} /></button
							></span
						>{/each}
				</div>{/if}
		{/if}
	{:else if property.type === 'markdown'}
		<MarkdownEditor {id} {label} {value} {disabled} onchange={change} />
	{:else if property.type === 'json'}
		<textarea
			{id}
			aria-label={label}
			aria-required={!!property.required}
			rows={4}
			{disabled}
			{value}
			oninput={(event) => change(event.currentTarget.value)}></textarea>
	{:else if property.type === 'select' || property.type === 'multi_select'}
		<select
			{id}
			aria-label={label}
			aria-required={!!property.required}
			{disabled}
			multiple={multi}
			value={multi ? list(value) : value}
			onchange={(event) =>
				change(
					multi
						? JSON.stringify([...event.currentTarget.selectedOptions].map((option) => option.value))
						: event.currentTarget.value
				)}
		>
			{#if !multi}<option value="">Choose an option</option>{/if}
			{#each choices as choice (choice)}<option value={choice}
					>{choice}{property.options?.find((o) => o.v === choice)?.d
						? ` - ${property.options.find((o) => o.v === choice)?.d}`
						: ''}</option
				>{/each}
		</select>
		{#if multi}<div class="chips">
				{#each list(value) as choice}<span class="chip">{choice}</span>{/each}
			</div>{/if}
	{:else if property.type === 'bool'}
		<div class="boolean">
			<input
				{id}
				type="checkbox"
				aria-label={label}
				{disabled}
				checked={value === '1' || value === 'true'}
				indeterminate={value === ''}
				onchange={(event) => change(event.currentTarget.checked ? '1' : '0')}
			/><span>{value === '' ? 'Empty' : value === '1' || value === 'true' ? 'Yes' : 'No'}</span>
		</div>
	{:else if property.type === 'datetime'}
		<input
			{id}
			aria-label={label}
			aria-required={!!property.required}
			type="datetime-local"
			step="0.001"
			{disabled}
			value={value.replace(/Z$/, '')}
			onchange={(event) => dateTime(event.currentTarget.value)}
		/><small>UTC</small>
	{:else}
		<input
			{id}
			aria-label={label}
			aria-required={!!property.required}
			type={property.type === 'date'
				? 'date'
				: property.type === 'url'
					? 'url'
					: property.type === 'email'
						? 'email'
						: property.type === 'phone'
							? 'tel'
							: 'text'}
			inputmode={['number', 'int'].includes(property.type ?? '') ? 'decimal' : undefined}
			{disabled}
			{value}
			oninput={(event) => change(event.currentTarget.value)}
		/>
	{/if}
	{#if link}
		<a
			class="field-link"
			href={link}
			target={property.type === 'url' ? '_blank' : undefined}
			rel={property.type === 'url' ? 'noopener noreferrer' : undefined}
			>{property.type === 'email'
				? 'Compose email'
				: property.type === 'phone'
					? 'Call'
					: 'Open website'}</a
		>
	{/if}
	<button
		class="clear"
		type="button"
		{disabled}
		aria-label={`Clear ${label}`}
		onclick={() => change('')}>Clear</button
	>
</div>

<style>
	.field-control {
		display: grid;
		gap: 6px;
		min-width: 0;
	}
	input,
	select,
	textarea {
		width: 100%;
		min-width: 0;
		box-sizing: border-box;
		font: inherit;
		color: var(--color-ink);
		background: var(--color-paper);
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		padding: 8px 10px;
	}
	input:disabled,
	select:disabled,
	textarea:disabled {
		opacity: 0.6;
	}
	textarea {
		resize: vertical;
	}
	.boolean {
		display: flex;
		align-items: center;
		gap: 8px;
	}
	.boolean input {
		width: 18px;
		height: 18px;
	}
	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 4px;
	}
	.chip {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		max-width: 100%;
		overflow-wrap: anywhere;
		background: var(--color-accent-soft);
		border-radius: 4px;
		padding: 3px 6px;
		font-size: 12px;
	}
	.chip button {
		display: inline-flex;
		padding: 2px;
	}
	button {
		color: var(--color-muted);
		border: 0;
		background: transparent;
		cursor: pointer;
	}
	button:disabled {
		opacity: 0.45;
		cursor: default;
	}
	.clear,
	.field-link {
		justify-self: start;
		padding: 2px 0;
		font: inherit;
		font-size: 12px;
		text-decoration: underline;
	}
	.field-link {
		color: var(--color-ink);
	}
	small {
		color: var(--color-muted);
	}
</style>
