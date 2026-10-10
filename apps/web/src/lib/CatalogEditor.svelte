<script lang="ts">
	import { onDestroy, untrack } from 'svelte';
	import { focusReturn } from './popover';
	import { OPTION_COLORS } from 'iris-core/client';
	import { IconCheck, IconPalette } from '@tabler/icons-svelte';
	import OptionChip from './OptionChip.svelte';
	import { newOptionColor } from './option-colors';
	let dialog: HTMLDialogElement;
	onDestroy(focusReturn());
	$effect(() => {
		dialog?.showModal();
	});
	import type {
		Catalog,
		Property,
		Row,
		SaveCatalogPropertyArgs,
		SaveCatalogRuleArgs,
		OptionDef
	} from 'iris-core/client';
	let {
		table,
		catalog,
		onproperty,
		onrule,
		onclose
	}: {
		table: string;
		catalog: Catalog;
		onproperty: (args: SaveCatalogPropertyArgs) => Promise<Property>;
		onrule: (args: SaveCatalogRuleArgs) => Promise<Row>;
		onclose: () => void;
	} = $props();
	const types = [
		'text',
		'markdown',
		'number',
		'int',
		'bool',
		'date',
		'datetime',
		'date_or_datetime',
		'json',
		'select',
		'multi_select',
		'ref',
		'multi_ref',
		'url',
		'email',
		'phone'
	];
	const system = new Set(['id', 'created_at', 'updated_at', 'hub_at', 'deleted_at']);
	const properties = $derived(
		catalog.properties.filter((p) => p.tbl === table && !system.has(p.col))
	);
	const rules = $derived(catalog.rules.filter((r) => r.tbl === table));
	let mode = $state<'property' | 'rule'>('property');
	let original = $state<Row | null>(
		untrack(() => catalog.properties.find((p) => p.tbl === table && !system.has(p.col)) ?? null)
	);
	function draft(row: Row | null) {
		return {
			key: String(row?.col ?? row?.id ?? ''),
			type: String(row?.type ?? 'text'),
			label: String(row?.label ?? ''),
			description: String(row?.description ?? ''),
			required: row?.required === 1,
			hasDefault: row?.default_value != null,
			defaultValue: String(row?.default_value ?? ''),
			immutable: row?.immutable === 1,
			deprecated: row?.deprecated === 1,
			refTable: String(row?.ref_table ?? ''),
			pattern: String(row?.pattern ?? ''),
			optionsSQL: String(row?.options_sql ?? ''),
			kind: String(row?.kind ?? 'doctrine'),
			scope: String(row?.scope ?? 'table'),
			text: String(row?.text ?? ''),
			sql: String(row?.sql ?? ''),
			enforce: row?.enforce === 1,
			ruleColumn: String(row?.col ?? '')
		};
	}
	let form = $state(untrack(() => draft(original)));
	let options = $state<OptionDef[]>(
		untrack(() => ((original?.options as OptionDef[] | null) ?? []).map((o) => ({ ...o })))
	);
	let saving = $state(false);
	let dirty = $state(false);
	let failure = $state('');
	let receipt = $state('');
	function load(row: Row | null, next = mode) {
		if (saving || (dirty && !confirm('Discard unsaved catalog changes?'))) return;
		mode = next;
		original = row;
		form = draft(row);
		if (next === 'rule') form.key = String(row?.id ?? '');
		options = ((row?.options as OptionDef[] | null) ?? []).map((o) => ({ ...o }));
		dirty = false;
		failure = '';
		receipt = '';
	}
	function close() {
		if (!saving && (!dirty || confirm('Discard unsaved catalog changes?'))) onclose();
	}
	async function save(event: SubmitEvent) {
		event.preventDefault();
		if (saving) return;
		const revision = typeof original?.updated_at === 'string' ? original.updated_at : null;
		const fields: Row =
			mode === 'property'
				? {
						type: form.type,
						label: form.label || null,
						description: form.description || null,
						required: Number(form.required),
						default_value: form.hasDefault ? form.defaultValue : null,
						immutable: Number(form.immutable),
						deprecated: Number(form.deprecated),
						...(['select', 'multi_select'].includes(form.type)
							? {
									options: options.map(({ color, ...o }) => ({
										...o,
										v: o.v,
										d: o.d ?? '',
										...(color ? { color } : {})
									})),
									options_sql: form.optionsSQL || null
								}
							: {}),
						...(['ref', 'multi_ref'].includes(form.type)
							? { ref_table: form.refTable || null }
							: {}),
						pattern: form.pattern || null
					}
				: {
						kind: form.kind,
						scope: form.scope,
						text: form.text,
						sql: form.sql || null,
						enforce: Number(form.enforce),
						col: form.ruleColumn || null
					};
		saving = true;
		failure = '';
		receipt = '';
		try {
			const row =
				mode === 'property'
					? await onproperty({
							table,
							column: form.key,
							fields,
							expectedUpdatedAt: revision,
							addColumn: original === null
						})
					: await onrule({ table, id: form.key, fields, expectedUpdatedAt: revision });
			original = row;
			dirty = false;
			receipt = 'Saved to the catalog and its change log.';
		} catch (error) {
			failure = error instanceof Error ? error.message : String(error);
		} finally {
			saving = false;
		}
	}
