import type {
	ApprovalResult,
	HistoryEvent,
	MutationResult,
	Preview,
	PreviewRequest,
	Proposal,
	Target,
	ReadResult,
	Change,
	Intent,
	Revision
} from './contract';

// Type-only mapping of the owner's operation table. The host supplies null
// until core actually advertises the operations. This file has no transport.
export interface ApprovalRequest {
	proposalId: string;
	expectedVersion: string;
	previewToken: string;
	idempotencyKey: string;
}
export interface GovernanceAPI {
	historyEvents(args: {
		target: Target;
		cursor?: string;
		limit?: number;
	}): Promise<ReadResult<{ events: HistoryEvent[]; nextCursor: string | null }>>;
	previewChanges(args: PreviewRequest): Promise<ReadResult<Preview>>;
	createProposal(args: {
		previewToken: string;
		idempotencyKey: string;
		claimedOrigin?: string;
	}): Promise<MutationResult<Proposal>>;
	listProposals(args: {
		target?: Target;
		state?: 'pending' | 'approved' | 'rejected';
		cursor?: string;
		limit?: number;
	}): Promise<ReadResult<{ proposals: Proposal[]; nextCursor: string | null }>>;
	getProposal(args: { proposalId: string; version?: string }): Promise<ReadResult<Proposal>>;
	editProposal(args: {
		proposalId: string;
		expectedVersion: string;
		previewToken: string;
		idempotencyKey: string;
		claimedOrigin?: string;
	}): Promise<MutationResult<Proposal>>;
	previewProposal(args: {
		proposalId: string;
		expectedVersion: string;
	}): Promise<ReadResult<Preview>>;
	approveProposal(args: ApprovalRequest): Promise<ApprovalResult>;
	rejectProposal(args: {
		proposalId: string;
		expectedVersion: string;
		idempotencyKey: string;
	}): Promise<MutationResult<Proposal>>;
}

export interface ApprovalScope {
	deploymentId: string;
	sessionId: string;
	principalId: string;
}
export interface PendingApproval {
	version: 1;
	scope: ApprovalScope;
	target: Target;
	intent: Intent;
	revision: Revision;
	changes: Change[];
	selectedEventIds: string[];
	request: ApprovalRequest;
}
/** Durable, serialized host store. retain resolves only after durable commit.
 * resolve is compare-and-delete of the exact entry; load must fail closed on
 * malformed/unreadable data. Pending entries survive navigation and process exit.
 */
export interface ApprovalJournal {
	load(): Promise<PendingApproval | null>;
	retain(entry: PendingApproval): Promise<void>;
	resolve(entry: PendingApproval): Promise<void>;
}
