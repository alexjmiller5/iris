import type { ChangesetCapability, ChangesetInput, ChangesetProposal, ChangesetPreviewResult, ChangesetProposalResult, ChangesetApprovalResult, CreateProposalArgs, GetProposalArgs, PreviewProposalArgs, ApproveProposalArgs, RejectProposalArgs, SessionReply } from './contract.generated.ts';
export declare const changesetRoutes: {
    readonly preview: "/v1/governance/changesets/preview";
    readonly createProposal: "/v1/governance/changesets/proposals/create";
    readonly getProposal: "/v1/governance/changesets/proposals/get";
    readonly previewProposal: "/v1/governance/changesets/proposals/preview";
    readonly approveProposal: "/v1/governance/changesets/proposals/approve";
    readonly rejectProposal: "/v1/governance/changesets/proposals/reject";
};
export type ChangesetRoute = typeof changesetRoutes[keyof typeof changesetRoutes];
export type ChangesetTransport = (route: ChangesetRoute, body: unknown) => Promise<SessionReply | {
    notDispatched: true;
}>;
export interface ChangesetAPI {
    preview(input: unknown): Promise<ChangesetPreviewResult>;
    createProposal(args: CreateProposalArgs): Promise<ChangesetProposalResult>;
    getProposal(args: GetProposalArgs): Promise<ChangesetProposalResult>;
    previewProposal(args: PreviewProposalArgs, proposal: unknown): Promise<ChangesetPreviewResult>;
    approveProposal(args: ApproveProposalArgs, proposal: unknown): Promise<ChangesetApprovalResult>;
    rejectProposal(args: RejectProposalArgs): Promise<ChangesetProposalResult>;
}
export declare function isChangesetCapability(v: unknown): v is ChangesetCapability;
export declare function isChangesetInput(v: unknown): v is ChangesetInput;
export declare function isChangesetProposal(v: unknown): v is ChangesetProposal;
export declare function createChangesetAPI(capability: unknown, transport: ChangesetTransport | undefined): ChangesetAPI | null;