</script>

<dialog
	bind:this={dialog}
	oncancel={(event) => {
		event.preventDefault();
		close();
	}}
>
	<section aria-label="Catalog editor" class="catalog-editor">
		<header>
			<div>
				<p class="eyebrow">{table}</p>
				<h2>Catalog</h2>
			</div>
			<button type="button" onclick={close} disabled={saving}>Close catalog</button>
		</header>
		<p class="hint">Define properties, choices and rules. Existing records are kept unchanged.</p>
		<nav aria-label="Catalog sections">
			<button
				type="button"
				aria-pressed={mode === 'property'}
				onclick={() => load(properties[0] ?? null, 'property')}
				disabled={saving}>Properties</button
			><button
				type="button"
				aria-pressed={mode === 'rule'}
				onclick={() => load(rules[0] ?? null, 'rule')}
				disabled={saving}>Rules</button
			>
		</nav>
		<div class="catalog-body">
			<aside aria-label="Catalog entries">
				{#each mode === 'property' ? properties : rules as entry}
					<button
						type="button"
						disabled={saving}
						aria-pressed={entry.id === original?.id}
						onclick={() => load(entry)}
						>{String(
							mode === 'rule'
								? ((entry as Row).text ?? entry.id)
								: (entry.label ?? entry.col ?? entry.id)
						)}</button
					>
				{/each}
				<button type="button" onclick={() => load(null)} disabled={saving}>Add {mode}</button>
			</aside>
			<form onsubmit={save} oninput={() => (dirty = true)} onchange={() => (dirty = true)}>
				<fieldset disabled={saving}>
					<label
						>{mode === 'property' ? 'Property ID' : 'Rule ID'}<input
							aria-label={mode === 'property' ? 'Property ID' : 'Rule ID'}
							bind:value={form.key}
							required
							readonly={original !== null}
						/></label
					>
					{#if mode === 'property'}
						<label>Label<input aria-label="Property label" bind:value={form.label} /></label>
						<label
							>Type<select aria-label="Property type" bind:value={form.type}
								>{#each types as type}<option value={type}>{type}</option>{/each}</select
							></label
						>
						<label
							>Description<textarea aria-label="Property description" bind:value={form.description}
							></textarea></label
						>
						<label class="check"
							><input type="checkbox" bind:checked={form.required} />Required</label
						>
						<label class="check"
							><input type="checkbox" bind:checked={form.hasDefault} />Prefill a default</label
						>
						{#if form.hasDefault}<label
								>Default value<input
									aria-label="Default value"
									bind:value={form.defaultValue}
								/></label
							>{/if}
						<label class="check"
							><input type="checkbox" bind:checked={form.immutable} />Set once, then read-only</label
						>
						<label class="check"
							><input type="checkbox" bind:checked={form.deprecated} />Deprecated</label
						>
						{#if ['select', 'multi_select'].includes(form.type)}
							<h3>Options</h3>
							{#each options as option, index}<div class="option">
									<label
										>Value<input
											aria-label={`Option ${index + 1} value`}
											bind:value={option.v}
											required
										/></label
									><label
										>Description<input
											aria-label={`Option ${index + 1} description`}
											bind:value={option.d}
										/></label
									>
									<fieldset class="colors">
										<legend
											><IconPalette size={16} aria-hidden="true" />Color
											<OptionChip
												property={{ options: [option] }}
												value={option.v || 'Preview'}
											/></legend
										>
										{#each [undefined, ...OPTION_COLORS] as color (color ?? 'none')}
											<label
												class="swatch"
												data-color={color}
												title={color ? color[0].toUpperCase() + color.slice(1) : 'No color'}
												><input
													type="radio"
													name={`option-${index}-color`}
													aria-label={`Option ${index + 1} ${color ?? 'no'} color`}
													checked={option.color === color}
													onchange={() => {
														option.color = color;
														dirty = true;
													}}
												/>{#if option.color === color}<IconCheck
														size={14}
														aria-hidden="true"
													/>{/if}</label
											>
										{/each}
									</fieldset>
									<button
										type="button"
										onclick={() => {
											options = options.filter((_, i) => i !== index);
											dirty = true;
										}}>Remove option {index + 1}</button
									>
								</div>{/each}
							<button
								type="button"
								onclick={() => {
									options = [...options, { v: '', d: '', color: newOptionColor(options.length) }];
									dirty = true;
								}}>Add option</button
							>
							<label
								>Additional options query<textarea
									aria-label="Options query"
									bind:value={form.optionsSQL}></textarea></label
							>
						{/if}
						{#if ['ref', 'multi_ref'].includes(form.type)}<label
								>Related table<select aria-label="Related table" bind:value={form.refTable}
									><option value="">Choose table</option>{#each catalog.tables as item}<option
											value={String(item.id)}>{String(item.id)}</option
										>{/each}</select
								></label
							>{/if}
						<details>
							<summary>Validation</summary><label
								>Pattern<input aria-label="Property pattern" bind:value={form.pattern} /></label
							>{#if original?.derived_by}<p>
									Derived by {String(original.derived_by)}. Values remain read-only.
								</p>{/if}
						</details>
					{:else}
						<label
							>Rule guidance<textarea aria-label="Rule guidance" bind:value={form.text} required
							></textarea></label
						>
						<label
							>Kind<select aria-label="Rule kind" bind:value={form.kind}
								><option value="doctrine">Guidance</option><option value="invariant"
									>Invariant</option
								><option value="audit">Audit</option></select
							></label
						>
						<label
							>Scope<select aria-label="Rule scope" bind:value={form.scope}
								><option value="table">This table</option><option value="estate"
									>All tables (audit only)</option
								></select
							></label
						>
						<label
							>Property<select aria-label="Rule property" bind:value={form.ruleColumn}
								><option value="">Whole table</option>{#each properties as p}<option value={p.col}
										>{p.label ?? p.col}</option
									>{/each}</select
							></label
						>
						<label
							>Violation query<textarea
								aria-label="Rule SQL"
								bind:value={form.sql}
								required={form.kind === 'invariant'}></textarea></label
						>
						<p class="hint">
							A SELECT query returns rows that violate the rule. Record invariants can use changed,
							before and now.ts.
						</p>
						<label class="check"
							><input type="checkbox" bind:checked={form.enforce} />Reject record writes that
							violate this invariant</label
						>
					{/if}
					<button type="submit" disabled={saving}>Save {mode}</button>
				</fieldset>
				{#if failure}<p role="alert">{failure}</p>{/if}{#if receipt}<p role="status">
						{receipt}
					</p>{/if}
			</form>
		</div>
	</section>
</dialog>

<style>
	dialog {
		width: min(60rem, 92vw);
		max-height: 90vh;
		padding: 0;
		border: 0;
		border-radius: 0.5rem;
		background: var(--color-paper);
	}
	dialog::backdrop {
		background: rgb(0 0 0 / 0.35);
	}
	.catalog-editor {
		background: var(--color-paper);
		color: var(--color-ink);
		padding: 1.5rem;
		border: 1px solid var(--color-rule);
		border-radius: 0.5rem;
		max-width: 60rem;
		margin: 1rem auto;
	}
	header {
		display: flex;
		justify-content: space-between;
		gap: 1rem;
		align-items: center;
	}
	h2 {
		margin: 0.25rem 0;
	}
	.eyebrow,
	.hint {
		color: var(--color-muted);
		font-size: 0.875rem;
	}
	nav {
		display: flex;
		gap: 0.5rem;
		margin: 1rem 0;
	}
	.catalog-body {
		display: grid;
		grid-template-columns: minmax(8rem, 1fr) minmax(0, 3fr);
		gap: 1.5rem;
	}
	aside {
		display: flex;
		flex-direction: column;
		gap: 0.5rem;
	}
	fieldset {
		border: 0;
		padding: 0;
		display: grid;
		gap: 0.8rem;
	}
	label {
		display: grid;
		gap: 0.25rem;
	}
	.check {
		display: flex;
		gap: 0.5rem;
		align-items: center;
	}
	input:not([type='checkbox']),
	select,
	textarea {
		width: 100%;
		border: 1px solid var(--color-rule);
		padding: 0.5rem;
		border-radius: 0.25rem;
		background: var(--color-paper);
		color: inherit;
	}
	textarea {
		min-height: 5rem;
	}
	button {
		border: 1px solid var(--color-rule);
		padding: 0.5rem 0.75rem;
		border-radius: 0.25rem;
	}
	button[aria-pressed='true'] {
		background: var(--color-bone);
	}
	button:disabled {
		opacity: 0.5;
	}
	.option {
		display: grid;
		gap: 0.5rem;
		padding: 0.75rem;
		border: 1px solid var(--color-rule);
	}
	.colors {
		display: flex;
		flex-wrap: wrap;
		gap: 0.375rem;
	}
	.colors legend {
		display: flex;
		align-items: center;
		gap: 0.375rem;
		margin-bottom: 0.375rem;
	}
	.swatch {
		position: relative;
		display: grid;
		place-items: center;
		width: 1.75rem;
		height: 1.75rem;
		border-radius: 0.375rem;
		color: var(--color-option-ink);
		box-shadow: inset 0 0 0 1px var(--color-rule);
		cursor: pointer;
	}
	.swatch:not([data-color]) {
		color: var(--color-ink);
		background: linear-gradient(
			to top right,
			transparent calc(50% - 1px),
			var(--color-muted) calc(50% - 1px) calc(50% + 1px),
			transparent calc(50% + 1px)
		);
	}
	.swatch input {
		position: absolute;
		inset: 0;
		margin: 0;
		opacity: 0;
		cursor: pointer;
	}
	.swatch:has(input:focus-visible) {
		outline: 2px solid var(--color-accent);
		outline-offset: 2px;
	}
	.swatch[data-color='default'] {
		background: var(--color-option-default);
	}
	.swatch[data-color='gray'] {
		background: var(--color-option-gray);
	}
	.swatch[data-color='brown'] {
		background: var(--color-option-brown);
	}
	.swatch[data-color='orange'] {
		background: var(--color-option-orange);
	}
	.swatch[data-color='yellow'] {
		background: var(--color-option-yellow);
	}
	.swatch[data-color='green'] {
		background: var(--color-option-green);
	}
	.swatch[data-color='blue'] {
		background: var(--color-option-blue);
	}
	.swatch[data-color='purple'] {
		background: var(--color-option-purple);
	}
	.swatch[data-color='pink'] {
		background: var(--color-option-pink);
	}
	.swatch[data-color='red'] {
		background: var(--color-option-red);
	}
	[role='alert'] {
		color: #b42318;
	}
	details label {
		margin-top: 0.5rem;
	}
	@media (max-width: 640px) {
		.catalog-body {
			grid-template-columns: 1fr;
		}
		aside {
			flex-direction: row;
			overflow: auto;
		}
		.catalog-editor {
			padding: 1rem;
		}
		header {
			align-items: start;
		}
	}
</style>
