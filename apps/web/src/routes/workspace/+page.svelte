<script lang="ts">
	import { markdownPatch } from '$lib/record-autosave';
	import { editRevision } from '$lib/record-revision';
	import MarkdownEditor from '$lib/components/MarkdownEditor.svelte';
	import { onDestroy, onMount } from 'svelte';
	import { beforeNavigate } from '$app/navigation';
	import {
		IconDatabase,
		IconPlus,
		IconRefresh,
		IconTrash,
		IconArrowLeft,
		IconSearch,
		IconX,
		IconDeviceFloppy
	} from '@tabler/icons-svelte';
	import {
		createHttpHub,
		displayName,
		isReadOnlyTable,
		type Row,
		type Property,
		type Filter
	} from 'life-ui-core/client';
	import { WorkspaceDatabase } from '$lib/database';
	import SchemaGraph from '$lib/SchemaGraph.svelte';
	import HubServices from '$lib/HubServices.svelte';
	let connectedHub = $state<{ endpoint: string; token: string } | null>(null);

	let database: WorkspaceDatabase | null = null;
	let ready = $state(false),
		online = $state(true);
	onMount(() => {
		ready = true;
		online = navigator.onLine;
	});
	let opened = $state(false),
		demo = $state(false),
		busy = $state(false),
		error = $state('');
	let writing = $state(false);
	let bodySaving = $state(false),
		bodyFailure = $state('');
	let editorVersion = $state(0);
	let catalog = $state<{ tables: Row[]; properties: Property[]; rules: Row[] }>({
		tables: [],
		properties: [],
		rules: []
	});
	let table = $state(''),
		rows = $state<Row[]>([]),
		selected = $state<Row | null>(null),
		editing = $state(false);
	let draft = $state<Record<string, string>>({}),
		search = $state(''),
		trash = $state(false),
		endpoint = $state(''),
		token = $state('');
	let savedDraft = $state('');
	let graphVisible = $state(false),
		groups = $state<Record<string, string>>({});
	$effect(() => {
		if (opened)
			try {
				localStorage.setItem(
					`life-ui:groups:${demo ? 'demo' : 'workspace'}`,
					JSON.stringify(groups)
				);
			} catch {
				notice = 'Table groups could not be saved on this device.';
			}
	});
	const dirty = $derived(editing && JSON.stringify(draft) !== savedDraft);
	const discard = () =>
		!writing && !bodySaving && (!dirty || confirm('Discard unsaved changes to this record?'));
	beforeNavigate((navigation) => {
		if (!discard()) navigation.cancel();
	});
	let lastSync = $state<string | null>(null),
		pendingEdits = $state(0),
		rejected = $state<Row[]>([]),
		notice = $state('');
	let skipped = $state<string[]>([]),
		maxRows = $state(50000),
		included = $state<Record<string, boolean>>({});
	let sort = $state('id'),
		descending = $state(false),
		offset = $state(0);
	let references = $state<Record<string, Row[]>>({}),
		referenceSearch = $state<Record<string, string>>({});
	let optionValues = $state<Record<string, string[]>>({});
	let names = $state<Record<string, string>>({});
	let rowsRequest = 0;
	const referenceRequests: Record<string, number> = {};
	let filterColumn = $state(''),
		filterOp = $state<Filter['op']>('eq'),
		filterValue = $state(''),
		filters = $state<Filter[]>([]);
	const system = new Set(['id', 'created_at', 'updated_at', 'deleted_at', 'hub_at']);
	const properties = $derived(
		catalog.properties
			.filter((p) => p.tbl === table && !system.has(p.col))
			.sort((a, b) => (a.sort ?? 0) - (b.sort ?? 0) || a.col.localeCompare(b.col))
	);
	const filterType = $derived(properties.find((p) => p.col === filterColumn)?.type ?? 'text');
	const current = $derived(catalog.tables.find((t) => t.id === table));
	const display = $derived(typeof current?.display === 'string' ? current.display : null);
	const rules = $derived(catalog.rules.filter((r) => r.tbl === table || r.scope === 'estate'));
	const readOnly = $derived(isReadOnlyTable(table, current));
	const blocked = $derived(rules.some((r) => r.kind === 'invariant' && r.enforce));
	const draftProperties = $derived(properties.filter((p) => Object.hasOwn(draft, p.col)));
	const bodyPatch = $derived(markdownPatch(properties, draft, selected));
	const bodySaveKey = $derived(JSON.stringify([editorVersion, bodyPatch]));
	$effect(() => {
		if (
			!editing ||
			!bodyPatch ||
			busy ||
			readOnly ||
			blocked ||
			trash ||
			bodyFailure === bodySaveKey
		)
			return;
		const patch = bodyPatch,
			key = bodySaveKey;
		const timer = setTimeout(() => void saveBody(patch, key), 600);
		return () => clearTimeout(timer);
	});
	async function saveBody(patch: Row, key: string) {
		if (!database || !selected || !editing || busy || key !== bodySaveKey) return;
		const workspace = database,
			version = editorVersion,
			target = table;
		bodySaving = true;
		busy = true;
		try {
			const stored = await workspace.request('write', {
				table: target,
				patch,
				expectedUpdatedAt: editRevision(selected)
			});
			if (database !== workspace || editorVersion !== version || table !== target) return;
			selected = stored;
			// Keep the live draft: typing may have continued while the write was pending.
			const acknowledged = rowDraft(stored);
			savedDraft = JSON.stringify(
				Object.fromEntries(Object.keys(draft).map((column) => [column, acknowledged[column] ?? '']))
			);
			bodyFailure = '';
			error = '';
			await refresh();
		} catch (e) {
			if (database === workspace && editorVersion === version) {
				bodyFailure = key;
				error = message(e);
			}
		} finally {
			if (database === workspace) {
				bodySaving = false;
				busy = false;
			}
		}
	}
	const label = (p: Property) =>
		p.label || p.col.charAt(0).toUpperCase() + p.col.slice(1).replaceAll('_', ' ');
	const tableName = (t: Row) => String(t.id);
	const title = (row: Row) => displayName(row, display);
	const locked = (p: Property) =>
		writing ||
		!!p.derived_by ||
		!!p.deprecated ||
		!!(selected && p.immutable) ||
		readOnly ||
		blocked;
	const list = (value: string) => {
		try {
			const parsed = JSON.parse(value || '[]');
			return Array.isArray(parsed) ? parsed.map(String) : [];
		} catch {
			return [] as string[];
		}
	};
	const choices = (p: Property) => [
		...new Set([
			...(optionValues[p.col] ?? (p.options ?? []).map((o) => o.v)),
			...(p.type === 'multi_select' ? list(draft[p.col]) : [draft[p.col]].filter(Boolean))
		])
	];
	const choiceLabel = (p: Property, value: string) => {
		const description = p.options?.find((o) => o.v === value)?.d;
		return description ? `${value} - ${description}` : value;
	};
	async function loadOptions(p: Property) {
		const workspace = database,
			version = editorVersion,
			target = table;
		if (!workspace) return;
		try {
			const values: string[] = await workspace.request('options', { table: target, column: p.col });
			if (database === workspace && editorVersion === version && table === target)
				optionValues[p.col] = values;
		} catch (e) {
			if (database === workspace && editorVersion === version) error = message(e);
		}
	}
	const refTitle = (p: Property, row: Row) =>
		displayName(row, catalog.tables.find((t) => t.id === p.ref_table)?.display as string | null);
	const cell = (p: Property, value: unknown): string => {
		if (value == null) return '';
		if (p.type === 'bool') return value ? 'Yes' : 'No';
		if (p.type === 'ref') return names[JSON.stringify([p.ref_table, value])] ?? String(value);
		if (p.type === 'multi_ref')
			return list(String(value))
				.map((id) => names[JSON.stringify([p.ref_table, id])] ?? id)
				.join(', ');
		if (p.type === 'multi_select') return list(String(value)).join(', ');
		return String(value);
	};
	async function loadReferences(p: Property, query = '') {
		if (!database || !p.ref_table) return;
		const workspace = database,
			version = editorVersion;
		const request = (referenceRequests[p.col] = (referenceRequests[p.col] ?? 0) + 1);
		try {
			const found: Row[] = await workspace.request('rows', {
				view: { table: p.ref_table, search: query, limit: 50 }
			});
			if (database !== workspace || editorVersion !== version) return;
			const ids = p.type === 'multi_ref' ? list(draft[p.col]) : [draft[p.col]];
			for (const id of ids.filter(Boolean))
				if (!found.some((r) => r.id === id))
					found.push(
						...(await workspace.request('rows', {
							view: {
								table: p.ref_table,
								filters: [{ column: 'id', op: 'eq', value: id }],
								limit: 1
							}
						}))
					);
			if (
				database === workspace &&
				editorVersion === version &&
				request === referenceRequests[p.col]
			)
				references[p.col] = found;
		} catch (e) {
			if (database === workspace && editorVersion === version) error = message(e);
		}
	}
	function message(e: unknown) {
		return e instanceof Error ? e.message : 'The operation failed. Your saved data is unchanged.';
	}
	function rejectionText(row: Row) {
		const errors = Array.isArray(row.errors) ? row.errors : [row.errors ?? row.message];
		return errors
			.map((e: unknown) =>
				e && typeof e === 'object'
					? String((e as Row).message ?? (e as Row).error ?? (e as Row).rule ?? 'Edit rejected')
					: String(e ?? 'Edit rejected')
			)
			.join('\n');
	}
	async function reviewRejected(row: Row) {
		if (!database || !discard()) return;
		editing = false;
		await changeTable(String(row.tbl));
		try {
			let found: Row[] = await database.request('rows', {
				view: { table, filters: [{ column: 'id', op: 'eq', value: String(row.row_id) }], limit: 1 }
			});
			if (!found.length)
				found = await database.request('rows', {
					view: {
						table,
						trash: true,
						filters: [{ column: 'id', op: 'eq', value: String(row.row_id) }],
						limit: 1
					}
				});
			if (!found[0])
				throw new Error(
					'This record is not available locally. Include its table and sync before repairing the edit.'
				);
			trash = !!found[0].deleted_at;
			edit(found[0]);
			if (row.row && typeof row.row === 'object')
				for (const p of properties.filter((p) => !locked(p))) {
					const value = (row.row as Row)[p.col];
					draft[p.col] =
						value == null ? '' : typeof value === 'string' ? value : JSON.stringify(value);
				}
			notice = 'Review the rejected values, save your correction, then sync.';
		} catch (e) {
			error = message(e);
		}
	}
	async function loadRows() {
		if (!database || !table) return;
		const workspace = database;
		const request = ++rowsRequest;
		const found: Row[] = await workspace.request('rows', {
			view: {
				table,
				search,
				trash,
				filters: $state.snapshot(filters),
				sort: [{ column: sort, direction: descending ? 'desc' : 'asc' }],
				limit: 50,
				offset
			}
		});
		if (database !== workspace || request !== rowsRequest) return;
		rows = found;
		names = {};
		const labels: Record<string, string> = {};
		// ponytail: at most 200 visible references per page; batch SQL when larger grids need it.
		const targets = new Map<string, Property>();
		for (const p of properties
			.filter((p) => p.type === 'ref' || p.type === 'multi_ref')
			.slice(0, 4))
			for (const row of found) {
				for (const id of p.type === 'multi_ref' ? list(String(row[p.col] ?? '[]')) : [row[p.col]])
					if (id && targets.size < 200) targets.set(JSON.stringify([p.ref_table, id]), p);
			}
		await Promise.all(
			[...targets].map(async ([key, p]) => {
				const [target, id] = JSON.parse(key);
				const matches: Row[] = await workspace.request('rows', {
					view: { table: target, filters: [{ column: 'id', op: 'eq', value: id }], limit: 1 }
				});
				if (matches[0]) labels[key] = refTitle(p, matches[0]);
			})
		);
		if (database === workspace && request === rowsRequest) names = labels;
	}
	async function refresh() {
		if (!database) return;
		const workspace = database;
		const state = await workspace.request('snapshot');
		if (database !== workspace) return;
		catalog = state.catalog;
		lastSync = state.lastSync ?? null;
		pendingEdits = state.status.pendingUiEdits;
		rejected = state.rejected ?? [];
		skipped = state.skipped ?? [];
		if (!table && catalog.tables.length)
			table = tableName(
				catalog.tables.find((t) => !/^catalog_|^history$|^provenance$/.test(tableName(t))) ??
					catalog.tables[0]
			);
		await loadRows();
	}
	function resetView() {
		editorVersion++;
		rowsRequest++;
		editing = false;
		selected = null;
		draft = {};
		savedDraft = '';
		bodyFailure = '';
		rows = [];
		names = {};
		references = {};
		referenceSearch = {};
		optionValues = {};
		search = '';
		trash = false;
		offset = 0;
		sort = 'id';
		descending = false;
		filters = [];
		filterColumn = '';
		filterOp = 'eq';
		filterValue = '';
		error = '';
		notice = '';
	}
	async function openWorkspace(sample: boolean) {
		if (busy) return;
		busy = true;
		connectedHub = null;
		resetView();
		try {
			database?.close();
			database = new WorkspaceDatabase();
			await database.request('open', { demo: sample });
			demo = sample;
			try {
				const prefs = JSON.parse(localStorage.getItem('life-ui:replica') ?? '{}');
				maxRows = Number.isSafeInteger(prefs.maxRows) && prefs.maxRows >= 0 ? prefs.maxRows : 50000;
				included =
					prefs.tables && typeof prefs.tables === 'object' && !Array.isArray(prefs.tables)
						? (Object.fromEntries(
								Object.entries(prefs.tables).filter(([, v]) => typeof v === 'boolean')
							) as Record<string, boolean>)
						: {};
			} catch {
				maxRows = 50000;
				included = {};
			}
			graphVisible = false;
			try {
				const saved = JSON.parse(
					localStorage.getItem(`life-ui:groups:${sample ? 'demo' : 'workspace'}`) ?? '{}'
				);
				groups =
					saved && typeof saved === 'object' && !Array.isArray(saved)
						? (Object.fromEntries(
								Object.entries(saved).filter(([, v]) => typeof v === 'string')
							) as Record<string, string>)
						: {};
			} catch {
				groups = {};
			}
			table = '';
			opened = true;
			editing = false;
			await refresh();
			database.addEventListener('change', () => {
				void refresh().catch((e) => (error = message(e)));
			});
		} catch (e) {
			error = message(e);
			opened = false;
		} finally {
			busy = false;
		}
	}
	async function changeTable(name: string) {
		if (!discard()) return;
		resetView();
		graphVisible = false;
		table = name;
		await loadRows().catch((e) => (error = message(e)));
	}
	async function applyFilter() {
		filters = filterColumn
			? [
					{
						column: filterColumn,
						op: filterOp,
						...(['empty', 'not_empty'].includes(filterOp)
							? {}
							: {
									value: ['number', 'int', 'bool'].includes(filterType)
										? Number(filterValue)
										: filterValue
								})
					}
				]
			: [];
		await find();
	}
	function edit(row: Row | null) {
		if (!discard()) return;
		editorVersion++;
		selected = row;
		bodyFailure = '';
		draft = rowDraft(row);
		references = {};
		referenceSearch = {};
		optionValues = {};
		error = '';
		editing = true;
		savedDraft = JSON.stringify(draft);
		for (const p of properties.filter((p) => p.type === 'ref' || p.type === 'multi_ref'))
			void loadReferences(p);
		for (const p of properties.filter((p) => p.type === 'select' || p.type === 'multi_select'))
			void loadOptions(p);
	}
	function rowDraft(row: Row | null) {
		const values: Record<string, string> = {};
		for (const p of properties) {
			const value =
				row?.[p.col] ?? (!row && !p.default_value?.startsWith('sql:') ? p.default_value : null);
			values[p.col] =
				value == null ? '' : typeof value === 'string' ? value : JSON.stringify(value);
		}
		return values;
	}
	async function save() {
		if (!database || busy || !editing) return;
		const workspace = database,
			version = editorVersion,
			target = table;
		writing = true;
		busy = true;
		error = '';
		try {
			const patch: Row = selected ? { id: selected.id } : {};
			for (const p of draftProperties) {
				if (p.derived_by || p.deprecated || (selected && p.immutable)) continue;
				const value = draft[p.col] ?? '';
				if (
					selected &&
					value ===
						(selected[p.col] == null
							? ''
							: typeof selected[p.col] === 'string'
								? selected[p.col]
								: JSON.stringify(selected[p.col]))
				)
					continue;
				if (!selected && value === '') continue;
				patch[p.col] =
					value === ''
						? null
						: ['number', 'int', 'bool'].includes(p.type ?? '')
							? Number(value)
							: value;
			}
			const stored: Row = await workspace.request('write', {
				table: target,
				patch,
				...(selected ? { expectedUpdatedAt: editRevision(selected) } : {})
			});
			if (database !== workspace || editorVersion !== version || table !== target) return;
			selected = stored;
			draft = rowDraft(stored);
			savedDraft = JSON.stringify(draft);
			bodyFailure = '';
			notice = 'Saved on this device';
			await refresh();
		} catch (e) {
			if (database === workspace && editorVersion === version) error = message(e);
		} finally {
			if (database === workspace) {
				writing = false;
				busy = false;
			}
		}
	}
	async function toggleTrash() {
		if (!database || !selected || busy) return;
		if (!discard()) return;
		const workspace = database,
			version = editorVersion,
			target = table;
		writing = true;
		busy = true;
		error = '';
		try {
			await workspace.request('write', {
				table: target,
				patch: { id: selected.id, deleted_at: trash ? null : true },
				expectedUpdatedAt: editRevision(selected)
			});
			if (database !== workspace || editorVersion !== version || table !== target) return;
			editorVersion++;
			editing = false;
			selected = null;
			notice = trash ? 'Record restored' : 'Moved to trash';
			await refresh();
		} catch (e) {
			if (database === workspace && editorVersion === version) error = message(e);
		} finally {
			if (database === workspace) {
				writing = false;
				busy = false;
			}
		}
	}
	async function syncNow() {
		if (!database || busy) return;
		const workspace = database;
		let connection: { endpoint: string; token: string } | null = null;
		busy = true;
		error = '';
		notice = 'Syncing';
		try {
			// A rejected endpoint switch must not change the service connection.
			const hub = createHttpHub(endpoint, token, fetch);
			connection = { endpoint: hub.endpoint, token };
			const result = await workspace.request('sync', {
				...connection,
				maxRows,
				tables: $state.snapshot(included)
			});
			if (database !== workspace) return;
			connectedHub = connection;
			try {
				localStorage.setItem('life-ui:replica', JSON.stringify({ maxRows, tables: included }));
			} catch {
				/* Sync remains valid when preference persistence is unavailable. */
			}
			notice = result.rejected.length
				? 'Some edits need attention'
				: `Synced: ${result.pulled} received, ${result.pushed} sent`;
			await refresh();
		} catch (e) {
			if (database !== workspace) return;
			// The core checks replica identity before HTTP. A cap must still let
			// this deployment's usage and notifications explain the paused sync.
			if (connection && message(e) === 'hub HTTP 429') connectedHub = connection;
			error = message(e);
			notice = 'Sync did not finish. Local records remain available.';
		} finally {
			busy = false;
		}
	}
	async function find() {
		offset = 0;
		try {
			await loadRows();
		} catch (e) {
			error = message(e);
		}
	}
	onDestroy(() => {
		editorVersion++;
		database?.close();
		database = null;
	});
