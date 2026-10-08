<script lang="ts">
	import { IconDatabaseExport, IconDownload, IconRestore, IconX } from '@tabler/icons-svelte';
	import type { HubBackup, RestorePreview } from 'life-ui-core/client';
	import type { WorkspaceDatabase } from './database';
	import {
		backupMessage,
		downloadHubBackup,
		formatBytes,
		restoreRows,
		saveBlob,
		type RestoreRow
	} from './backup';

	let {
		database,
		connection,
		demo,
		canRestore,
		onactivity,
		onrestored
	}: {
		database: WorkspaceDatabase;
		connection: { endpoint: string; token: string } | null;
		demo: boolean;
		/** False while drafts or local edits wait; a restore would discard them. */
		canRestore: boolean;
		onactivity(label: string): void;
		onrestored(): void;
	} = $props();

	let dialog: HTMLDialogElement;
	let busy = $state('');
	let done = $state('');
	let failure = $state('');
	let hub = $state<HubBackup[] | null>(null);
	let hubError = $state('');
	let recovery = $state<{ file: string; bytes: number; modified: number }[]>([]);
	let preview = $state<{
		source: string;
		file: string;
		data: RestorePreview;
		rows: RestoreRow[];
	} | null>(null);
	let confirm = $state('');
	let progress = $state<{ phase: string; done: number; total: number } | null>(null);
	const percent = $derived(
		progress?.total ? Math.min(100, Math.floor((progress.done / progress.total) * 100)) : null
	);
	const when = (iso: string | number) => new Date(iso).toLocaleString();
	// A plain copy: the worker cannot structured-clone a reactive proxy.
	const hubArgs = () => ({ endpoint: connection!.endpoint, token: connection!.token });

	$effect(() => {
		const listener = (event: Event) => {
			progress = (event as CustomEvent).detail;
		};
		database.addEventListener('progress', listener);
		return () => database.removeEventListener('progress', listener);
	});
	$effect(() => {
		onactivity(busy ? (percent === null ? busy : `${progress?.phase ?? busy} ${percent}%`) : '');
	});

	export async function open() {
		failure = done = '';
		preview = null;
		dialog.showModal();
		await Promise.all([loadRecovery(), loadHub()]);
	}
	async function loadRecovery() {
		recovery = await database.request('recoveryBackups').catch(() => []);
	}
	async function loadHub() {
		if (!connection || demo) return;
		hubError = '';
		try {
			hub = (await database.request('hubBackups', hubArgs())).backups;
		} catch (e) {
			hubError = backupMessage(e);
		}
	}
	async function run(label: string, work: () => Promise<string | void>) {
		if (busy) return;
		busy = label;
		progress = null;
		failure = done = '';
		try {
			done = (await work()) ?? '';
		} catch (e) {
			failure = backupMessage(e);
		} finally {
			busy = '';
			progress = null;
		}
	}
	const downloadReplica = () =>
		run('Copying database', async () => {
			const file = await database.request('replicaFile');
			saveBlob(file, demo ? 'life-ui-sample.sqlite' : 'life-ui.sqlite');
			return `Downloaded the SQLite database (${formatBytes(file.size)}).`;
		});
	const exportDump = () =>
		run('Exporting', async () => {
			const { file, summary } = await database.request('exportReplica');
			saveBlob(file, file.name);
			return `Exported ${summary.rows.toLocaleString()} rows from ${summary.tables.length} tables (${formatBytes(file.size)}).`;
		});
	const backUpNow = () =>
		run('Backing up on the hub', async () => {
			const backup = await database.request('createHubBackup', hubArgs());
			await loadHub();
			return `The hub saved a backup (${formatBytes(backup.bytes)}).`;
		});
	const downloadHub = (backup: HubBackup) =>
		run('Downloading', async () => {
			saveBlob(await downloadHubBackup(connection!, backup), backup.key.split('/').pop()!);
			return `Downloaded ${backup.key} (${formatBytes(backup.bytes)}), checksum verified.`;
		});
	async function stagePreview(source: string, blob: Blob, name: string) {
		const file = await database.request('stageBackup', { blob, name });
		const data = await database.request('previewRestore', { file });
		preview = { source, file, data, rows: restoreRows(data.backup, data.current) };
		confirm = '';
	}
	const previewHub = (backup: HubBackup) =>
		run('Downloading', async () => {
			await stagePreview(
				`Hub backup ${when(backup.taken_at)}`,
				await downloadHubBackup(connection!, backup),
				backup.key.split('/').pop()!
			);
		});
	const previewRecovery = (entry: { file: string; modified: number }) =>
		run('Checking backup', async () => {
			const file = await database.request('backupFile', { file: entry.file });
			await stagePreview(`Recovery copy from ${when(entry.modified)}`, file, file.name);
		});
	function previewFile(event: Event) {
		const input = event.currentTarget as HTMLInputElement;
		const file = input.files?.[0];
		input.value = '';
		if (file) void run('Checking backup', () => stagePreview(`File ${file.name}`, file, file.name));
	}
	const restore = () =>
		run('Restoring', async () => {
			const result = await database.request('restoreReplica', {
				file: preview!.file,
				confirm: 'replace'
			});
			preview = null;
			await loadRecovery();
			onrestored();
			return `Restored ${result.restored.rows.toLocaleString()} rows from ${result.restored.tables.length} tables. The previous replica is saved as a recovery copy below.`;
		});
