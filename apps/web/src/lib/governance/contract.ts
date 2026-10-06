// PROVISIONAL TYPE-ONLY copy approved by the Life Data owner.
// Source: Life Data core/src/contract.generated.ts at
// f0ed465d230c96dd63c2610691274034c34c79e9.
// Contract hash: 323ba793aeb8962d9555f48d80ccf486bf1010116f1f1b89d8c33f9491c26d12.
// No operation is available until advertised by core. Replace with canonical
// generated DTO imports during integration; never bind guessed HTTP routes.

export type Target = { table: string; rowId: string };
export type Revision = { updated_at: string; hub_at: string | null };
export type CellValue =
	| { type: 'null' }
	| { type: 'text'; value: string }
	| { type: 'integer'; value: string } // signed decimal, preserves 64-bit values
	| { type: 'real'; value: number }; // finite only
export type Actor = { principalId: string; kind: 'user' | 'agent' | 'service' };
export type Change = { column: string; before: CellValue; after: CellValue };
export type Conflict = {
	code:
		| 'later_column_change'
		| 'history_unavailable'
		| 'revision_changed'
		| 'validation_failed'
		| 'proposal_changed'
		| 'unavailable';
	column: string | null;
	eventIds: string[];
	message: string;
};
export type Intent =
	| { kind: 'selected_inverse'; eventIds: string[] }
	| { kind: 'patch'; changes: { column: string; after: CellValue }[] };
export type PreviewRequest = { target: Target; intent: Intent };
export type Preview = {
	target: Target;
	revision: Revision;
	changes: Change[];
	selectedEventIds: string[];
	conflicts: Conflict[];
	// Null unless valid, authorized, supported, and safe to submit.
	previewToken: string | null;
	expiresAt: string | null;
};
export type HistoryEvent = {
	id: string;
	operationId: string | null;
	target: Target;
	column: string;
	before: CellValue | null; // outer null means unknown, not SQL NULL
	after: CellValue | null;
	occurredAt: string;
	actor: Actor | null; // null for unverified legacy attribution
	claimedOrigin: string | null;
	reversible: boolean;
	unavailableReason: string | null;
};
export type Proposal = {
	id: string;
	version: string;
	target: Target;
	intent: Intent;
	changes: Change[];
	baseRevision: Revision;
	state: 'pending' | 'approved' | 'rejected';
	proposedBy: Actor;
	claimedOrigin: string | null;
	createdAt: string;
	updatedAt: string;
};
export type ApprovalReceipt = {
	operationId: string;
	proposalId: string;
	proposalVersion: string;
	target: Target;
	revision: Revision;
	historyEventIds: string[];
	approvedBy: Actor;
	committedAt: string;
};
export type MutationErrorCode =
	| 'proposal_changed'
	| 'revision_changed'
	| 'history_unavailable'
	| 'validation_failed'
	| 'permission_denied'
	| 'unavailable'
	| 'expired_preview'
	| 'idempotency_conflict';
export type MutationResolution = 'unresolved' | 'not_committed';
export type MutationError = {
	kind: 'error';
	code: MutationErrorCode;
	resolution: MutationResolution;
	conflicts: Conflict[];
};
export type MutationResult<T> =
	| { kind: 'success'; value: T }
	| { kind: 'purged' }
	| MutationError
	// Adapter outcomes, never JSON fabricated by the service:
	| { kind: 'transport_error'; code: 'offline' | 'indeterminate' };
export type ApprovalResult = MutationResult<ApprovalReceipt>;
export type ReadResult<T> =
	| { kind: 'success'; value: T }
	| { kind: 'unavailable' }
	| { kind: 'transport_error'; code: 'offline' | 'indeterminate' };
