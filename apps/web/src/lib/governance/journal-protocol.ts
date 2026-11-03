import type { PendingApproval } from './api';
import type { PendingChangeset } from './changeset-journal';
export type JournalKind = 'governance' | 'changesets';
export type JournalEntry<K extends JournalKind> = K extends 'governance'
	? PendingApproval
	: PendingChangeset;
export type JournalRequest =
	| { method: 'open'; kind: JournalKind }
	| { method: 'load' | 'close'; handle: string }
	| { method: 'retain' | 'resolve'; handle: string; entry: PendingApproval | PendingChangeset };
export type JournalReply = string | PendingApproval | PendingChangeset | null;
/** Implement with the owning worker's request channel. No key, credential or caller-chosen scope. */
export type JournalTransport = (request: JournalRequest) => Promise<JournalReply>;
export interface JournalProxy<K extends JournalKind> {
	load(): Promise<JournalEntry<K> | null>;
	retain(entry: JournalEntry<K>): Promise<void>;
	resolve(entry: JournalEntry<K>): Promise<void>;
	close(): Promise<void>;
}
