import type { ChangesetApprovalResult, ChangesetChange } from './contract.generated.ts';
/** The host captures this scope with its durable original-request journal before
 * dispatch. A reply for a different proposal, actor, member or lifecycle action
 * cannot acknowledge the pending set. No partial receipt is accepted. */
export type ChangesetApprovalScope = {
    proposalId: string;
    proposalVersion: string;
    principalId: string;
    changes: Pick<ChangesetChange, 'table' | 'id' | 'kind'>[];
};
export declare function parseChangesetApproval(scope: ChangesetApprovalScope, reply: unknown): ChangesetApprovalResult;
/** Only authenticated, durable negative outcomes may settle an original request. */
export declare function parseChangesetFailure(reply: unknown): ChangesetApprovalResult;
