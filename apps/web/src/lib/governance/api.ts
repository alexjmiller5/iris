import type {
	ApprovalResult,
	ApproveProposalArgs,
	CreateProposalArgs,
	EditProposalArgs,
	GetProposalArgs,
	HistoryEventsArgs,
	HistoryEventsResult,
	ListProposalsArgs,
	PreviewProposalArgs,
	PreviewRequest,
	PreviewResult,
	ProposalMutationResult,
	ProposalResult,
	ProposalsResult,
	RejectProposalArgs,
	Target,
	Change,
	Intent,
	Revision
} from 'life-ui-core/contract';

// Type-only mapping of the owner's operation table. The host supplies null
// until core actually advertises the operations. This file has no transport.
export type ApprovalRequest = ApproveProposalArgs;
export interface GovernanceAPI {
	historyEvents(args: HistoryEventsArgs): Promise<HistoryEventsResult>;
	previewChanges(args: PreviewRequest): Promise<PreviewResult>;
	createProposal(args: CreateProposalArgs): Promise<ProposalMutationResult>;
	listProposals(args: ListProposalsArgs): Promise<ProposalsResult>;
	getProposal(args: GetProposalArgs): Promise<ProposalResult>;
	editProposal(args: EditProposalArgs): Promise<ProposalMutationResult>;
	previewProposal(args: PreviewProposalArgs): Promise<PreviewResult>;
	approveProposal(args: ApprovalRequest): Promise<ApprovalResult>;
	rejectProposal(args: RejectProposalArgs): Promise<ProposalMutationResult>;
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
