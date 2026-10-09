<script lang="ts">
	import type { Property } from 'iris-core/client';
	import { IconX } from '@tabler/icons-svelte';
	import { DATE_TYPES, defaultRule, operatorsFor, opLabel, type Rule } from './filter-bar';

	// Edits one filter rule. Every change is reported at once; the parent decides
	// whether the rule is complete enough to apply and save.
	let {
		rule,
		properties,
		pick = false,
		single = false,
		error = '',
		options = {},
		references = () => [],
		onsearch,
		onchange,
		onremove
	}: {
		rule: Rule;
		properties: Property[];
		/** Show a property picker (advanced group rules). */
		pick?: boolean;
		/** Allow one value only (advanced group rules save one filter each). */
		single?: boolean;
		error?: string;
		options?: Record<string, string[]>;
		references?: (p: Property) => { id: string; label: string }[];
		onsearch?: (p: Property, query: string) => void;
		onchange: (rule: Rule) => void;
		onremove?: () => void;
	} = $props();
	const id = $props.id();
	const property = $derived(
		properties.find((p) => p.col === rule.column) ?? ({ col: rule.column } as Property)
	);
	const type = $derived(property.type ?? 'text');
	const label = (p: Property) => p.label || p.col;
	const valued = $derived(!['empty', 'not_empty'].includes(rule.op));
	const listed = $derived(['select', 'multi_select', 'ref', 'multi_ref'].includes(type));
	const refs = $derived(type === 'ref' || type === 'multi_ref');
	let query = $state('');
	$effect(() => {
		// Load choices once per property; ref search narrows them as the person types.
		if (listed) onsearch?.(property, '');
	});
	const choices = $derived.by(() => {
		if (refs) {
			const found = references(property);
			return [
				...found,
				...rule.values
					.filter((v) => !found.some((row) => row.id === v))
					.map((v) => ({ id: v, label: v }))
			];
		}
		const values = [
			...new Set([
				...(property.options ?? []).map((o) => o.v),
				...(options[property.col] ?? []),
				...rule.values
			])
		];
		const q = query.trim().toLowerCase();
		return values
			.filter((v) => !q || v.toLowerCase().includes(q))
			.map((v) => ({ id: v, label: v }));
	});
	function toggle(value: string, on: boolean) {
		const values = single
			? on
				? [value]
				: []
			: on
				? [...rule.values, value]
				: rule.values.filter((v) => v !== value);
		onchange({ ...rule, values });
	}
	function setOp(op: Rule['op']) {
		const relative =
			rule.relative && !['empty', 'not_empty'].includes(op) ? rule.relative : undefined;
		onchange({ column: rule.column, op, values: rule.values, ...(relative ? { relative } : {}) });
	}
	const dateValue = (value: string) =>
		type === 'datetime' ? value.replace(/(\.\d+)?Z$/, '') : value.slice(0, 10);
	function setDate(raw: string) {
		if (type !== 'datetime' || !raw) return onchange({ ...rule, values: [raw] });
		const date = new Date(raw + 'Z');
		onchange({ ...rule, values: [Number.isFinite(date.getTime()) ? date.toISOString() : raw] });
	}
</script>

