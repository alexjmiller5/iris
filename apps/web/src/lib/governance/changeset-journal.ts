import { isChangesetProposal } from 'life-ui-core/client';
import type { ChangesetProposal, ApproveProposalArgs } from 'life-ui-core/contract';
import { openScopedJournal, type DurableJournal } from './approval-journal';
export interface ChangesetScope {
	endpoint: string;
	deploymentId: string;
	sessionId: string;
	principalId: string;
}
export interface PendingChangeset {
	version: 1;
	scope: ChangesetScope;
	proposal: ChangesetProposal;
	request: ApproveProposalArgs;
}
export type ChangesetJournal = DurableJournal<PendingChangeset>;
const text = (v: unknown): v is string => typeof v === 'string' && v.trim().length > 0;
const exact = (v: unknown, keys: string[]): v is Record<string, unknown> =>
	v !== null &&
	typeof v === 'object' &&
	!Array.isArray(v) &&
	Object.keys(v).length === keys.length &&
	keys.every((k) => Object.hasOwn(v, k));
export function changesetScopeKey(scope: ChangesetScope): string {
	if (
		!exact(scope, ['endpoint', 'deploymentId', 'sessionId', 'principalId']) ||
		!Object.values(scope).every(text)
	)
		throw new Error('Invalid review connection.');
	return JSON.stringify([scope.endpoint, scope.deploymentId, scope.sessionId, scope.principalId]);
}
export function decodeChangesetApproval(raw: unknown, scope: ChangesetScope): PendingChangeset {
	if (typeof raw !== 'string') throw new Error('Unreadable retained review.');
	const v: unknown = JSON.parse(raw);
	if (
		!exact(v, ['version', 'scope', 'proposal', 'request']) ||
		v.version !== 1 ||
		!exact(v.scope, ['endpoint', 'deploymentId', 'sessionId', 'principalId']) ||
		changesetScopeKey(v.scope as unknown as ChangesetScope) !== changesetScopeKey(scope) ||
		!isChangesetProposal(v.proposal) ||
		v.proposal.state !== 'pending' ||
		!exact(v.request, ['proposalId', 'expectedVersion', 'previewToken', 'idempotencyKey']) ||
		!Object.values(v.request).every(text) ||
		v.request.proposalId !== v.proposal.id ||
		v.request.expectedVersion !== v.proposal.version
	)
		throw new Error('Invalid retained review.');
	return v as unknown as PendingChangeset;
}
export function encodeChangesetApproval(entry: PendingChangeset, scope: ChangesetScope): string {
	const encoded = JSON.stringify(entry);
	decodeChangesetApproval(encoded, scope);
	return encoded;
}
export function openChangesetJournal(
	scope: ChangesetScope,
	options: { indexedDB?: IDBFactory; databaseName?: string } = {}
): Promise<ChangesetJournal> {
	const boundScope = { ...scope };
	return openScopedJournal(
		changesetScopeKey(boundScope),
		{
			encode: (e) => encodeChangesetApproval(e, boundScope),
			decode: (r) => decodeChangesetApproval(r, boundScope)
		},
		{ databaseName: 'life-ui-changesets', ...options }
	);
}