</script>

<button class="open" onclick={() => open()}><IconDatabaseExport size={17} /> Backup</button>

<dialog
	bind:this={dialog}
	aria-labelledby="backup-title"
	oncancel={(event) => {
		if (busy) event.preventDefault();
	}}
>
	<header>
		<div>
			<h2 id="backup-title">Backup</h2>
			<p class="muted">Copies of this workspace, and restoring one in its place.</p>
		</div>
		<button aria-label="Close" disabled={!!busy} onclick={() => dialog.close()}
			><IconX size={20} /></button
		>
	</header>

	<div class="status" aria-live="polite">
		{#if busy}
			<p>{progress?.phase ?? busy}{percent === null ? '…' : ` ${percent}%`}</p>
		{:else if done}<p class="ok">{done}</p>{/if}
		{#if failure}<p role="alert" class="failure">{failure}</p>{/if}
	</div>

	{#if preview}
		<section aria-labelledby="preview-title">
			<h3 id="preview-title">Restore preview</h3>
			<p>
				{preview.source}. Backup newest change: {preview.data.backup.newestUpdatedAt
					? when(preview.data.backup.newestUpdatedAt)
					: 'none'}; this device: {preview.data.current.newestUpdatedAt
					? when(preview.data.current.newestUpdatedAt)
					: 'none'}.
			</p>
			<div class="table-scroll">
				<table>
					<thead>
						<tr><th>Table</th><th>Backup rows</th><th>On this device</th><th>Result</th></tr>
					</thead>
					<tbody>
						{#each preview.rows as row (row.table)}
							<tr data-change={row.change}>
								<td>{row.table}</td>
								<td
									>{row.backupRows === null
										? '-'
										: `${row.backupRows.toLocaleString()} (${row.backupLive?.toLocaleString()} live)`}</td
								>
								<td
									>{row.currentRows === null
										? '-'
										: `${row.currentRows.toLocaleString()} (${row.currentLive?.toLocaleString()} live)`}</td
								>
								<td
									>{{ added: 'Added', removed: 'Removed', changed: 'Replaced', same: 'Unchanged' }[
										row.change
									]}</td
								>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
			<p class="warning">
				Restoring replaces every table on this device with the backup. A recovery copy of the
				current replica is saved first. The next sync uploads the restored rows; rows changed on the
				hub after this backup keep their newer versions.
			</p>
			{#if !canRestore}
				<p class="failure">Save or discard open edits and wait for local changes to sync first.</p>
			{/if}
			<label for="restore-confirm">Type <strong>replace</strong> to confirm</label>
			<div class="actions">
				<input
					id="restore-confirm"
					autocomplete="off"
					spellcheck="false"
					bind:value={confirm}
					disabled={!!busy}
				/>
				<button
					class="danger"
					disabled={confirm !== 'replace' || !canRestore || !!busy}
					onclick={restore}><IconRestore size={17} /> Restore</button
				>
				<button disabled={!!busy} onclick={() => (preview = null)}>Cancel</button>
			</div>
		</section>
	{:else}
		<section aria-labelledby="device-title">
			<h3 id="device-title">This device</h3>
			<div class="row">
				<button disabled={!!busy} onclick={downloadReplica}
					><IconDownload size={17} /> Download replica</button
				>
				<p class="muted">The SQLite database stored in this browser.</p>
			</div>
			<div class="row">
				<button disabled={!!busy} onclick={exportDump}
					><IconDownload size={17} /> Export SQL dump</button
				>
				<p class="muted">
					Portable SQL, the same shape as <code>life export</code>. Import it with
					<code>sqlite3 life.db &lt; dump.sql</code>.
				</p>
			</div>
		</section>

		{#if connection && !demo}
			<section aria-labelledby="hub-title">
				<div class="actions">
					<h3 id="hub-title">Hub backups</h3>
					<button disabled={!!busy} onclick={backUpNow}>Back up now</button>
				</div>
				{#if hubError}<p role="alert" class="failure">{hubError}</p>{/if}
				{#if hub && !hub.length}<p class="muted">The hub has no backups yet.</p>{/if}
				{#if hub?.length}
					<ul class="list">
						{#each hub as backup (backup.key)}
							<li>
								<span
									>{when(backup.taken_at)}<small
										>{backup.key.split('/')[0]} · {formatBytes(backup.bytes)}</small
									></span
								>
								<button disabled={!!busy} onclick={() => downloadHub(backup)}
									>Download<span class="sr-only">: {backup.key}</span></button
								>
								<button disabled={!!busy} onclick={() => previewHub(backup)}
									>Restore…<span class="sr-only">: {backup.key}</span></button
								>
							</li>
						{/each}
					</ul>
				{/if}
			</section>
		{/if}

		<section aria-labelledby="file-title">
			<h3 id="file-title">Restore from a file</h3>
			<p class="muted">
				A <code>.sql</code> or <code>.sql.gz</code> dump. It is checked before anything changes.
			</p>
			<input
				type="file"
				accept=".sql,.gz,application/sql,application/gzip"
				aria-label="Choose a backup file"
				disabled={!!busy}
				onchange={previewFile}
			/>
		</section>

		{#if recovery.length}
			<section aria-labelledby="recovery-title">
				<h3 id="recovery-title">Recovery copies</h3>
				<p class="muted">Saved before each restore. Restore one to undo.</p>
				<ul class="list">
					{#each recovery as entry (entry.file)}
						<li>
							<span>{when(entry.modified)}<small>{formatBytes(entry.bytes)}</small></span>
							<button
								disabled={!!busy}
								onclick={() =>
									run('Downloading', async () => {
										const file = await database.request('backupFile', { file: entry.file });
										saveBlob(file, file.name);
									})}>Download<span class="sr-only">: recovery copy</span></button
							>
							<button disabled={!!busy} onclick={() => previewRecovery(entry)}
								>Restore…<span class="sr-only">: recovery copy</span></button
							>
						</li>
					{/each}
				</ul>
			</section>
		{/if}
	{/if}
</dialog>

<style>
	button {
		display: inline-flex;
		align-items: center;
		gap: 0.5rem;
		min-height: 38px;
		padding: 0.4rem 0.65rem;
		color: var(--color-ink);
		background: var(--color-paper);
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		cursor: pointer;
		white-space: nowrap;
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	.open {
		width: 100%;
	}
	.danger:not(:disabled) {
		color: var(--color-on-accent);
		background: var(--color-violation);
		border-color: var(--color-violation);
	}
	dialog {
		width: min(760px, calc(100vw - 2rem));
		max-height: calc(100dvh - 2rem);
		margin: auto;
		padding: 1.5rem;
		color: var(--color-ink);
		background: var(--color-paper);
		border: 1px solid var(--color-rule);
		border-radius: 0.75rem;
		overflow-y: auto;
	}
	dialog::backdrop {
		background: #0007;
	}
	header {
		display: flex;
		justify-content: space-between;
		align-items: start;
		gap: 1rem;
	}
	h2 {
		margin: 0;
		font-size: 1.5rem;
		font-weight: 650;
	}
	h3 {
		margin: 0 0 0.5rem;
		font-size: 1.1rem;
		font-weight: 600;
	}
	section {
		margin-top: 1.25rem;
		padding-top: 1rem;
		border-top: 1px solid var(--color-rule);
	}
	p {
		margin: 0.4rem 0;
		line-height: 1.5;
	}
	.muted,
	small {
		color: var(--color-muted);
		font-size: 0.85rem;
	}
	.failure {
		color: var(--color-violation);
	}
	.ok {
		color: var(--color-valid);
	}
	.warning {
		padding: 0.6rem 0.8rem;
		border-left: 3px solid var(--color-violation);
		background: var(--color-bone);
	}
	.row {
		display: flex;
		align-items: center;
		gap: 0.8rem;
		flex-wrap: wrap;
		margin: 0.5rem 0;
	}
	.row p {
		flex: 1 1 16rem;
		margin: 0;
	}
	.actions {
		display: flex;
		gap: 0.5rem;
		align-items: center;
		flex-wrap: wrap;
	}
	.actions h3 {
		margin: 0 auto 0 0;
	}
	input:not([type='file']) {
		min-height: 38px;
		padding: 0.4rem 0.6rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
	}
	label {
		display: block;
		margin: 0.6rem 0 0.3rem;
	}
	.list {
		list-style: none;
		margin: 0.5rem 0 0;
		padding: 0;
	}
	.list li {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		padding: 0.5rem 0;
		border-bottom: 1px solid var(--color-rule);
	}
	.list li > span {
		display: grid;
		margin-right: auto;
		font-variant-numeric: tabular-nums;
	}
	.table-scroll {
		overflow-x: auto;
	}
	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 0.9rem;
		font-variant-numeric: tabular-nums;
	}
	th,
	td {
		padding: 0.35rem 0.5rem;
		border-bottom: 1px solid var(--color-rule);
		text-align: left;
	}
	tr[data-change='removed'] td,
	tr[data-change='added'] td:last-child {
		color: var(--color-violation);
	}
	code {
		font-size: 0.85em;
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
		white-space: nowrap;
	}
</style>
