<script lang="ts">
	import type { Property } from 'iris-core/client';
	import AttachmentControl from './AttachmentControl.svelte';
	import type { AttachmentOutbox } from './attachments';
	import MarkdownEditor from './components/MarkdownEditor.svelte';
	import { retainedFileKey, type RetainedFileResolver } from './retained-files';
	import { onDestroy } from 'svelte';
	import { IconPlus, IconX } from '@tabler/icons-svelte';
	import { creationOffer } from './reference-create';
	import OptionChip from './OptionChip.svelte';
	import { richSelect } from './option-colors';
	import { isFlag } from './cell-values';
	let {
		id,
		property,
		value = $bindable(''),
		disabled = false,
		options = [],
		references = [],
		showReferenceSelections = true,
		onsearch,
		oncreate,
		onchange,
		resolveFile,
		attachments,
		onopenlink,
		invalid,
		referencesLoading = false
	}: {
		id: string;
		property: Property;
		value?: string;
		disabled?: boolean;
		options?: string[];
		references?: { id: string; label: string }[];
		showReferenceSelections?: boolean;
		onsearch?(query: string): void;
		/** Offered only when the host can create a record in the target table. */
		oncreate?(text: string): void;
		onchange?(value: string): void;
		resolveFile?: RetainedFileResolver;
		attachments?: AttachmentOutbox;
		onopenlink?(href: string): Promise<boolean>;
		/** Id of this field's refusal message; marks the control invalid. */
		invalid?: string;
		/** Reference labels are still being read; a stored id is not unavailable yet. */
		referencesLoading?: boolean;
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
	// Browsers with customizable selects show option chips; others keep plain text.
	const rich = richSelect();
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
	let query = $state('');
	const creation = $derived(oncreate && !disabled ? creationOffer(query, references) : null);
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
	const recordLink = $derived(
		property.type === 'text' &&
			value.length <= 4096 &&
			/^[A-Za-z_][A-Za-z0-9_]*\/[^\s/\\?#\u0000-\u001f\u007f]+$/.test(value)
	);
	const fileKey = $derived(property.type === 'file' ? retainedFileKey(value) : null);
	let downloading = $state(false),
		downloadError = $state('');
	let active = true;
	const downloadAbort = new AbortController(),
		downloads: (() => void)[] = [];
	onDestroy(() => {
		active = false;
		downloadAbort.abort();
		for (const dispose of downloads) dispose();
	});
	async function downloadFile() {
		if (!fileKey || !resolveFile || downloading) return;
		const selected = value,
			resolver = resolveFile,
			key = fileKey;
		downloading = true;
		downloadError = '';
		try {
			const file = await resolver(key, downloadAbort.signal);
			if (!active || value !== selected || resolveFile !== resolver) {
				file.dispose();
				return;
			}
			downloads.push(file.dispose);
			const link = document.createElement('a');
			link.href = file.url;
			link.download = key.split('/').at(-1) || 'attachment';
			document.body.appendChild(link);
			link.click();
			link.remove();
		} catch {
			if (active)
				downloadError =
					'The file could not download. Its reference has been kept. Retry when connected.';
		} finally {
			downloading = false;
		}
	}
	let opening = $state(false);
	let openError = $state('');
	async function openRecord() {
		if (!onopenlink || opening) return;
		const original = value;
		opening = true;
		openError = '';
		try {
			if (!(await onopenlink(original)) && value === original)
				openError = 'This record is not available in this workspace.';
		} catch (error) {
			if (value === original && !(error instanceof DOMException && error.name === 'AbortError'))
				openError = error instanceof Error ? error.message : 'Could not open this record.';
		} finally {
			opening = false;
		}
	}
</script>

<div class="field-control">
	{#if property.type === 'ref' || property.type === 'multi_ref'}
		<input
			aria-label={`Search ${label}`}
			placeholder="Search related records"
			{disabled}
			oninput={(event) => {
				query = event.currentTarget.value;
				onsearch?.(query);
			}}
		/>
		{#if creation}<button
				class="field-link create"
				type="button"
				onclick={() => oncreate?.(creation)}
				><IconPlus size={14} aria-hidden="true" />Create “{creation}”</button
			>{/if}
		{#if property.type === 'ref'}
			<select
				{id}
				aria-invalid={invalid ? true : undefined}
				aria-describedby={invalid}
				aria-label={label}
				aria-required={!!property.required}
				{disabled}
				{value}
				onchange={(event) => change(event.currentTarget.value)}
			>
				<option value="">No related record</option>
				{#if value && !references.some((row) => row.id === value)}<option {value}
						>{referencesLoading ? 'Loading…' : `${value} (not available locally)`}</option
					>{/if}
				{#each references as row (row.id)}<option value={row.id}>{row.label}</option>{/each}
			</select>
		{:else}
			<select
				{id}
				aria-invalid={invalid ? true : undefined}
				aria-describedby={invalid}
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
		<MarkdownEditor {id} {label} {value} {disabled} {resolveFile} {onopenlink} onchange={change} />
		{#if attachments}<AttachmentControl
				outbox={attachments}
				{value}
				{disabled}
				onchange={change}
			/>{/if}
	{:else if property.type === 'json'}
		<textarea
			{id}
			aria-invalid={invalid ? true : undefined}
			aria-describedby={invalid}
			aria-label={label}
			aria-required={!!property.required}
			rows={4}
			{disabled}
			{value}
			oninput={(event) => change(event.currentTarget.value)}></textarea>
	{:else if property.type === 'select' || property.type === 'multi_select'}
		<select
			{id}
			class:rich
			aria-invalid={invalid ? true : undefined}
			aria-describedby={invalid}
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
			{#if rich && !multi}<button type="button"><selectedcontent></selectedcontent></button>{/if}
			{#if !multi}<option value="">Choose an option</option>{/if}
			{#each choices as choice (choice)}
				{@const description = property.options?.find((o) => o.v === choice)?.d}
				<option value={choice} title={rich ? description : undefined}
					>{#if rich}<OptionChip {property} value={choice} />{:else}{choice}{description
							? ` - ${description}`
							: ''}{/if}</option
				>{/each}
		</select>
		{#if multi}<div class="chips">
				{#each list(value) as choice}<OptionChip {property} value={choice} />{/each}
			</div>{/if}
	{:else if isFlag(property)}
		<div class="boolean">
			<input
				{id}
				aria-invalid={invalid ? true : undefined}
				aria-describedby={invalid}
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
			aria-invalid={invalid ? true : undefined}
			aria-describedby={invalid}
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
			aria-invalid={invalid ? true : undefined}
			aria-describedby={invalid}
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
	{#if recordLink && onopenlink}
		<button class="field-link" type="button" disabled={opening} onclick={openRecord}
			>{opening ? 'Opening record…' : 'Open record'}</button
		>
		{#if openError}<p role="alert">{openError}</p>{/if}
	{/if}
	<button
		class="clear"
		type="button"
		{disabled}
		aria-label={`Clear ${label}`}
		onclick={() => change('')}>Clear</button
	>
</div>

{#if fileKey && resolveFile}
	<button type="button" disabled={downloading} onclick={downloadFile}
		>{downloading ? 'Downloading…' : 'Download file'}</button
	>
	{#if downloadError}<p role="alert">{downloadError}</p>{/if}
{/if}

{#if property.type === 'file' && attachments}<AttachmentControl
		outbox={attachments}
		{value}
		{disabled}
		onchange={change}
		property
	/>{/if}

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
	.create {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		overflow-wrap: anywhere;
	}
	small {
		color: var(--color-muted);
	}
</style>
