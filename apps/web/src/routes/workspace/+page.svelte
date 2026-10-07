<script lang="ts">
	import PresentationControls from '$lib/PresentationControls.svelte';
	import RecordPresentations from '$lib/RecordPresentations.svelte';
	import type { ViewPresentation } from 'life-ui-core/client';
	let presentation = $state<ViewPresentation>({ kind: 'table' });
	import { resolveDerivedRecord } from '$lib/resolve-derived';
	import { prepareDuplicate } from '$lib/record-duplicate';
	import { markdownPatch } from '$lib/record-autosave';
	import { editRevision } from '$lib/record-revision';
	import { reconcileUndo } from '$lib/record-undo';
	import FieldEditor from '$lib/FieldEditor.svelte';
	import { createRetainedFileResolver } from '$lib/retained-files';
	import RejectedEdits from '$lib/RejectedEdits.svelte';
	import type { RejectionSnapshot } from '$lib/rejection-inbox';
	import RecordGrid from '$lib/RecordGrid.svelte';
	import ExportPanel from '$lib/export/ExportPanel.svelte';
	import type { ExportSnapshot } from '$lib/export/serialize';
	import {
		cellPatch,
		recordPatch,
		duplicateValues,
		rawValue,
		type CellKey,
		type CellDraft
	} from '$lib/record-grid';
	import { onDestroy, onMount, tick } from 'svelte';
	import { afterNavigate, beforeNavigate, goto } from '$app/navigation';
	import {
		destinationURL,
		readDestination,
		resolveDestination,
		type Destination
	} from '$lib/workspace-navigation';
	import {
		IconDatabase,
		IconPlus,
		IconRefresh,
		IconTrash,
		IconArrowLeft,
		IconArrowUpRight,
		IconSearch,
		IconX,
		IconDeviceFloppy,
		IconLink,
		IconArrowBackUp
	} from '@tabler/icons-svelte';
	import {
		createHttpHub,
		displayName,
		isReadOnlyTable,
		type Row,
		type Property,
		type Filter,
		type SearchHit,
		type SavedViewRecord,
		type SavedViewDefinition,
		type Writeability,
		type Sort,
		type RejectedEdit,
		type UndoAction
	} from 'life-ui-core/client';
	import { WorkspaceDatabase } from '$lib/database';
	import IncomingReferences from '$lib/IncomingReferences.svelte';
	import SchemaGraph from '$lib/SchemaGraph.svelte';
	import HubServices from '$lib/HubServices.svelte';
	import HubEnrollment from '$lib/HubEnrollment.svelte';
	import type { HubConnection } from '$lib/device-enrollment';
	let enrollment = $state<HubEnrollment>();
	let enrolling = $state(false);
	import SearchDialog from '$lib/SearchDialog.svelte';
	import {
		loadDestinations,
		type NavigationState,
		type PaletteDestination
	} from '$lib/command-palette';
	import ColumnSettings from '$lib/ColumnSettings.svelte';
	import SavedViews from '$lib/SavedViews.svelte';
	import ViewControls from '$lib/ViewControls.svelte';
	import { queryDefinition } from '$lib/view-controls';
	import { calendarContext } from '$lib/calendar-context';
	import { untrack } from 'svelte';
	import type { FilterGroup, RowAction, ViewLayoutItem } from 'life-ui-core/client';
	import SidebarTables from '$lib/SidebarTables.svelte';
	import SidebarRecents from '$lib/SidebarRecents.svelte';
	import {
		describeRecent,
		loadRecentEntries,
		parseRecents,
		recentKey,
		rememberRecent,
		serializeRecents,
		type RecentEntry
	} from '$lib/sidebar-recents';
	let recentDestinations = $state<Destination[]>([]);
	let recentEntries = $state<RecentEntry[]>([]);
	let recentStorageError = $state('');
	let recentReadError = $state('');
	let recentsRequest = 0;
	const recentsStorageKey = () => `life-ui:recents:${demo ? 'demo' : 'workspace'}`;
	function readRecents() {
		recentsRequest++;
		recentEntries = [];
		recentStorageError = '';
		recentReadError = '';
		try {
			recentDestinations = parseRecents(localStorage.getItem(recentsStorageKey()));
		} catch {
			recentDestinations = [];
			recentReadError =
				'Recents could not be read on this device. New recents remain available until this workspace closes.';
		}
	}
	function persistRecents() {
		if (recentReadError) return;
		try {
			localStorage.setItem(recentsStorageKey(), serializeRecents(recentDestinations));
			recentStorageError = '';
		} catch {
			recentStorageError =
				'Recents could not be saved on this device. They remain available until this workspace closes.';
		}
	}
	function refreshRecentLabels() {
		const workspace = database,
			scope = demo,
			request = ++recentsRequest;
		if (!workspace) return;
		void loadRecentEntries(
			$state.snapshot(recentDestinations),
			async (destination) =>
				describeRecent(destination, await resolveDestination(workspace, destination, '')),
			(entries) => {
				recentEntries = entries;
			},
			() => database === workspace && demo === scope && request === recentsRequest
		);
	}
	function recordRecent() {
		const destination = currentDestination();
		if (!destination.table) return;
		recentDestinations = rememberRecent(recentDestinations, destination);
		persistRecents();
		refreshRecentLabels();
	}
	function removeRecent(destination: Destination) {
		recentDestinations = recentDestinations.filter(
			(entry) => recentKey(entry) !== recentKey(destination)
		);
		persistRecents();
		refreshRecentLabels();
	}
	async function openRecent(destination: Destination) {
		const workspace = database,
			version = editorVersion;
		const current = () =>
			database === workspace &&
			editorVersion === version &&
			!findVisible &&
			recentDestinations.some((entry) => recentKey(entry) === recentKey(destination));
		try {
			await openDestination(destination, current);
		} catch (e) {
			if (current()) {
				error = message(e);
				refreshRecentLabels();
			}
		}
	}
	import RemoteBrowser from '$lib/RemoteBrowser.svelte';
	let onlineBrowser = $state<{
		workspace: WorkspaceDatabase;
		table: string;
		connection: { endpoint: string; token: string };
	} | null>(null);
	let connectedHub = $state<{ endpoint: string; token: string } | null>(null);
	const resolveRetainedFile = $derived(
		connectedHub ? createRetainedFileResolver(connectedHub) : undefined
	);
	let findVisible = $state(false);
	let findVersion = 0;
	let findNavigation = $state<NavigationState>({ destinations: [], loading: false, error: '' });
	function showFind(visible: boolean) {
		findVersion++;
		findVisible = visible;
		findNavigation = { destinations: [], loading: false, error: '' };
		if (visible && database) {
			const workspace = database,
				version = findVersion;
			void loadDestinations(
				catalog.tables.map(tableName),
				(target) => workspace.request('listViews', { table: target }),
				(state) => {
					findNavigation = state;
				},
				() => database === workspace && findVisible && findVersion === version
			);
		}
	}

	let database = $state<WorkspaceDatabase | null>(null);
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
	$effect(() => {
		if (
			onlineBrowser &&
			(!opened ||
				database !== onlineBrowser.workspace ||
				table !== onlineBrowser.table ||
				connectedHub !== onlineBrowser.connection)
		)
			onlineBrowser = null;
	});
	let writing = $state(false);
	let undoAction = $state<UndoAction | null>(null);
	let undoPaused = $state(false);
	let bodySaving = $state(false),
		bodyFailure = $state('');
	let editorVersion = $state(0);
	let relationOpening = $state<number | null>(null);
	let gridActionOpening = $state<number | null>(null);
	let recordHeading = $state<HTMLHeadingElement>();
	let recordOpenVersion = 0;
	let locationRequest = 0;
	let reflectingURL: string | null = null;
	let navigationLoading = $state(false);
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
	let gridDraft = $state<CellDraft | null>(null);
	let explicitCreation = $state<Set<string>>(new Set());
	let copiedCreation = $state<Row | null>(null);
	let gridContext = $state(0);
	const gridDirty = $derived(
		!!gridDraft && gridDraft.raw !== rawValue(gridDraft.baseline[gridDraft.cell.column])
	);
	const dirty = $derived(
		(editing &&
			(JSON.stringify(draft) !== savedDraft ||
				(!selected && (explicitCreation.size > 0 || copiedCreation !== null)))) ||
			gridDirty
	);
	function confirmDiscard() {
		if (writing || bodySaving || (dirty && !confirm('Discard unsaved changes to this record?')))
			return false;
		return true;
	}
	function discard() {
		if (!confirmDiscard()) return false;
		gridDraft = null;
		return true;
	}
	beforeNavigate((navigation) => {
		if (navigation.to?.url.href === reflectingURL) return;
		if ((opened && busy) || !discard()) {
			navigation.cancel();
			return;
		}
		locationRequest++;
		recordOpenVersion++;
		showFind(false);
	});
	afterNavigate(({ to }) => {
		if (opened && to && to.url.href !== reflectingURL) void restoreLocation(to.url);
	});
	function currentDestination() {
		return {
			table: table || null,
			view: chosenView?.id ?? null,
			row: editing && selected ? String(selected.id) : null
		};
	}
	async function reflectLocation(replace = false) {
		const url = destinationURL(new URL(window.location.href), currentDestination());
		if (url.href === window.location.href) return;
		reflectingURL = url.href;
		try {
			await goto(url, { replaceState: replace, noScroll: true, keepFocus: true });
		} finally {
			if (reflectingURL === url.href) reflectingURL = null;
		}
	}
	async function restoreLocation(url: URL) {
		const workspace = database,
			request = ++locationRequest;
		let version = editorVersion;
		if (!workspace) return;
		navigationLoading = true;
		const current = () =>
			database === workspace && request === locationRequest && version === editorVersion;
		try {
			const resolved = await resolveDestination(workspace, readDestination(url), table);
			if (!current()) return;
			resetView();
			catalog = resolved.catalog;
			table = resolved.table;
			graphVisible = false;
			applyView(resolved.view);
			if (resolved.row) trash = !!resolved.row.deleted_at;
			if (resolved.row) edit(resolved.row, false);
			version = editorVersion;
			await Promise.all([loadRows(), loadViews(), loadWriteability()]);
			await tick();
			if (current()) {
				if (resolved.row) recordHeading?.focus();
				recordRecent();
			}
		} catch (e) {
			if (current()) error = message(e);
		} finally {
			if (request === locationRequest) navigationLoading = false;
		}
	}
	async function copyLink() {
		try {
			await navigator.clipboard.writeText(
				destinationURL(new URL(window.location.href), currentDestination()).href
			);
			notice = 'Link copied. Open it in the matching workspace.';
		} catch {
			error = 'The link could not be copied. Copy the address from your browser.';
		}
	}
	function closeRecord() {
		if (!discard()) return false;
		editing = false;
		editorVersion++;
		locationRequest++;
		navigationLoading = false;
		void reflectLocation();
		return true;
	}
	let lastSync = $state<string | null>(null),
		pendingEdits = $state(0),
		rejected = $state<RejectionSnapshot>({ page: null, error: '' }),
		rejectedCount = $state(0),
		notice = $state('');
	let skipped = $state<string[]>([]),
		maxRows = $state(50000),
		included = $state<Record<string, boolean>>({});
	let sort = $state('id'),
		descending = $state(false),
		offset = $state(0);
	let columns = $state<string[] | null>(null),
		widths = $state<Record<string, number>>({});
	let savedViews = $state<SavedViewRecord[]>([]),
		viewsUnavailable = $state<string | null>(null),
		chosenView = $state<SavedViewRecord | null>(null),
		viewBaseline = $state('');
	let viewVersion = 0,
		viewsRequest = 0;
	let importedSort = $state<Sort[] | null>(null);
	let filterGroups = $state<FilterGroup[]>([]),
		actions = $state<RowAction[]>([]),
		actionLayout = $state<ViewLayoutItem[] | undefined>(),
		timeZone = $state('UTC'),
		dayStartMinutes = $state(0);
	const sortClauses = $derived(
		importedSort ?? [{ column: sort, direction: descending ? ('desc' as const) : ('asc' as const) }]
	);
	let references = $state<Record<string, Row[]>>({}),
		referenceSearch = $state<Record<string, string>>({});
	let optionValues = $state<Record<string, string[]>>({});
	let names = $state<Record<string, string>>({});
	let rowsRequest = 0;
	let exportSnapshot = $state.raw<ExportSnapshot | null>(null);
	let exportContext = $state('');
	let exportRefreshes = $state(0);
	const referenceRequests: Record<string, number> = {};
	let filterColumn = $state(''),
		filterOp = $state<Filter['op']>('eq'),
		filterValue = $state(''),
		filters = $state<Filter[]>([]);
	const currentExportContext = $derived(
		JSON.stringify([table, search, trash, filters, sortClauses, offset])
	);
	const filterLabels: Record<Filter['op'], string> = {
		eq: 'is',
		ne: 'is not',
		empty: 'is empty',
		not_empty: 'is not empty',
		contains: 'contains',
		gt: 'greater than',
		gte: 'at least',
		lt: 'less than',
		lte: 'at most'
	};
	const describeFilter = (filter: Filter) =>
		`${properties.find((p) => p.col === filter.column)?.label || filter.column} ${filterLabels[filter.op]}${filter.relative === 'today' ? ' Today' : filter.value === undefined ? '' : ` ${filter.value}`}`;
	const system = new Set(['id', 'created_at', 'updated_at', 'deleted_at', 'hub_at']);
	const properties = $derived(
		catalog.properties
			.filter((p) => p.tbl === table && !system.has(p.col))
			.sort((a, b) => (a.sort ?? 0) - (b.sort ?? 0) || a.col.localeCompare(b.col))
	);
	const filterType = $derived(properties.find((p) => p.col === filterColumn)?.type ?? 'text');
	const current = $derived(catalog.tables.find((t) => t.id === table));
	const display = $derived(typeof current?.display === 'string' ? current.display : null);
	const viewProperties = $derived([
		...properties,
		...[
			['id', 'ID', 'text'],
			['created_at', 'Created', 'datetime'],
			['updated_at', 'Updated', 'datetime'],
			['deleted_at', 'Deleted', 'datetime'],
			['hub_at', 'Hub revision', 'datetime']
		].map(
			([col, label, type]) => ({ id: `${table}.${col}`, tbl: table, col, label, type }) as Property
		)
	]);
	const columnChoices = $derived(viewProperties.filter((p) => p.col !== (display ?? 'id')));
	const visibleColumns = $derived(
		columns ??
			properties
				.filter((p) => p.col !== display && p.type !== 'markdown')
				.slice(0, 4)
				.map((p) => p.col)
	);
	const gridProperties = $derived(
		visibleColumns
			.map((col) => columnChoices.find((p) => p.col === col))
			.filter((p): p is Property => !!p)
	);
	const recordProperty = $derived(
		properties.find((p) => p.col === display) ?? { col: 'id', label: 'Record', type: 'text' }
	);
	const gridColumns = $derived([recordProperty, ...gridProperties]);
	const canEditCell = (p: Property) =>
		!system.has(p.col) &&
		!p.derived_by &&
		!p.deprecated &&
		!p.immutable &&
		!readOnly &&
		!blocked &&
		!trash;
	async function beginCell(cell: CellKey): Promise<Row | false> {
		if (!database || busy || navigationLoading) return false;
		const workspace = database,
			target = table,
			version = editorVersion,
			request = ++recordOpenVersion;
		const current = () =>
			database === workspace &&
			target === table &&
			version === editorVersion &&
			request === recordOpenVersion &&
			!busy &&
			!navigationLoading;
		let found: Row[];
		try {
			found = await workspace.request('rows', {
				view: { table: target, filters: [{ column: 'id', op: 'eq', value: cell.rowId }], limit: 1 }
			});
		} catch (e) {
			if (!current()) return false;
			throw e;
		}
		if (!current()) return false;
		if (!found[0])
			throw new Error('This record is no longer available locally. Your saved data is unchanged.');
		const property = properties.find((p) => p.col === cell.column);
		if (!property || !canEditCell(property) || !discard()) return false;
		editing = false;
		editorVersion++;
		selected = found[0];
		draft = rowDraft(found[0]);
		savedDraft = JSON.stringify(draft);
		references = {};
		optionValues = {};
		if (property.type === 'ref' || property.type === 'multi_ref') void loadReferences(property);
		if (property.type === 'select' || property.type === 'multi_select') void loadOptions(property);
		void reflectLocation(true);
		return found[0];
	}
	async function commitCell(cell: CellDraft): Promise<Row> {
		if (!database || busy || navigationLoading)
			throw new Error('Wait for the current operation before saving this cell.');
		const property = properties.find((p) => p.col === cell.cell.column);
		if (!property || !canEditCell(property))
			throw new Error(
				writePermission?.reason?.message ?? 'This field is not editable. Your draft is kept.'
			);
		const workspace = database,
			target = table,
			version = editorVersion;
		writing = true;
		busy = true;
		try {
			const stored = await workspace.request('write', {
				table: target,
				patch: cellPatch(property, cell),
				expectedUpdatedAt: editRevision(cell.baseline)
			});
			if (database === workspace && table === target && editorVersion === version) {
				selected = stored;
				notice = 'Cell saved on this device';
				await refresh().catch((e) => {
					error = `Cell saved. Could not refresh records: ${message(e)}`;
				});
			}
			return stored;
		} finally {
			if (database === workspace) {
				writing = false;
				busy = false;
			}
		}
	}
	async function newGridRecord(): Promise<boolean> {
		if (busy || navigationLoading || readOnly || blocked || trash) return false;
		return edit(null);
	}
	async function duplicateRecord(id: string): Promise<boolean> {
		if (!database || busy || navigationLoading || readOnly || blocked || trash) return false;
		const workspace = database,
			target = table,
			version = editorVersion,
			request = ++recordOpenVersion;
		const current = () =>
			database === workspace &&
			table === target &&
			editorVersion === version &&
			recordOpenVersion === request &&
			!busy &&
			!writing &&
			!bodySaving &&
			!navigationLoading;
		try {
			const prepared = await prepareDuplicate(workspace, target, id, current);
			if (!prepared || !current() || !discard()) return false;
			catalog = prepared.catalog;
			writePermission = prepared.permission;
			edit(null, true, true);
			const copy = duplicateValues(properties, prepared.row);
			draft = { ...draft, ...copy };
			copiedCreation = Object.fromEntries(Object.keys(copy).map((col) => [col, prepared.row[col]]));
			notice = 'Review this unsaved copy, then save to create a new record.';
			return true;
		} catch (e) {
			if (current()) error = message(e);
			return false;
		}
	}
	async function trashGridRecord(id: string): Promise<boolean> {
		if (!database || busy || navigationLoading || readOnly || blocked || gridActionOpening)
			return false;
		const workspace = database,
			target = table,
			version = editorVersion,
			request = ++recordOpenVersion,
			restore = trash;
		const current = () =>
			database === workspace &&
			table === target &&
			editorVersion === version &&
			recordOpenVersion === request &&
			trash === restore;
		gridActionOpening = request;
		try {
			const found = await workspace.request('rows', {
				view: {
					table: target,
					trash: restore,
					filters: [{ column: 'id', op: 'eq', value: id }],
					limit: 1
				}
			});
			if (!current() || busy || navigationLoading || readOnly || blocked) return false;
			if (!found[0])
				throw new Error('This record is no longer available locally. Your draft is kept.');
			if (!confirmDiscard()) return false;
			writing = true;
			busy = true;
			error = '';
			try {
				await workspace.request('write', {
					table: target,
					patch: { id, deleted_at: restore ? null : true },
					expectedUpdatedAt: editRevision(found[0])
				});
				if (!current()) return false;
				gridDraft = null;
				editorVersion++;
				editing = false;
				selected = null;
				notice = restore ? 'Record restored' : 'Moved to trash';
				await refresh().catch((e) => {
					error = `${notice}. Could not refresh records: ${message(e)}`;
				});
				await reflectLocation(true);
				return true;
			} finally {
				if (database === workspace) {
					writing = false;
					busy = false;
				}
			}
		} catch (e) {
			if (current()) error = message(e);
			return false;
		} finally {
			if (gridActionOpening === request) gridActionOpening = null;
		}
	}
	function changeColumns(next: string[], sizes: Record<string, number>) {
		if (
			gridDraft &&
			gridDraft.cell.column !== (display ?? 'id') &&
			!next.includes(gridDraft.cell.column) &&
			!discard()
		)
			return;
		columns = next;
		if (actionLayout) {
			const ids = [display ?? 'id', ...next];
			actionLayout = [
				...actionLayout.filter((i) => i.kind === 'action' || ids.includes(i.id)),
				...ids
					.filter((id) => !actionLayout?.some((i) => i.kind === 'column' && i.id === id))
					.map((id) => ({ kind: 'column' as const, id }))
			];
		}
		widths = sizes;
		void loadRows().catch((e) => (error = message(e)));
	}
	const rules = $derived(catalog.rules.filter((r) => r.tbl === table || r.scope === 'estate'));
	const readOnly = $derived(isReadOnlyTable(table, current));
	let writePermission = $state<Writeability | null>(null);
	let permissionRequest = 0;
	const blocked = $derived(!writePermission?.writable);
	async function loadWriteability() {
		const workspace = database,
			target = table,
			request = ++permissionRequest;
		writePermission = null;
		if (!workspace || !target) return;
		try {
			const result = await workspace.request('writeability', { table: target });
			if (database === workspace && table === target && request === permissionRequest)
				writePermission = result;
		} catch (e) {
			if (database === workspace && table === target && request === permissionRequest)
				writePermission = {
					writable: false,
					reason: { tbl: target, row_id: null, col: '', rule: 'storage', message: message(e) }
				};
		}
	}
	const draftProperties = $derived(properties.filter((p) => Object.hasOwn(draft, p.col)));
	const bodyPatch = $derived(markdownPatch(properties, draft, selected));
	const bodySaveKey = $derived(JSON.stringify([editorVersion, bodyPatch]));
	$effect(() => {
		if (
			!editing ||
			!bodyPatch ||
			navigationLoading ||
			busy ||
			undoPaused ||
			readOnly ||
			blocked ||
			selected?.deleted_at != null ||
			bodyFailure === bodySaveKey
		)
			return;
		const patch = bodyPatch,
			key = bodySaveKey;
		const timer = setTimeout(() => void saveBody(patch, key), 600);
		return () => clearTimeout(timer);
	});
	async function saveBody(patch: Row, key: string) {
		if (
			!database ||
			!selected ||
			!editing ||
			busy ||
			undoPaused ||
			selected.deleted_at != null ||
			key !== bodySaveKey
		)
			return;
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
		navigationLoading ||
		writing ||
		selected?.deleted_at != null ||
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
	let actionOptions = $state<Record<string, string[]>>({});
	let actionReferences = $state<Record<string, { id: string; label: string }[]>>({});
	let actionReferenceRequests: Record<string, number> = {};
	let actionReferenceSearch: Record<string, string> = {};
	let actionReferenceSequence = 0;
	$effect(() => {
		const workspace = database,
			target = table,
			definitions = $state.snapshot(actions);
		const properties = viewProperties;
		let active = true;
		untrack(() => {
			actionOptions = {};
			actionReferences = {};
			for (const p of properties.filter((p) =>
				definitions.some((a) => Object.hasOwn(a.values, p.col))
			)) {
				if (['select', 'multi_select'].includes(p.type ?? '')) {
					void workspace
						?.request('options', { table: target, column: p.col })
						.then((values) => {
							if (active) actionOptions[p.col] = values;
						})
						.catch((e) => {
							if (active) error = message(e);
						});
				}
				if (['ref', 'multi_ref'].includes(p.type ?? ''))
					for (const a of definitions.filter((a) => Object.hasOwn(a.values, p.col)))
						void loadActionReferences(
							a,
							p,
							actionReferenceSearch[JSON.stringify([a.id, p.col])] ?? ''
						);
			}
		});
		return () => {
			active = false;
			actionReferenceRequests = {};
		};
	});
	async function loadActionReferences(action: RowAction, p: Property, query = '') {
		const workspace = database,
			version = viewVersion;
		if (!workspace || !p.ref_table) return;
		const key = JSON.stringify([action.id, p.col]);
		actionReferenceSearch[key] = query;
		const request = ++actionReferenceSequence;
		actionReferenceRequests[key] = request;
		const current = () =>
			workspace === database && version === viewVersion && actionReferenceRequests[key] === request;
		try {
			const found = await workspace.request('rows', {
				view: { table: p.ref_table, search: query, limit: 50 }
			});
			const raw = rawValue(action.values[p.col]);
			const selected = p.type === 'multi_ref' ? list(raw) : [raw];
			for (const id of selected.filter(Boolean)) {
				if (!current()) return;
				if (!found.some((row) => row.id === id))
					found.push(
						...(await workspace.request('rows', {
							view: {
								table: p.ref_table,
								filters: [{ column: 'id', op: 'eq', value: id }],
								limit: 1
							}
						}))
					);
			}
			if (current())
				actionReferences[key] = found.map((row) => ({
					id: String(row.id),
					label: refTitle(p, row)
				}));
		} catch (e) {
			if (current()) error = message(e);
		}
	}
	function loadBoardOptions() {
		if (presentation.kind !== 'board') return;
		const property = properties.find((p) => p.col === presentation.groupColumn);
		if (property) void loadOptions(property);
	}
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
			const raw = gridDraft?.cell.column === p.col ? gridDraft.raw : draft[p.col];
			const ids = p.type === 'multi_ref' ? list(raw) : [raw];
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
	async function reviewRejected(entry: RejectedEdit) {
		if (!database || busy || writing || bodySaving || navigationLoading) return;
		const workspace = database,
			request = ++recordOpenVersion;
		let version = editorVersion;
		const current = () =>
			database === workspace && editorVersion === version && request === recordOpenVersion && !busy;
		try {
			let found = await workspace.request('rows', {
				view: {
					table: entry.table,
					filters: [{ column: 'id', op: 'eq', value: entry.rowID }],
					limit: 1
				}
			});
			if (!current()) return;
			if (!found.length)
				found = await workspace.request('rows', {
					view: {
						table: entry.table,
						trash: true,
						filters: [{ column: 'id', op: 'eq', value: entry.rowID }],
						limit: 1
					}
				});
			if (!current()) return;
			if (!found[0] || found[0].id !== entry.rowID)
				throw new Error(
					'This record is not available locally. Include its table and sync before repairing the edit.'
				);
			const latest = await workspace.request('snapshot');
			if (!current()) return;
			const permission = await workspace.request('writeability', { table: entry.table });
			if (!current() || !discard()) return;
			locationRequest++;
			resetView();
			catalog = latest.catalog;
			table = entry.table;
			graphVisible = false;
			trash = found[0].deleted_at != null;
			writePermission = permission;
			edit(found[0], false);
			version = editorVersion;
			// Rejected values are an explicit review draft. Preserve the fresh row's
			// revision and keep autosave paused, including while a tombstone is restored.
			undoPaused = true;
			for (const p of properties.filter((p) => !p.derived_by && !p.deprecated && !p.immutable)) {
				if (!Object.hasOwn(entry.submitted, p.col)) continue;
				const value = entry.submitted[p.col];
				draft[p.col] =
					value == null ? '' : typeof value === 'string' ? value : JSON.stringify(value);
			}
			notice = 'Review the rejected values, save your correction, then sync.';
			const openedVersion = editorVersion;
			await Promise.all([loadRows(), loadViews()]);
			if (database !== workspace || editorVersion !== openedVersion) return;
			await reflectLocation();
		} catch (e) {
			if (current()) error = message(e);
		}
	}
	async function runSavedAction(actionId: string, row: Row) {
		if (
			!database ||
			busy ||
			navigationLoading ||
			!chosenView ||
			!chosenView.updated_at ||
			viewModified ||
			blocked ||
			readOnly ||
			trash ||
			!discard()
		)
			return;
		const workspace = database,
			version = viewVersion;
		busy = true;
		writing = true;
		error = '';
		try {
			await workspace.request('runRowAction', {
				viewId: chosenView.id,
				actionId,
				rowId: String(row.id),
				expectedUpdatedAt: editRevision(row),
				expectedViewUpdatedAt: chosenView.updated_at
			});
			if (database !== workspace || viewVersion !== version) return;
			selected = null;
			editing = false;
			gridDraft = null;
			draft = {};
			savedDraft = '';
			await loadRows();
			notice = 'Action saved on this device';
		} catch (e) {
			if (database === workspace && viewVersion === version) error = message(e);
		} finally {
			if (database === workspace) {
				busy = false;
				writing = false;
			}
		}
	}
	$effect(() => {
		const workspace = database,
			zone = timeZone,
			boundary = dayStartMinutes;
		const relative = [...filters, ...filterGroups.flatMap((g) => g.filters)].some(
			(f) => f.relative === 'today'
		);
		if (!workspace || !relative) return;
		let timer: ReturnType<typeof setTimeout>, previous: string;
		try {
			previous = calendarContext(zone, new Date(), boundary).today;
		} catch (e) {
			error = message(e);
			return;
		}
		const refresh = () => {
			clearTimeout(timer);
			const next = calendarContext(zone, new Date(), boundary);
			if (next.today !== previous) {
				previous = next.today;
				untrack(() => void loadRows().catch((e) => (error = message(e))));
			}
			timer = setTimeout(refresh, Math.max(1, Date.parse(next.end) - Date.now() + 1));
		};
		refresh();
		window.addEventListener('focus', refresh);
		window.addEventListener('pageshow', refresh);
		document.addEventListener('visibilitychange', refresh);
		return () => {
			clearTimeout(timer);
			window.removeEventListener('focus', refresh);
			window.removeEventListener('pageshow', refresh);
			document.removeEventListener('visibilitychange', refresh);
		};
	});

	async function loadRows() {
		exportSnapshot = null;
		if (!database || !table) return;
		const workspace = database;
		const request = ++rowsRequest;
		const capturedContext = currentExportContext;
		const capturedTable = table;
		const capturedProperties = structuredClone(
			$state.snapshot(catalog.properties.filter((p) => p.tbl === table))
		);
		const found: Row[] = await workspace.request('rows', {
			view: {
				...queryDefinition(table, viewDefinition()),
				limit: 50,
				offset
			}
		});
		if (database !== workspace || request !== rowsRequest) return;
		rows = found;
		exportContext = capturedContext;
		exportSnapshot = {
			table: capturedTable,
			properties: capturedProperties,
			rows: structuredClone(found),
			scope: 'loaded',
			completeness: {
				rows: 'unknown',
				// This rows request omits a projection, independently of visible grid columns.
				columns: 'full',
				reasons: [
					'Only the current local page is included; filters, pagination and sync may omit records.',
					'Catalog and sync status are acquired separately from rows. Attached bytes are not included.'
				]
			},
			acquisition: {
				source: 'local-replica',
				capturedAt: new Date().toISOString(),
				freshness: 'unknown',
				lastSync,
				skippedTables: [...skipped],
				pendingUiEdits: pendingEdits,
				rejectedEdits: rejectedCount
			}
		};
		names = {};
		const labels: Record<string, string> = {};
		// ponytail: at most 200 visible references per page; batch SQL when larger grids need it.
		const targets = new Map<string, Property>();
		for (const p of gridProperties.filter(
			(p) =>
				(p.type === 'ref' || p.type === 'multi_ref') &&
				catalog.tables.some((target) => target.id === p.ref_table)
		))
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
		exportSnapshot = null;
		if (!database) return;
		// An older rows reply cannot restore an export while catalog/status refreshes.
		rowsRequest++;
		exportRefreshes++;
		try {
			const workspace = database;
			const state = await workspace.request('snapshot');
			if (database !== workspace) return;
			catalog = state.catalog;
			lastSync = state.lastSync ?? null;
			pendingEdits = state.status.pendingUiEdits;
			undoAction = state.undo;
			rejected = state.rejected;
			rejectedCount = state.status.rejected;
			skipped = state.skipped ?? [];
			if (!table && catalog.tables.length)
				table = tableName(catalog.tables.find((t) => !t.readOnly) ?? catalog.tables[0]);
			await Promise.all([loadRows(), loadViews(), loadWriteability()]);
			if (database === workspace) refreshRecentLabels();
		} finally {
			exportRefreshes--;
		}
	}
	function resetView() {
		exportSnapshot = null;
		undoPaused = false;
		gridDraft = null;
		gridContext++;
		permissionRequest++;
		writePermission = null;
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
		columns = null;
		widths = {};
		importedSort = null;
		filterGroups = [];
		actions = [];
		actionLayout = undefined;
		presentation = { kind: 'table' };
		timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
		dayStartMinutes = 0;
		chosenView = null;
		viewBaseline = '';
		savedViews = [];
		viewsUnavailable = null;
		viewVersion++;
		actionReferenceSearch = {};
		viewsRequest++;
		filters = [];
		filterColumn = '';
		filterOp = 'eq';
		filterValue = '';
		error = '';
		notice = '';
	}
	async function openWorkspace(sample: boolean) {
		if (busy) return;
		showFind(false);
		busy = true;
		connectedHub = null;
		resetView();
		try {
			database?.close();
			database = new WorkspaceDatabase();
			await database.request('open', { demo: sample });
			demo = sample;
			readRecents();
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
			const linked = new URL(window.location.href);
			if (['table', 'view', 'row'].some((key) => linked.searchParams.has(key)))
				await restoreLocation(linked);
			else {
				await reflectLocation(true);
				recordRecent();
			}
		} catch (e) {
			error = message(e);
			opened = false;
		} finally {
			busy = false;
		}
	}
	async function changeTable(name: string) {
		if (!discard()) return;
		locationRequest++;
		navigationLoading = false;
		resetView();
		graphVisible = false;
		table = name;
		const version = editorVersion;
		let loaded = true;
		await Promise.all([loadRows(), loadViews(), loadWriteability()]).catch((e) => {
			loaded = false;
			if (editorVersion === version) error = message(e);
		});
		if (editorVersion === version) {
			await reflectLocation();
			if (loaded && editorVersion === version) recordRecent();
		}
	}

	function viewDefinition(): SavedViewDefinition {
		return $state.snapshot({
			version: 2,
			presentation,
			groups: filterGroups,
			timeZone,
			...(dayStartMinutes !== 0 || chosenView?.definition?.dayStartMinutes !== undefined
				? { dayStartMinutes }
				: {}),
			actions,
			...(actionLayout ? { layout: actionLayout } : {}),
			columns: [...new Set([display ?? 'id', ...visibleColumns])],
			filters,
			sort: sortClauses,
			search,
			trash,
			widths
		});
	}
	const viewModified = $derived(!!chosenView && JSON.stringify(viewDefinition()) !== viewBaseline);
	async function loadViews() {
		if (!database || !table) return;
		const workspace = database,
			target = table,
			request = ++viewsRequest;
		const result = await workspace.request('listViews', { table: target });
		if (database !== workspace || table !== target || request !== viewsRequest) return;
		savedViews = result.views;
		viewsUnavailable = result.unavailable;
		// Keep the applied revision and query. A remote edit must not silently
		// replace this device's configuration or defeat optimistic conflict checks.
	}
	async function chooseView(id: string | null): Promise<boolean> {
		const view = id === null ? null : savedViews.find((view) => view.id === id);
		if (id !== null && (!view?.definition || !view.view || view.unavailable)) return false;
		if (!discard()) return false;
		locationRequest++;
		navigationLoading = false;
		applyView(view ?? null);
		const version = editorVersion;
		await loadRows();
		if (version === editorVersion) {
			await reflectLocation();
			if (version === editorVersion) recordRecent();
		}
		return true;
	}
	function applyView(view: SavedViewRecord | null) {
		gridDraft = null;
		gridContext++;
		editorVersion++;
		viewVersion++;
		actionReferenceSearch = {};
		editing = false;
		selected = null;
		draft = {};
		savedDraft = '';
		bodyFailure = '';
		const definition = view?.definition;
		columns = definition?.columns?.filter((col) => col !== (display ?? 'id')) ?? null;
		widths = { ...definition?.widths };
		filters = definition?.filters?.map((filter) => ({ ...filter })) ?? [];
		filterGroups = $state.snapshot(definition?.groups ?? []);
		actions = $state.snapshot(definition?.actions ?? []);
		actionLayout = definition?.layout ? $state.snapshot(definition.layout) : undefined;
		timeZone = definition?.timeZone ?? Intl.DateTimeFormat().resolvedOptions().timeZone;
		dayStartMinutes = definition?.dayStartMinutes ?? 0;
		presentation = definition?.presentation
			? $state.snapshot(definition.presentation)
			: { kind: 'table' };
		loadBoardOptions();
		search = definition?.search ?? '';
		trash = definition?.trash ?? false;
		importedSort = definition?.sort?.map((clause) => ({ ...clause })) ?? null;
		sort = importedSort?.[0]?.column ?? 'id';
		descending = importedSort?.[0]?.direction === 'desc';
		offset = 0;
		filterColumn = '';
		filterValue = '';
		chosenView = view ?? null;
		viewBaseline = JSON.stringify(viewDefinition());
		error = '';
	}
	async function saveNamedView(name: string, update: boolean) {
		if (!database || busy) return;
		const workspace = database,
			target = table,
			version = viewVersion;
		const selectedView = chosenView;
		if (update && !selectedView?.updated_at)
			throw new Error('Reopen this view before updating it.');
		const definition = viewDefinition();
		busy = true;
		writing = true;
		try {
			const saved = await workspace.request('saveView', {
				table: target,
				name,
				definition,
				...(update ? { id: selectedView!.id, expectedUpdatedAt: selectedView!.updated_at! } : {})
			});
			if (workspace !== database || table !== target || version !== viewVersion) return;
			chosenView = saved;
			viewBaseline = JSON.stringify(definition);
			await loadViews();
			await reflectLocation();
			notice = 'View saved on this device';
		} finally {
			if (database === workspace) {
				busy = false;
				writing = false;
			}
		}
	}
	async function deleteNamedView(id: string) {
		if (!database || busy) return;
		const workspace = database,
			target = table,
			version = viewVersion;
		const selectedView = chosenView;
		if (id !== selectedView?.id || !selectedView.updated_at)
			throw new Error('Reopen this view before deleting it.');
		if (!discard()) return;
		busy = true;
		writing = true;
		try {
			await workspace.request('deleteView', { id, expectedUpdatedAt: selectedView.updated_at });
			if (workspace !== database || table !== target || version !== viewVersion) return;
			applyView(null);
			await Promise.all([loadRows(), loadViews()]);
			await reflectLocation();
			notice = 'View deleted; records kept';
		} finally {
			if (database === workspace) {
				busy = false;
				writing = false;
			}
		}
	}
	async function applyFilter() {
		let value: Filter['value'] = filterValue;
		if (!['empty', 'not_empty'].includes(filterOp)) {
			if (filterType === 'bool') {
				if (!['true', 'false'].includes(filterValue)) {
					error = 'Choose True or False for this filter.';
					return;
				}
				value = filterValue === 'true';
			} else if (['number', 'int'].includes(filterType)) {
				if (!filterValue.trim() || !Number.isFinite(Number(filterValue))) {
					error = 'Enter a number for this filter.';
					return;
				}
				value = Number(filterValue);
			}
		}
		error = '';
		filters = filterColumn
			? [
					...filters,
					{
						column: filterColumn,
						op: filterOp,
						...(['empty', 'not_empty'].includes(filterOp) ? {} : { value })
					}
				]
			: [];
		await find();
	}
	async function removeFilter(index?: number) {
		filters = index === undefined ? [] : filters.filter((_, i) => i !== index);
		await find();
	}
	function edit(row: Row | null, reflect = true, discardConfirmed = false): boolean {
		if (!discardConfirmed && !discard()) return false;
		explicitCreation = new Set();
		copiedCreation = null;
		undoPaused = false;
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
		if (reflect) void reflectLocation();
		return true;
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
	async function moveBoardRecord(row: Row, value: string | null) {
		const property = properties.find((p) => p.col === presentation.groupColumn);
		if (!database || !property || !canEditCell(property) || busy || navigationLoading || dirty) {
			error = 'Finish the current edit before moving a record.';
			return;
		}
		const workspace = database,
			target = table;
		busy = true;
		writing = true;
		error = '';
		try {
			await workspace.request('write', {
				table: target,
				patch: { id: row.id, [property.col]: value },
				expectedUpdatedAt: editRevision(row)
			});
			if (database === workspace && table === target) await refresh();
		} catch (e) {
			if (database === workspace) error = message(e);
		} finally {
			if (database === workspace) {
				busy = false;
				writing = false;
			}
		}
	}
	async function resolveField(property: Property) {
		if (
			!database ||
			!selected ||
			!connectedHub ||
			busy ||
			writing ||
			bodySaving ||
			navigationLoading
		)
			return;
		if (dirty) {
			error = 'Save or discard your changes before resolving. Your draft has been kept.';
			return;
		}
		const workspace = database,
			version = editorVersion,
			target = table,
			original = $state.snapshot(selected),
			connection = connectedHub;
		const current = () =>
			database === workspace &&
			editorVersion === version &&
			table === target &&
			connectedHub === connection;
		busy = true;
		writing = true;
		error = '';
		try {
			const { record, result } = await resolveDerivedRecord(
				workspace,
				connection,
				target,
				original,
				property.col,
				{ maxRows, tables: $state.snapshot(included) },
				current
			);
			if (!current()) return;
			const reconciled = reconcileUndo(draft, rowDraft(original), rowDraft(record));
			selected = record;
			draft = reconciled.values;
			savedDraft = reconciled.baseline;
			undoPaused = reconciled.dirty;
			error = result.failed.map((failure) => failure.error).join(' ');
			notice = result.failed.length
				? 'Some derived values could not be resolved.'
				: 'Resolved and synced';
			await refresh();
		} catch (failure) {
			if (current()) error = message(failure);
		} finally {
			if (database === workspace) {
				busy = false;
				writing = false;
			}
		}
	}
	async function save() {
		if (!database || busy || navigationLoading || !editing || selected?.deleted_at != null) return;
		const workspace = database,
			version = editorVersion,
			target = table;
		writing = true;
		busy = true;
		error = '';
		try {
			const patch = recordPatch(
				draftProperties,
				draft,
				selected,
				explicitCreation,
				copiedCreation ?? {}
			);
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
			undoPaused = false;
			await refresh();
			await reflectLocation(true);
		} catch (e) {
			if (database === workspace && editorVersion === version) error = message(e);
		} finally {
			if (database === workspace) {
				writing = false;
				busy = false;
			}
		}
	}
	async function undoLastSavedChange() {
		if (!database || !undoAction || busy || navigationLoading) return;
		const workspace = database,
			action = undoAction;
		let version = editorVersion;
		let promoted = false;
		undoPaused = true;
		writing = true;
		busy = true;
		error = '';
		try {
			const receipt = await workspace.request('undo', { receiptId: action.receiptId });
			if (database !== workspace || editorVersion !== version) return;
			if (gridDraft && table === action.table && gridDraft.cell.rowId === action.rowId) {
				const cell = gridDraft;
				gridDraft = null;
				selected = receipt;
				undoPaused = false;
				if (cell.raw !== rawValue(cell.baseline[cell.cell.column])) {
					const before = rowDraft(cell.baseline);
					const reconciled = reconcileUndo(
						{ ...before, [cell.cell.column]: cell.raw },
						before,
						rowDraft(receipt)
					);
					draft = reconciled.values;
					savedDraft = reconciled.baseline;
					undoPaused = reconciled.dirty;
					editing = true;
					version = ++editorVersion;
					promoted = true;
					explicitCreation = new Set();
					for (const p of properties.filter((p) => p.type === 'ref' || p.type === 'multi_ref'))
						void loadReferences(p);
					for (const p of properties.filter(
						(p) => p.type === 'select' || p.type === 'multi_select'
					))
						void loadOptions(p);
				}
			} else if (editing && selected && table === action.table && selected.id === action.rowId) {
				const reconciled = reconcileUndo(draft, rowDraft(selected), rowDraft(receipt));
				selected = receipt;
				draft = reconciled.values;
				savedDraft = reconciled.baseline;
				undoPaused = reconciled.dirty;
			} else {
				undoPaused = dirty;
			}
			bodyFailure = '';
			notice = `Undid the last saved change in ${action.table}`;
			await refresh();
			if (promoted && database === workspace && editorVersion === version)
				await reflectLocation(true);
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
		if (!database || !selected || busy || navigationLoading) return;
		const restoring = selected.deleted_at != null;
		const preserveDraft = restoring && undoPaused;
		if (!preserveDraft && !discard()) return;
		const workspace = database,
			version = editorVersion,
			target = table;
		writing = true;
		busy = true;
		error = '';
		try {
			const receipt = await workspace.request('write', {
				table: target,
				patch: { id: selected.id, deleted_at: restoring ? null : true },
				expectedUpdatedAt: editRevision(selected)
			});
			if (database !== workspace || editorVersion !== version || table !== target) return;
			if (preserveDraft) {
				const reconciled = reconcileUndo(draft, rowDraft(selected), rowDraft(receipt));
				selected = receipt;
				draft = reconciled.values;
				savedDraft = reconciled.baseline;
				undoPaused = reconciled.dirty;
			} else {
				editorVersion++;
				editing = false;
				selected = null;
			}
			notice = restoring ? 'Record restored' : 'Moved to trash';
			await refresh();
			await reflectLocation(true);
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
		if (!database || busy || enrolling) return;
		if (!connectedHub || connectedHub.endpoint !== endpoint || connectedHub.token !== token) {
			await enrollment?.connectManual();
			return;
		}
		await syncConnection(connectedHub, () => true).catch(() => {});
	}
	async function syncConnection(candidate: HubConnection, isCurrent: () => boolean) {
		if (!database || busy || !isCurrent()) throw new Error('Connection is no longer current.');
		const workspace = database;
		const current = () => database === workspace && isCurrent();
		let connection: HubConnection | null = null;
		let accepted = false;
		let failure: unknown;
		busy = true;
		error = '';
		notice = 'Syncing';
		try {
			const hub = createHttpHub(candidate.endpoint, candidate.token, fetch);
			connection = { endpoint: hub.endpoint, token: candidate.token };
			const result = await workspace.request('sync', {
				...connection,
				maxRows,
				tables: $state.snapshot(included)
			});
			if (!current()) return;
			accepted = true;
			try {
				localStorage.setItem('life-ui:replica', JSON.stringify({ maxRows, tables: included }));
			} catch {
				/* Preference storage does not affect sync. */
			}
			notice = result.rejected.length
				? 'Some edits need attention'
				: `Synced: ${result.pulled} received, ${result.pushed} sent`;
		} catch (e) {
			if (!current()) return;
			// Core binding checks precede HTTP. A cap still permits usage/notifications.
			accepted = !!connection && message(e) === 'hub HTTP 429';
			failure = e;
			error = message(e);
			notice = 'Sync did not finish. Local records remain available.';
		} finally {
			if (current()) {
				// A refresh failure must not revoke a successfully installed credential.
				await refresh().catch(async (e) => {
					if (!current()) return;
					await loadWriteability();
					if (current()) error = `${error} Could not refresh local records: ${message(e)}`.trim();
				});
				if (current() && accepted && connection) {
					connectedHub = connection;
					endpoint = connection.endpoint;
					token = connection.token;
				}
			}
			if (database === workspace) busy = false;
		}
		if (current() && !accepted) throw failure ?? new Error('Connection failed.');
	}
	async function find() {
		offset = 0;
		try {
			await loadRows();
		} catch (e) {
			error = message(e);
		}
	}
	async function searchWorkspace(text: string, offset: number) {
		if (!database) throw new Error('Open a workspace first.');
		return database.request('search', { text, offset, limit: 50 });
	}
	async function openRecord(
		target: { table: string; id: string },
		sourceIsCurrent: () => boolean,
		preserveView = false
	) {
		if (!database || busy) return false;
		locationRequest++;
		navigationLoading = false;
		const workspace = database,
			version = editorVersion,
			request = ++recordOpenVersion;
		const current = () =>
			database === workspace &&
			version === editorVersion &&
			request === recordOpenVersion &&
			!busy &&
			sourceIsCurrent();
		let found: Row[];
		try {
			// Picker labels and saved-view projections are not editable record snapshots.
			found = await workspace.request('rows', {
				view: {
					table: target.table,
					filters: [{ column: 'id', op: 'eq', value: target.id }],
					trash: preserveView && trash,
					limit: 1
				}
			});
		} catch (e) {
			if (current()) throw e;
			return false;
		}
		if (!current()) return false;
		if (!found[0])
			throw new Error(
				'This record is not available locally. It may be missing, in the trash, or outside this replica.'
			);
		if (!discard()) return false;
		locationRequest++;
		navigationLoading = false;
		if (preserveView && table === target.table) editing = false;
		else resetView();
		table = target.table;
		graphVisible = false;
		edit(found[0], false);
		showFind(false);
		const openedVersion = editorVersion;
		await tick();
		if (database !== workspace || editorVersion !== openedVersion) return false;
		recordHeading?.focus();
		let loaded = true;
		await Promise.all([loadRows(), loadViews(), loadWriteability()]).catch((e) => {
			loaded = false;
			if (database === workspace && editorVersion === openedVersion) error = message(e);
		});
		if (database !== workspace || editorVersion !== openedVersion) return false;
		await reflectLocation();
		if (loaded && database === workspace && editorVersion === openedVersion) recordRecent();
		return true;
	}
	function openSearchHit(hit: SearchHit) {
		const version = findVersion;
		return openRecord(hit, () => findVisible && findVersion === version);
	}
	function openSearchDestination(destination: PaletteDestination): Promise<boolean> {
		const version = findVersion;
		return openDestination(
			{
				table: destination.table,
				view: destination.kind === 'view' ? destination.id : null,
				row: null
			},
			() => findVisible && findVersion === version
		);
	}
	async function openDestination(
		destination: Destination,
		sourceIsCurrent: () => boolean,
		reservedRequest?: number
	): Promise<boolean> {
		if (!database || busy || writing || bodySaving) return false;
		const workspace = database,
			sourceEditor = editorVersion,
			request = reservedRequest ?? ++recordOpenVersion;
		const current = () =>
			database === workspace &&
			editorVersion === sourceEditor &&
			request === recordOpenVersion &&
			sourceIsCurrent();
		let resolved;
		try {
			resolved = await resolveDestination(workspace, destination, table);
		} catch (e) {
			if (current()) throw e;
			return false;
		}
		if (!current() || busy || writing || bodySaving || !discard()) return false;
		locationRequest++;
		navigationLoading = false;
		resetView();
		catalog = resolved.catalog;
		table = resolved.table;
		graphVisible = false;
		applyView(resolved.view);
		if (resolved.row) {
			trash = !!resolved.row.deleted_at;
			edit(resolved.row, false);
		}
		showFind(false);
		const openedVersion = editorVersion;
		let loaded = true;
		await Promise.all([loadRows(), loadViews(), loadWriteability()]).catch((e) => {
			loaded = false;
			if (database === workspace && editorVersion === openedVersion) error = message(e);
		});
		if (database !== workspace || editorVersion !== openedVersion) return false;
		await reflectLocation();
		if (database !== workspace || editorVersion !== openedVersion) return false;
		if (loaded) recordRecent();
		if (resolved.row) {
			await tick();
			recordHeading?.focus();
		}
		return true;
	}
	async function openSourceLink(url: string): Promise<boolean> {
		if (!database || busy || writing || bodySaving)
			throw Error('Wait for the current save, then open the link again.');
		const workspace = database,
			version = editorVersion,
			request = ++recordOpenVersion;
		const current = () =>
			database === workspace &&
			editorVersion === version &&
			recordOpenVersion === request &&
			(editing || !!gridDraft) &&
			!findVisible;
		try {
			const { destination } = await workspace.request('resolveSourceLink', { url });
			if (!current()) throw new DOMException('Navigation superseded', 'AbortError');
			if (!destination) return false;
			// Web Markdown publishes each transaction synchronously. The shared
			// destination guard checks that live draft immediately before discard;
			// opening a link never commits an inline cell or replaces its source.
			const opened = await openDestination({ ...destination, view: null }, current, request);
			if (!opened) throw new DOMException('Navigation canceled', 'AbortError');
			return opened;
		} catch (reason) {
			if (!current()) throw new DOMException('Navigation superseded', 'AbortError');
			throw reason;
		}
	}
	async function openRelatedRecord(
		target: { table: string; id: string },
		button: HTMLButtonElement
	) {
		if (!target.table || busy || relationOpening === editorVersion) return;
		const workspace = database,
			version = editorVersion;
		const current = () =>
			database === workspace && editorVersion === version && editing && !findVisible;
		relationOpening = version;
		error = '';
		try {
			await openRecord(target, current);
		} catch (e) {
			if (current()) error = message(e);
		} finally {
			if (relationOpening === version) relationOpening = null;
			await tick();
			if (current() && !busy && button.isConnected) button.focus();
		}
	}
	onDestroy(() => {
		locationRequest++;
		editorVersion++;
		database?.close();
		database = null;
		recentsRequest++;
	});
</script>

{#snippet undoButton()}
	<button
		type="button"
		class="secondary"
		onclick={undoLastSavedChange}
		disabled={!undoAction || busy || navigationLoading}
		title={undoAction
			? `Last saved change in ${undoAction.table}`
			: 'No saved change to undo in this session'}
		><IconArrowBackUp size={16} />Undo last saved change</button
	>
{/snippet}

<svelte:head><title>Workspace | Life UI</title></svelte:head>
<svelte:window
	onkeydown={(event) => {
		if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k' && opened) {
			event.preventDefault();
			if (!busy && !findVisible && !onlineBrowser) showFind(true);
		}
	}}
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
	{#if onlineBrowser && database === onlineBrowser.workspace && table === onlineBrowser.table && connectedHub === onlineBrowser.connection}
		{@const context = onlineBrowser}
		<RemoteBrowser
			table={context.table}
			properties={catalog.properties.filter((p) => p.tbl === context.table)}
			readPage={(cursor) =>
				context.workspace.request('remoteRows', {
					...context.connection,
					table: context.table,
					limit: 50,
					...(cursor === undefined ? {} : { cursor })
				})}
			readRow={(id) =>
				context.workspace.request('remoteRow', { ...context.connection, table: context.table, id })}
			onclose={() => {
				onlineBrowser = null;
			}}
		/>
	{/if}
	{#if findVisible}
		<SearchDialog
			search={searchWorkspace}
			onchoose={openSearchHit}
			onclose={() => showFind(false)}
			incomplete={skipped.length > 0}
			destinations={findNavigation.destinations}
			navigationLoading={findNavigation.loading}
			navigationError={findNavigation.error}
			onnavigate={openSearchDestination}
		/>
	{/if}
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
				<button class="secondary" onclick={() => showFind(true)} disabled={busy}
					><IconSearch size={16} /> Find records <kbd>⌘K</kbd></button
				>
				<SidebarTables
					tables={catalog.tables}
					current={table}
					disabled={busy || writing || bodySaving}
					onchoose={changeTable}
				/>
				<SidebarRecents
					entries={recentEntries}
					current={currentDestination()}
					busy={busy || writing || bodySaving}
					storageError={[recentReadError, recentStorageError].filter(Boolean).join(' ')}
					onchoose={openRecent}
					onremove={removeRecent}
				/>
				<button
					class="secondary"
					onclick={() => {
						if (closeRecord()) {
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
						<summary>Connect to a hub</summary>
						{#if database}{#key database}<HubEnrollment
									core={database}
									bind:this={enrollment}
									bind:endpoint
									bind:token
									bind:pending={enrolling}
									disabled={busy}
									onconnect={syncConnection}
								/>{/key}{/if}
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
						<button onclick={syncNow} disabled={busy || enrolling || !endpoint || !token}
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
						recentsRequest++;
						recentDestinations = [];
						recentEntries = [];
						opened = false;
						showFind(false);
						resetView();
						token = '';
					}}>Switch workspace</button
				>
			</aside>
			<main class="records">
				{#if !editing && (table || undoAction)}<div class="link-toolbar">
						{#if table && !editing}
							<button
								class="secondary"
								onclick={copyLink}
								disabled={navigationLoading || (editing && !selected)}
								><IconLink size={16} /> Copy link</button
							>
						{/if}
						{@render undoButton()}
					</div>{/if}
				{#if navigationLoading}<p role="status" class="hint">Opening link…</p>{/if}
				{#if error}<p role="alert" class="failure">{error}</p>{/if}
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
								disabled={busy || writing || bodySaving || !connectedHub || !online}
								onclick={() => {
									if (database && connectedHub)
										onlineBrowser = { workspace: database, table, connection: connectedHub };
								}}>Browse online</button
							>
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
						<button
							onclick={newGridRecord}
							disabled={busy || navigationLoading || !table || readOnly || blocked || trash}
							><IconPlus size={17} />New record</button
						>
					</header>
					{#if !table}<div class="empty">
							Connect to your hub in the sidebar and sync to bring your tables to this device.
						</div>{/if}
					{#if table}
						{#key table}
							<div class="saved-views-panel">
								<SavedViews
									list={savedViews}
									unavailable={viewsUnavailable}
									{busy}
									selected={chosenView?.id ?? null}
									modified={viewModified}
									onchoose={chooseView}
									onsave={saveNamedView}
									ondelete={deleteNamedView}
								/>
							</div>
						{/key}
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
									if (!closeRecord()) return;
									trash = !trash;
									offset = 0;
									loadRows().catch((e) => (error = message(e)));
								}}><IconTrash size={16} />{trash ? 'All records' : 'Trash'}</button
							>
							<ExportPanel
								snapshot={exportSnapshot}
								disabled={busy ||
									navigationLoading ||
									exportRefreshes > 0 ||
									exportContext !== currentExportContext}
							/>
						</div>
						<PresentationControls
							value={presentation}
							{properties}
							disabled={busy || navigationLoading}
							onchange={(value) => {
								if (!closeRecord()) return;
								presentation = value;
								loadBoardOptions();
							}}
						/>
						<ViewControls
							properties={viewProperties}
							sorts={sortClauses}
							{filters}
							groups={filterGroups}
							{actions}
							layout={actionLayout}
							{timeZone}
							{dayStartMinutes}
							{actionOptions}
							{actionReferences}
							onactionsearch={loadActionReferences}
							columns={[display ?? 'id', ...visibleColumns]}
							disabled={busy || navigationLoading}
							onchange={(patch) => {
								if (!closeRecord()) return;
								if (patch.sorts) importedSort = patch.sorts;
								if (patch.groups) filterGroups = patch.groups;
								if (patch.filters) filters = patch.filters;
								if (patch.actions) actions = patch.actions;
								if (patch.layout) actionLayout = patch.layout;
								if (patch.timeZone !== undefined) timeZone = patch.timeZone;
								if (patch.dayStartMinutes !== undefined) dayStartMinutes = patch.dayStartMinutes;
								offset = 0;
								loadRows().catch((e) => (error = message(e)));
							}}
						/>

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
										><option value="lt">less than</option>{:else if filterType !== 'bool'}<option
											value="contains">contains</option
										>{/if}</select
								>
								{#if !['empty', 'not_empty'].includes(filterOp)}
									{#if filterType === 'bool'}
										<select aria-label="Filter value" bind:value={filterValue}>
											<option value="">Choose a value</option>
											<option value="true">True</option>
											<option value="false">False</option>
										</select>
									{:else}<input aria-label="Filter value" bind:value={filterValue} />{/if}{/if}{/if}
							<button class="secondary" type="submit">Apply filter</button>
						</form>
						<ColumnSettings
							properties={columnChoices}
							columns={visibleColumns}
							{widths}
							onChange={changeColumns}
						/>
						{#if filters.length}
							<div class="active-filters" role="group" aria-label="Active filters">
								<span>Match all</span>
								{#each filters as filter, index}
									<button
										class="secondary filter-chip"
										aria-label={`Remove filter ${index + 1}: ${describeFilter(filter)}`}
										onclick={() => removeFilter(index)}
										>{describeFilter(filter)}<IconX size={14} /></button
									>
								{/each}
								<button class="secondary" onclick={() => removeFilter()}>Clear filters</button>
							</div>
						{/if}
						{#if blocked}<p role="status" aria-label="Editing availability" class="notice">
								{writePermission?.reason?.message ?? 'Checking editing rules…'}
							</p>{/if}
						{#key database}
							{#if database}<RejectedEdits
									core={database}
									total={rejectedCount}
									snapshot={rejected}
									disabled={busy || writing || bodySaving || navigationLoading}
									onreview={reviewRejected}
								/>{/if}
						{/key}
						{#if presentation.kind !== 'table'}
							<RecordPresentations
								{presentation}
								{rows}
								{properties}
								{display}
								{timeZone}
								{dayStartMinutes}
								options={optionValues[presentation.groupColumn ?? ''] ?? []}
								canMove={!busy &&
									!navigationLoading &&
									!dirty &&
									!!properties.find((p) => p.col === presentation.groupColumn && canEditCell(p))}
								onmove={moveBoardRecord}
								resolveFile={resolveRetainedFile}
								onopen={(id) =>
									openRecord({ table, id }, () => !findVisible, true).catch((e) => {
										error = message(e);
										return false;
									})}
							/>
						{:else}
							{#key gridContext}
								<RecordGrid
									{rows}
									{actions}
									{actionLayout}
									canRunAction={!!chosenView &&
										!viewModified &&
										!blocked &&
										!readOnly &&
										!trash &&
										!navigationLoading}
									onaction={runSavedAction}
									properties={gridColumns}
									{widths}
									busy={busy || gridActionOpening !== null}
									canCreate={!navigationLoading && !readOnly && !blocked && !trash}
									canTrash={!navigationLoading && !readOnly && !blocked}
									{trash}
									bind:edit={gridDraft}
									format={(p, value) => cell(p, value)}
									canEdit={(p) => !navigationLoading && canEditCell(p)}
									onbegin={beginCell}
									oncommit={commitCell}
									resolveFile={resolveRetainedFile}
									onopenlink={openSourceLink}
									onopen={(id) =>
										openRecord({ table, id }, () => !findVisible, true).catch((e) => {
											error = message(e);
											return false;
										})}
									onnew={newGridRecord}
									onduplicate={duplicateRecord}
									ontrash={trashGridRecord}
									options={optionValues}
									referenceOptions={(p) =>
										(references[p.col] ?? []).map((row) => ({
											id: String(row.id),
											label: refTitle(p, row)
										}))}
									onsearch={loadReferences}
								/>
							{/key}
						{/if}
						{#if gridActionOpening !== null}<p role="status">Opening record action…</p>{/if}
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
							<h2 bind:this={recordHeading} tabindex="-1">
								{selected ? title(selected) : 'Untitled'}
							</h2>
						</div>
						<div class="record-navigation">
							<button
								class="icon-button secondary"
								aria-label="Copy link"
								title="Copy link"
								disabled={navigationLoading || !selected}
								onclick={copyLink}><IconLink size={18} /></button
							>
							<button class="icon-button secondary" aria-label="Close record" onclick={closeRecord}
								><IconX size={18} /></button
							>
						</div>
					</header>
					{#if undoPaused}<p class="hint" role="status" aria-label="Draft review">
							Your unsaved draft is kept. {selected?.deleted_at != null
								? 'Restore the record, then review and save your draft.'
								: 'Review it and choose Save record to continue.'} Body autosave is paused.
						</p>{/if}
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

								{#key editorVersion}
									<FieldEditor
										id={`field-${p.col}`}
										property={p}
										resolveFile={resolveRetainedFile}
										onopenlink={openSourceLink}
										bind:value={draft[p.col]}
										onchange={() => {
											if (!selected) explicitCreation = new Set([...explicitCreation, p.col]);
										}}
										disabled={locked(p)}
										showReferenceSelections={false}
										options={optionValues[p.col]}
										references={(references[p.col] ?? []).map((row) => ({
											id: String(row.id),
											label: refTitle(p, row)
										}))}
										onsearch={(query) => loadReferences(p, query)}
									/>
								{/key}
								{#if p.type === 'ref' || p.type === 'multi_ref'}
									<div
										class="relation-links"
										role="group"
										aria-label={`${label(p)} related records`}
									>
										{#each p.type === 'ref' ? [draft[p.col]].filter(Boolean) : list(draft[p.col]) as id}
											{@const related = (references[p.col] ?? []).find((row) => row.id === id)}
											{@const available =
												!!p.ref_table && catalog.tables.some((target) => target.id === p.ref_table)}
											<div class="relation">
												<button
													type="button"
													class="secondary relation-open"
													aria-label={`Open ${refTitle(p, related ?? { id })}`}
													disabled={busy || relationOpening === editorVersion || !available}
													onclick={(event) =>
														openRelatedRecord({ table: p.ref_table!, id }, event.currentTarget)}
												>
													<span>{refTitle(p, related ?? { id })}</span><IconArrowUpRight
														size={16}
														aria-hidden="true"
													/>
												</button>
												{#if p.type === 'multi_ref'}
													<button
														type="button"
														class="secondary relation-remove"
														disabled={locked(p)}
														aria-label={`Remove ${refTitle(p, related ?? { id })}`}
														onclick={() => {
															draft[p.col] = JSON.stringify(
																list(draft[p.col]).filter((value) => value !== id)
															);
															if (!selected)
																explicitCreation = new Set([...explicitCreation, p.col]);
														}}
													>
														<IconX size={16} aria-hidden="true" />
													</button>
												{/if}
											</div>
											{#if !available}<span class="hint"
													>Related table is not available on this device.</span
												>{/if}
										{/each}
									</div>
								{/if}
								{#if p.derived_by?.startsWith('http:') && !p.deprecated}
									<button
										type="button"
										class="secondary"
										aria-label={`Resolve ${label(p)}`}
										disabled={!selected ||
											selected.deleted_at != null ||
											!connectedHub ||
											busy ||
											writing ||
											bodySaving ||
											navigationLoading ||
											readOnly ||
											blocked}
										onclick={() => resolveField(p)}>Resolve</button
									>
									{#if !connectedHub}<span class="hint">Connect to the hub to resolve.</span>{/if}
								{/if}
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
							{@render undoButton()}
							{#if selected && selected.deleted_at == null}<button
									type="button"
									class="secondary"
									disabled={busy || navigationLoading || readOnly || blocked}
									onclick={() => duplicateRecord(String(selected!.id))}>Duplicate record</button
								>{/if}
							<button
								type="submit"
								disabled={busy ||
									navigationLoading ||
									readOnly ||
									blocked ||
									selected?.deleted_at != null}><IconDeviceFloppy size={17} />Save record</button
							>{#if selected}<button
									type="button"
									class="secondary"
									onclick={toggleTrash}
									disabled={busy || navigationLoading || readOnly || blocked}
									>{selected.deleted_at != null ? 'Restore record' : 'Move to trash'}</button
								>{/if}
						</div>
					</form>
					{#if selected && database}{#key `${editorVersion}:${selected.id}:${JSON.stringify([catalog, skipped])}`}<IncomingReferences
								core={database}
								{table}
								rowId={String(selected.id)}
								disabled={busy || navigationLoading || relationOpening === editorVersion}
								onopen={openRelatedRecord}
							/>{/key}{/if}
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
	input {
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
		min-width: 0;
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
	.link-toolbar {
		display: flex;
		justify-content: flex-end;
		margin-bottom: 8px;
	}
	.relation-links {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		margin-top: 8px;
	}
	.relation {
		display: flex;
		align-items: center;
		gap: 4px;
		max-width: 100%;
	}
	.relation-open {
		min-width: 0;
		max-width: 100%;
		text-align: left;
	}
	.relation-open span {
		min-width: 0;
		overflow-wrap: anywhere;
	}
	.relation-open :global(svg) {
		flex: none;
	}
	.relation-remove {
		flex: none;
		min-width: 36px;
		min-height: 36px;
		padding: 6px;
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
	.active-filters {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 8px;
		margin: 0 0 20px;
		font-size: 0.8rem;
		color: var(--color-muted);
	}
	.filter-chip {
		max-width: 100%;
		overflow-wrap: anywhere;
		text-align: left;
	}
	.saved-views-panel {
		margin-bottom: 20px;
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
	select {
		border: 1px solid var(--color-rule);
		border-radius: 6px;
		padding: 9px 10px;
		background: var(--color-paper);
		color: var(--color-ink);
		font-size: 13px;
		min-height: 38px;
	}
	select {
		max-width: 100%;
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
	.notice {
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
	.record-navigation {
		display: flex;
		align-items: start;
		gap: 6px;
		flex-shrink: 0;
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
	}
</style>