</script>

<svelte:head><title>Workspace | Life UI</title></svelte:head>
<svelte:window
	ononline={() => (online = true)}
	onoffline={() => (online = false)}
	onbeforeunload={(e) => {
		if (dirty || writing || bodySaving) {
			e.preventDefault();
			e.returnValue = '';
		}
	}}
/>

{#if !opened}
	<main class="start">
		<a class="back" href="/"><IconArrowLeft size={18} /> Life UI</a>
		<h1>Your data, within reach.</h1>
		<p>Open a workspace on this device. Your records stay available between sessions.</p>
		<div class="start-actions">
			<button onclick={() => openWorkspace(false)} disabled={busy || !ready}
				>Open my workspace</button
			><button class="secondary" onclick={() => openWorkspace(true)} disabled={busy || !ready}
				>Try sample workspace</button
			>
		</div>
		<p class="hint">
			The sample is a separate, editable workspace. It never connects to your account.
		</p>
		{#if error}<p role="alert" class="failure">{error}</p>{/if}
	</main>
{:else}
	<fieldset class="workspace-controls" disabled={writing} aria-label="Workspace controls">
		<div class="data-shell">
			<aside class="tables">
				<a
					class="wordmark"
					href="/"
					aria-disabled={writing}
					onclick={(event) => {
						if (writing) event.preventDefault();
					}}><IconDatabase size={22} /> Life UI</a
				>
				<div class="workspace-label">
					{demo ? 'Sample workspace' : 'My workspace'}<span
						>{demo ? 'Example data' : 'Stored on this device'}</span
					>
				</div>
				<nav aria-label="Tables">
					{#each catalog.tables as t (t.id)}<button
							class:active={tableName(t) === table}
							onclick={() => changeTable(tableName(t))}
							><IconDatabase size={16} />{tableName(t)}</button
						>{/each}
				</nav>
				<button
					class="secondary"
					onclick={() => {
						if (discard()) {
							editing = false;
							graphVisible = !graphVisible;
						}
					}}>{graphVisible ? 'Records' : 'Table graph'}</button
				>
				<div class="sync-state" aria-live="polite">
					<span class="dot"></span>{busy ? 'Working' : notice || 'Local workspace'}<small
						>{lastSync
							? `Last sync ${new Date(lastSync).toLocaleString()}`
							: 'No sync completed yet'}</small
					>
					<small>Pending edits: {pendingEdits}</small>
				</div>
				{#if !demo}
					{#key connectedHub}<HubServices connection={connectedHub} />{/key}
					<details class="connect">
						<summary>Connect to a hub</summary><label for="endpoint">Hub address</label><input
							id="endpoint"
							type="url"
							bind:value={endpoint}
							placeholder="https://your-hub.example"
						/><label for="token">Device token</label><input
							id="token"
							type="password"
							bind:value={token}
							autocomplete="off"
						/>
						<p class="hint">Use your scoped device token. It stays in memory for this session.</p>
						<label for="max-rows">Automatic sync row limit</label><input
							id="max-rows"
							type="number"
							min="0"
							step="1"
							bind:value={maxRows}
						/>
						<p class="hint">
							Larger tables stay out of automatic sync. Catalogs always sync. Local rows are
							retained.
						</p>
						<button onclick={syncNow} disabled={busy || !endpoint || !token}
							><IconRefresh size={16} /> Sync now</button
						>
					</details>
				{/if}
				<p class="hint">{online ? 'Network available' : 'Device offline - edits stay here'}</p>
				<button
					class="secondary leave"
					onclick={() => {
						if (!discard()) return;
						database?.close();
						database = null;
						opened = false;
						resetView();
						token = '';
					}}>Switch workspace</button
				>
			</aside>
			<main class="records">
				{#if graphVisible}<SchemaGraph
						tables={catalog.tables}
						properties={catalog.properties}
						bind:groups
						onSelect={changeTable}
					/>{:else}
					{#if skipped.includes(table)}<div class="notice">
							<p>This table is excluded from sync. Its local records may be incomplete.</p>
							<button
								class="secondary"
								onclick={() => {
									included = { ...included, [table]: true };
									notice = 'Table included. Sync now to download its records.';
								}}>Include this table</button
							>
						</div>{/if}
					{#if included[table]}<button
							class="secondary"
							onclick={() => {
								const next = { ...included };
								delete next[table];
								included = next;
								notice = 'Automatic size rule restored. Sync to apply it.';
							}}>Use automatic size rule</button
						>{/if}
					<header class="records-heading">
						<div>
							<p class="eyebrow">{demo ? 'Sample data' : 'Workspace'} / Table</p>
							<h1>{table || 'Welcome'}</h1>
							<p class="purpose">
								{String(current?.purpose ?? 'Browse your records and keep their rules in view.')}
							</p>
						</div>
						<button onclick={() => edit(null)} disabled={busy || !table || readOnly || blocked}
							><IconPlus size={17} />New record</button
						>
					</header>
					{#if !table}<div class="empty">
							Connect to your hub in the sidebar and sync to bring your tables to this device.
						</div>{/if}
					{#if table}
						<div class="toolbar">
							<form
								onsubmit={(e) => {
									e.preventDefault();
									find();
								}}
								class="search"
							>
								<IconSearch size={17} /><input
									aria-label="Search records"
									placeholder="Search records"
									bind:value={search}
									oninput={find}
								/>
							</form>
							<button
								class="secondary"
								onclick={() => {
									if (!discard()) return;
									trash = !trash;
									offset = 0;
									editing = false;
									loadRows().catch((e) => (error = message(e)));
								}}><IconTrash size={16} />{trash ? 'All records' : 'Trash'}</button
							>
							<select aria-label="Sort by" bind:value={sort} onchange={find}
								><option value="id">Sort by ID</option>{#each properties as p}<option value={p.col}
										>Sort by {label(p)}</option
									>{/each}</select
							>
							<button
								class="secondary"
								onclick={() => {
									descending = !descending;
									find();
								}}>{descending ? 'Descending' : 'Ascending'}</button
							>
						</div>
						<form
							class="filters"
							onsubmit={(e) => {
								e.preventDefault();
								applyFilter();
							}}
						>
							<select
								aria-label="Filter property"
								bind:value={filterColumn}
								onchange={() => {
									filterOp = 'eq';
									filterValue = '';
								}}
								><option value="">All records</option>{#each properties as p}<option value={p.col}
										>{label(p)}</option
									>{/each}</select
							>
							{#if filterColumn}<select aria-label="Filter operator" bind:value={filterOp}
									><option value="eq">is</option><option value="ne">is not</option><option
										value="empty">is empty</option
									><option value="not_empty">is not empty</option
									>{#if ['number', 'int', 'date', 'datetime'].includes(filterType)}<option
											value="gt">greater than</option
										><option value="lt">less than</option>{:else}<option value="contains"
											>contains</option
										>{/if}</select
								>
								{#if !['empty', 'not_empty'].includes(filterOp)}<input
										aria-label="Filter value"
										bind:value={filterValue}
									/>{/if}{/if}
							<button class="secondary" type="submit">Apply filter</button>
						</form>
						{#if blocked}<p class="notice">
								This table has enforced cross-record rules. It is read-only here until the local
								rule engine is connected.
							</p>{/if}
						{#if error}<p role="alert" class="failure">{error}</p>{/if}
						{#if rejected.length}<details class="rejections">
								<summary>{rejected.length} rejected edits need attention</summary
								>{#each rejected as r}<p>
										{String(r.tbl ?? r.table)} / {String(r.row_id ?? r.id)}: {rejectionText(r)}
									</p>
									<button class="secondary" onclick={() => reviewRejected(r)}
										>Review rejected edit</button
									>{/each}
							</details>{/if}
						<div class="table-scroll">
							<table>
								<thead
									><tr
										><th scope="col">Record</th>{#each properties
											.filter((p) => p.col !== display && p.type !== 'markdown')
											.slice(0, 4) as p}<th scope="col">{label(p)}</th>{/each}</tr
									></thead
								><tbody>
									{#each rows as row (row.id)}<tr
											class:selected={selected?.id === row.id && editing}
											><td
												><button class="record-link" onclick={() => edit(row)}>{title(row)}</button
												></td
											>{#each properties
												.filter((p) => p.col !== display && p.type !== 'markdown')
												.slice(0, 4) as p}<td>{cell(p, row[p.col])}</td>{/each}</tr
										>{/each}
								</tbody>
							</table>
						</div>
						{#if rows.length === 0}<div class="empty">
								{trash
									? 'Nothing in the trash.'
									: search
										? 'No matching records.'
										: 'No records yet. Create one to get started.'}
							</div>{/if}
						<footer class="pagination">
							<span>{rows.length} {rows.length === 1 ? 'record' : 'records'} shown</span><button
								class="secondary"
								disabled={offset === 0}
								onclick={() => {
									offset = Math.max(0, offset - 50);
									loadRows();
								}}>Previous</button
							><button
								class="secondary"
								disabled={rows.length < 50}
								onclick={() => {
									offset += 50;
									loadRows();
								}}>Next</button
							>
						</footer>
					{/if}
				{/if}
			</main>
			{#if editing}
				<aside class="record-panel" aria-label="Record editor">
					<header>
						<div>
							<p class="eyebrow">
								{selected ? 'Edit record' : 'New record'} / {dirty || !selected
									? 'Unsaved changes'
									: 'Saved'}
							</p>
							<h2>{selected ? title(selected) : 'Untitled'}</h2>
						</div>
						<button
							class="icon-button secondary"
							aria-label="Close record"
							onclick={() => {
								if (discard()) {
									editing = false;
									editorVersion++;
								}
							}}><IconX size={18} /></button
						>
					</header>
					{#if draftProperties.some((p) => p.type === 'markdown')}
						<p role="status" aria-label="Body save status" class="hint">
							{bodySaving
								? 'Saving body…'
								: !selected
									? 'Save record to start body autosave'
									: bodyPatch
										? bodyFailure === bodySaveKey
											? 'Body not saved. Your draft is kept.'
											: 'Body changes pending'
										: 'Body saved on this device'}
						</p>
					{/if}
					{#if draftProperties.length !== properties.length}
						<p class="hint">Properties changed. Reopen this record to edit newly added fields.</p>
					{/if}
					<form
						onsubmit={(e) => {
							e.preventDefault();
							save();
						}}
						novalidate
					>
						{#each draftProperties as p (p.col)}
							<div class="field">
								<label for={`field-${p.col}`}
									>{label(p)}{#if p.required}<span class="required" aria-hidden="true"
											>Required</span
										>{/if}</label
								>
								{#if p.type === 'ref' || p.type === 'multi_ref'}
									<input
										aria-label={`Search ${label(p)}`}
										placeholder="Search related records"
										bind:value={referenceSearch[p.col]}
										oninput={() => loadReferences(p, referenceSearch[p.col])}
										disabled={locked(p)}
									/>
									{#if p.type === 'ref'}<select
											id={`field-${p.col}`}
											aria-required={!!p.required}
											bind:value={draft[p.col]}
											disabled={locked(p)}
											><option value="">No related record</option
											>{#if draft[p.col] && !(references[p.col] ?? []).some((r) => r.id === draft[p.col])}<option
													value={draft[p.col]}>{draft[p.col]} (not available locally)</option
												>{/if}{#each references[p.col] ?? [] as r}<option value={String(r.id)}
													>{refTitle(p, r)}</option
												>{/each}</select
										>
									{:else}<select
											id={`field-${p.col}`}
											value=""
											disabled={locked(p)}
											onchange={(e) => {
												const id = e.currentTarget.value;
												if (id)
													draft[p.col] = JSON.stringify([...new Set([...list(draft[p.col]), id])]);
												e.currentTarget.value = '';
											}}
											><option value="">Add related record</option
											>{#each references[p.col] ?? [] as r}<option value={String(r.id)}
													>{refTitle(p, r)}</option
												>{/each}</select
										>
										<div class="chips">
											{#each list(draft[p.col]) as id}<button
													type="button"
													class="secondary"
													disabled={locked(p)}
													aria-label={`Remove ${refTitle(p, (references[p.col] ?? []).find((r) => r.id === id) ?? { id })}`}
													onclick={() =>
														(draft[p.col] = JSON.stringify(
															list(draft[p.col]).filter((x) => x !== id)
														))}
													>{refTitle(
														p,
														(references[p.col] ?? []).find((r) => r.id === id) ?? { id }
													)}<IconX size={14} /></button
												>{/each}
										</div>{/if}
								{:else if p.type === 'multi_select'}<select
										id={`field-${p.col}`}
										multiple
										value={list(draft[p.col])}
										disabled={locked(p)}
										onchange={(e) =>
											(draft[p.col] = JSON.stringify(
												[...e.currentTarget.selectedOptions].map((o) => o.value)
											))}
										>{#each choices(p) as value}<option {value}>{choiceLabel(p, value)}</option
											>{/each}</select
									>
								{:else if p.type === 'markdown'}
									{#key editorVersion}
										<MarkdownEditor
											id={`field-${p.col}`}
											label={label(p)}
											bind:value={draft[p.col]}
											disabled={locked(p)}
										/>
									{/key}
								{:else if p.type === 'json'}
									<textarea
										id={`field-${p.col}`}
										aria-required={!!p.required}
										rows={4}
										bind:value={draft[p.col]}
										disabled={locked(p)}></textarea>
								{:else if p.type === 'select'}<select
										id={`field-${p.col}`}
										aria-required={!!p.required}
										bind:value={draft[p.col]}
										disabled={locked(p)}
										><option value="">Choose an option</option>{#each choices(p) as value}<option
												{value}>{choiceLabel(p, value)}</option
											>{/each}</select
									>
								{:else if p.type === 'bool'}<select
										id={`field-${p.col}`}
										aria-required={!!p.required}
										bind:value={draft[p.col]}
										disabled={locked(p)}
										><option value="">Empty</option><option value="1">Yes</option><option value="0"
											>No</option
										></select
									>
								{:else}<input
										id={`field-${p.col}`}
										aria-required={!!p.required}
										type={p.type === 'date'
											? 'date'
											: p.type === 'number' || p.type === 'int'
												? 'number'
												: 'text'}
										step={p.type === 'int' ? '1' : 'any'}
										bind:value={draft[p.col]}
										disabled={locked(p)}
									/>{/if}
								<p class="field-note">
									{p.description || p.type}{p.derived_by
										? ' / Filled automatically'
										: ''}{p.immutable ? ' / Set once' : ''}{p.type === 'markdown'
										? ' / Markdown'
										: ''}
								</p>
							</div>
						{/each}
						{#if error}<p role="status" class="failure">{error}</p>{/if}
						<div class="editor-actions">
							<button type="submit" disabled={busy || readOnly || blocked || trash}
								><IconDeviceFloppy size={17} />Save record</button
							>{#if selected}<button
									type="button"
									class="secondary"
									onclick={toggleTrash}
									disabled={busy || readOnly || blocked}
									>{trash ? 'Restore record' : 'Move to trash'}</button
								>{/if}
						</div>
					</form>
					{#if rules.length}<div class="rules">
							<h3>Rules in force</h3>
							{#each rules as rule}<p>{String(rule.text ?? rule.id)}</p>{/each}
						</div>{/if}
				</aside>
			{/if}
		</div>
	</fieldset>
{/if}

<style>
	.workspace-controls {
		display: contents;
	}
	button,
	select,
	input,
	textarea {
		font: inherit;
	}
	button {
		display: inline-flex;
		gap: 7px;
		align-items: center;
		justify-content: center;
		min-height: 38px;
		border: 1px solid transparent;
		border-radius: 6px;
		background: var(--color-accent);
		color: var(--color-on-accent);
		padding: 8px 13px;
		cursor: pointer;
		font-size: 13px;
		font-weight: 600;
	}
	button:disabled {
		opacity: 0.45;
		cursor: default;
	}
	.secondary {
		color: var(--color-ink);
		background: var(--color-paper);
		border-color: var(--color-rule);
	}
	.start {
		max-width: 720px;
		margin: 12vh auto;
		padding: 24px;
	}
	.start h1 {
		font-size: clamp(32px, 5vw, 48px);
		letter-spacing: -1.7px;
		line-height: 1.1;
		margin: 42px 0 18px;
	}
	.start p {
		color: var(--color-muted);
		line-height: 1.7;
	}
	.back,
	.wordmark {
		display: flex;
		align-items: center;
		gap: 9px;
		text-decoration: none;
		font-weight: 650;
	}
	.start-actions {
		display: flex;
		gap: 12px;
		flex-wrap: wrap;
		margin: 30px 0 20px;
	}
	.hint {
		font-size: 12px;
	}
	.data-shell {
		display: grid;
		grid-template-columns: 224px minmax(0, 1fr);
		min-height: 100svh;
	}
	.tables {
		background: var(--color-paper);
		border-right: 1px solid var(--color-rule);
		padding: 24px 16px;
		display: flex;
		flex-direction: column;
		gap: 26px;
	}
	.wordmark {
		font-size: 20px;
		padding: 0 8px;
	}
	.wordmark :global(svg) {
		color: var(--color-accent);
	}
	.workspace-label {
		font-size: 13px;
		padding: 0 8px;
		font-weight: 600;
	}
	.workspace-label span {
		display: block;
		font-size: 11px;
		color: var(--color-muted);
		font-weight: 400;
		margin-top: 5px;
	}
	nav {
		display: grid;
		gap: 3px;
		max-height: 50vh;
		overflow: auto;
	}
	nav button {
		justify-content: start;
		background: none;
		color: var(--color-muted);
		font-weight: 500;
		overflow-wrap: anywhere;
		text-align: left;
	}
	nav button.active {
		color: var(--color-accent);
		background: var(--color-accent-soft);
	}
	.sync-state {
		margin-top: auto;
		font-size: 12px;
		line-height: 1.6;
		color: var(--color-muted);
		padding: 0 8px;
	}
	.dot {
		display: inline-block;
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: var(--color-valid);
		margin-right: 7px;
	}
	.sync-state small {
		display: block;
		margin-top: 4px;
		font-size: 11px;
	}
	.connect {
		font-size: 12px;
	}
	.connect label {
		display: block;
		margin: 12px 0 4px;
	}
	.connect input {
		width: 100%;
	}
	.connect summary {
		cursor: pointer;
	}
	.leave {
		width: 100%;
	}
	.records {
		min-width: 0;
		padding: 32px;
	}
	.records-heading {
		display: flex;
		justify-content: space-between;
		gap: 20px;
		align-items: center;
		padding-bottom: 24px;
	}
	.eyebrow {
		color: var(--color-muted);
		font-size: 12px;
		margin: 0 0 10px;
	}
	h1 {
		font-size: 32px;
		letter-spacing: -1px;
		margin: 0 0 8px;
	}
	h2 {
		font-size: 22px;
		margin: 0;
		overflow-wrap: anywhere;
	}
	.purpose {
		font-size: 13px;
		color: var(--color-muted);
		margin: 0;
		max-width: 520px;
		line-height: 1.6;
	}
	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		margin-top: 8px;
	}
	.filters {
		display: flex;
		gap: 8px;
		flex-wrap: wrap;
		margin: 0 0 20px;
	}
	.filters input {
		max-width: 220px;
	}
	.toolbar {
		display: flex;
		gap: 8px;
		align-items: center;
		flex-wrap: wrap;
		margin: 0 0 20px;
	}
	.search {
		display: flex;
		align-items: center;
		gap: 8px;
		flex: 1;
		min-width: 180px;
		background: var(--color-paper);
		border: 1px solid var(--color-rule);
		border-radius: 6px;
		padding-left: 10px;
		color: var(--color-muted);
	}
	.search input {
		border: 0;
		min-width: 0;
		width: 100%;
		background: none;
	}
	input,
	textarea,
	select {
		border: 1px solid var(--color-rule);
		border-radius: 6px;
		padding: 9px 10px;
		background: var(--color-paper);
		color: var(--color-ink);
		font-size: 13px;
		min-height: 38px;
	}
	textarea {
		resize: vertical;
		line-height: 1.7;
	}
	select {
		max-width: 100%;
	}
	.table-scroll {
		overflow: auto;
		border: 1px solid var(--color-rule);
		border-radius: 8px;
		background: var(--color-paper);
	}
	table {
		border-collapse: collapse;
		width: 100%;
		font-size: 13px;
	}
	th {
		text-align: left;
		font-weight: 500;
		color: var(--color-muted);
		background: var(--color-bone);
		font-size: 12px;
	}
	td,
	th {
		padding: 12px 15px;
		border-bottom: 1px solid var(--color-rule);
		white-space: nowrap;
	}
	tbody tr:last-child td {
		border-bottom: 0;
	}
	td {
		max-width: 300px;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	tr.selected {
		background: var(--color-accent-soft);
	}
	.record-link {
		padding: 0;
		min-height: 28px;
		background: none;
		color: var(--color-ink);
		font-weight: 550;
		justify-content: start;
	}
	.record-link:hover {
		color: var(--color-accent);
	}
	.empty {
		padding: 60px 24px;
		text-align: center;
		color: var(--color-muted);
		font-size: 14px;
	}
	.pagination {
		display: flex;
		align-items: center;
		justify-content: end;
		gap: 8px;
		margin-top: 16px;
		font-size: 12px;
		color: var(--color-muted);
	}
	.pagination span {
		margin-right: auto;
	}
	.failure {
		padding: 13px 16px;
		background: color-mix(in srgb, var(--color-violation) 9%, var(--color-paper));
		color: var(--color-violation);
		font-size: 13px;
		border-radius: 6px;
		white-space: pre-line;
		overflow-wrap: anywhere;
	}
	.notice,
	.rejections {
		font-size: 13px;
		padding: 12px;
		background: var(--color-accent-soft);
		border-radius: 6px;
		margin-bottom: 16px;
	}
	.record-panel {
		position: fixed;
		right: 0;
		top: 0;
		bottom: 0;
		width: min(470px, 100vw);
		overflow: auto;
		background: var(--color-paper);
		border-left: 1px solid var(--color-rule);
		box-shadow: -12px 0 40px #0000000c;
		padding: 28px;
		z-index: 5;
	}
	.record-panel header {
		display: flex;
		justify-content: space-between;
		align-items: start;
		gap: 16px;
		margin-bottom: 32px;
	}
	.field {
		margin-bottom: 24px;
	}
	.field label {
		display: flex;
		justify-content: space-between;
		font-size: 13px;
		font-weight: 600;
		margin-bottom: 7px;
	}
	.field input,
	.field select,
	.field textarea {
		width: 100%;
	}
	.required {
		font-size: 11px;
		color: var(--color-muted);
		font-weight: 400;
	}
	.field-note {
		font-size: 12px;
		color: var(--color-muted);
		margin: 7px 0 0;
		line-height: 1.5;
	}
	.editor-actions {
		display: flex;
		gap: 9px;
		flex-wrap: wrap;
		border-top: 1px solid var(--color-rule);
		padding-top: 20px;
	}
	.rules {
		border-top: 1px solid var(--color-rule);
		padding-top: 18px;
		margin-top: 24px;
		font-size: 13px;
		line-height: 1.6;
	}
	.rules h3 {
		font-size: 13px;
	}
	.icon-button {
		padding: 8px;
	}
	@media (max-width: 700px) {
		.data-shell {
			grid-template-columns: 1fr;
			grid-template-rows: auto 1fr;
		}
		.tables {
			padding: 16px;
			border-right: 0;
			border-bottom: 1px solid var(--color-rule);
			gap: 14px;
		}
		.tables nav {
			display: flex;
			overflow: auto;
		}
		.workspace-label {
			display: none;
		}
		.sync-state {
			padding: 0;
			margin-top: 0;
		}
		.sync-state small {
			display: inline;
			margin-left: 8px;
		}
		.records {
			padding: 22px 16px;
		}
		.records-heading {
			align-items: start;
		}
		.records-heading h1 {
			font-size: 28px;
		}
		.records-heading > button {
			white-space: nowrap;
		}
		.record-panel {
			padding: 22px 20px;
		}
		.pagination {
			flex-wrap: wrap;
		}
		.toolbar select {
			max-width: 170px;
		}
	}
</style>
