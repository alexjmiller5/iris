import type { SearchTable } from 'iris-core/client';
import { formatBytes } from './backup';

/** One line under a table's switch: what indexing it costs and why its default is off. */
export function searchTableDetail(table: SearchTable, sizeLimit: number): string {
	const parts = [
		`${table.rows.toLocaleString()} ${table.rows === 1 ? 'record' : 'records'}`,
		`about ${formatBytes(table.textBytes)} of text`
	];
	if (table.defaultExclusion === 'provenance') parts.push('Off by default: provenance links');
	if (table.defaultExclusion === 'size')
		parts.push(`Off by default: over ${sizeLimit.toLocaleString()} records`);
	return parts.join(' · ');
}

/** The stored choice for a switch: matching the default clears it, so the table follows it again. */
export function searchChoice(table: SearchTable, indexed: boolean): boolean | null {
	return indexed === !table.defaultExclusion ? null : indexed;
}
