import { hubBackupRoute, type BackupSummary, type HubBackup } from 'iris-core/client';

export type RestoreRow = {
	table: string;
	backupRows: number | null;
	backupLive: number | null;
	currentRows: number | null;
	currentLive: number | null;
	change: 'added' | 'removed' | 'changed' | 'same';
};

/** One row per table in either summary; restore replaces the current set with the backup's. */
export function restoreRows(backup: BackupSummary, current: BackupSummary): RestoreRow[] {
	const names = [...new Set([...backup.tables, ...current.tables].map((t) => t.table))].sort();
	return names.map((table) => {
		const b = backup.tables.find((t) => t.table === table);
		const c = current.tables.find((t) => t.table === table);
		return {
			table,
			backupRows: b?.rows ?? null,
			backupLive: b?.liveRows ?? null,
			currentRows: c?.rows ?? null,
			currentLive: c?.liveRows ?? null,
			change: !c
				? 'added'
				: !b
					? 'removed'
					: b.rows === c.rows &&
						  b.liveRows === c.liveRows &&
						  b.newestUpdatedAt === c.newestUpdatedAt
						? 'same'
						: 'changed'
		};
	});
}

export function formatBytes(bytes: number): string {
	const units = ['bytes', 'KB', 'MB', 'GB'];
	let value = bytes,
		unit = 0;
	while (value >= 1000 && unit < units.length - 1) {
		value /= 1000;
		unit++;
	}
	return `${unit ? value.toLocaleString(undefined, { maximumFractionDigits: 1 }) : value} ${units[unit]}`;
}

export function backupMessage(error: unknown): string {
	const text = error instanceof Error ? error.message : String(error);
	if (text === 'hub HTTP 429') return 'Back up now runs at most once an hour. Try again later.';
	if (text === 'hub HTTP 403')
		return 'This connection cannot use hub backups. Its credential needs backup access.';
	return text || 'The backup action failed.';
}

const hex = (buffer: ArrayBuffer) =>
	[...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, '0')).join('');

/** Downloads one hub backup's gzip bytes and checks them against the listed SHA-256. */
export async function downloadHubBackup(
	connection: { endpoint: string; token: string },
	backup: HubBackup,
	fetcher: typeof fetch = fetch
): Promise<Blob> {
	const response = await fetcher(
		connection.endpoint.replace(/\/+$/, '') + hubBackupRoute(backup.key),
		{
			headers: { Authorization: `Bearer ${connection.token}` },
			redirect: 'error',
			credentials: 'omit'
		}
	);
	if (!response.ok) throw new Error(`hub HTTP ${response.status}`);
	const blob = await response.blob();
	if (blob.size !== backup.bytes) throw new Error('The downloaded backup is incomplete.');
	if (
		backup.sha256 &&
		hex(await crypto.subtle.digest('SHA-256', await blob.arrayBuffer())) !== backup.sha256
	)
		throw new Error('The downloaded backup does not match its checksum.');
	return new Blob([blob], { type: 'application/gzip' });
}

/** Saves a Blob through the browser's download flow. */
export function saveBlob(blob: Blob, name: string) {
	const url = URL.createObjectURL(blob);
	const link = Object.assign(document.createElement('a'), { href: url, download: name });
	document.body.appendChild(link);
	link.click();
	link.remove();
	setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