<div class="rule" class:pick>
	<div class="line">
		{#if pick}
			<select
				aria-label="Property"
				value={rule.column}
				onchange={(e) => {
					const next = properties.find((p) => p.col === e.currentTarget.value);
					if (next) onchange(defaultRule(next.col, next.type ?? 'text'));
				}}
			>
				{#each properties as p (p.col)}<option value={p.col}>{label(p)}</option>{/each}
			</select>
		{/if}
		{#if type !== 'bool'}
			<select
				aria-label="Condition"
				value={rule.op}
				onchange={(e) => setOp(e.currentTarget.value as Rule['op'])}
			>
				{#each operatorsFor(type) as op (op)}<option value={op}>{opLabel(op, type)}</option>{/each}
			</select>
		{/if}
		{#if onremove}
			<button type="button" class="icon" aria-label="Remove rule" onclick={onremove}
				><IconX size={16} aria-hidden="true" /></button
			>
		{/if}
	</div>
	{#if valued}
		{#if type === 'bool'}
			<div class="segmented" role="radiogroup" aria-label="Value">
				{#each [['true', 'Checked'], ['false', 'Unchecked']] as [value, text] (value)}
					<label
						><input
							type="radio"
							name={`${id}-bool`}
							checked={rule.values[0] === value}
							onchange={() => onchange({ ...rule, values: [value] })}
						/>{text}</label
					>
				{/each}
			</div>
		{:else if DATE_TYPES.includes(type)}
			<div class="segmented" role="radiogroup" aria-label="Compare with">
				<label
					><input
						type="radio"
						name={`${id}-date`}
						checked={!rule.relative}
						onchange={() => {
							const { relative: _relative, ...exact } = rule;
							onchange(exact);
						}}
					/>Date</label
				>
				<label
					><input
						type="radio"
						name={`${id}-date`}
						checked={rule.relative === 'today'}
						onchange={() => onchange({ ...rule, values: [], relative: 'today' })}
					/>Today</label
				>
			</div>
			{#if !rule.relative}
				<input
					aria-label="Date value"
					type={type === 'datetime' ? 'datetime-local' : 'date'}
					step={type === 'datetime' ? 1 : undefined}
					value={dateValue(rule.values[0] ?? '')}
					onchange={(e) => setDate(e.currentTarget.value)}
				/>
				{#if type === 'datetime'}<small>UTC</small>{/if}
			{/if}
		{:else if listed}
			{#if refs || choices.length > 8 || query}
				<input
					type="search"
					aria-label={refs ? 'Search related records' : 'Search options'}
					placeholder={refs ? 'Search records' : 'Search options'}
					bind:value={query}
					oninput={() => refs && onsearch?.(property, query)}
				/>
			{/if}
			<div class="choices" role="group" aria-label="Values">
				{#each choices as choice (choice.id)}
					<label class="choice"
						><input
							type={single ? 'radio' : 'checkbox'}
							name={`${id}-values`}
							checked={rule.values.includes(choice.id)}
							onchange={(e) => toggle(choice.id, e.currentTarget.checked)}
						/><span>{choice.label}</span></label
					>
				{:else}
					<p class="hint">{refs ? 'No matching records' : 'No options'}</p>
				{/each}
			</div>
		{:else}
			<input
				aria-label="Value"
				type={['number', 'int'].includes(type) ? 'number' : 'text'}
				step={['number', 'int'].includes(type) ? 'any' : undefined}
				inputmode={['number', 'int'].includes(type) ? 'decimal' : undefined}
				placeholder="Type a value"
				value={rule.values[0] ?? ''}
				oninput={(e) => onchange({ ...rule, values: [e.currentTarget.value] })}
			/>
		{/if}
	{/if}
	{#if error}<p class="error" role="alert">{error}</p>{/if}
</div>

<style>
	.rule {
		display: grid;
		gap: 0.5rem;
		min-width: 0;
	}
	.line {
		display: flex;
		gap: 0.375rem;
		align-items: center;
		min-width: 0;
	}
	.line select {
		flex: 1 1 auto;
		min-width: 0;
	}
	select,
	input:not([type='radio'], [type='checkbox']) {
		min-height: 2.25rem;
		padding: 0.375rem 0.5rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
		font-size: 0.8125rem;
		min-width: 0;
		width: 100%;
	}
	.line select {
		width: auto;
	}
	.icon {
		display: inline-grid;
		place-items: center;
		flex: none;
		width: 2rem;
		height: 2rem;
		border: 0;
		border-radius: var(--radius-field);
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}
	.icon:hover {
		background: var(--color-bone);
		color: var(--color-ink);
	}
	.segmented {
		display: flex;
		gap: 0.25rem;
		padding: 0.1875rem;
		border-radius: var(--radius-field);
		background: var(--color-bone);
	}
	.segmented label {
		flex: 1;
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 0.375rem;
		min-height: 2rem;
		border-radius: calc(var(--radius-field) - 2px);
		font-size: 0.8125rem;
		cursor: pointer;
	}
	.segmented label:has(input:checked) {
		background: var(--color-paper);
		box-shadow: 0 0 0 1px var(--color-rule);
	}
	.segmented input {
		position: absolute;
		opacity: 0;
		pointer-events: none;
	}
	.segmented label:has(input:focus-visible) {
		outline: 2px solid var(--color-accent);
		outline-offset: 1px;
	}
	.choices {
		display: grid;
		max-height: 15rem;
		overflow-y: auto;
		margin: 0 -0.25rem;
	}
	.choice {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		min-height: 2.25rem;
		padding: 0 0.5rem;
		border-radius: var(--radius-field);
		font-size: 0.8125rem;
		cursor: pointer;
	}
	.choice:hover {
		background: var(--color-bone);
	}
	.choice input {
		accent-color: var(--color-accent);
		margin: 0;
	}
	.choice span {
		overflow-wrap: anywhere;
	}
	small,
	.hint {
		margin: 0;
		color: var(--color-muted);
		font-size: 0.75rem;
	}
	.error {
		margin: 0;
		color: var(--color-violation);
		font-size: 0.75rem;
	}
</style>
