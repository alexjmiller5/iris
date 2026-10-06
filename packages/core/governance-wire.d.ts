import type { Actor, GovernanceCapability, GovernanceLimits, Intent, Target } from './contract.generated.ts';
export declare const governanceOperations: {
    readonly historyEvents: {
        readonly route: "/v1/governance/history/events";
        readonly read: true;
        readonly required: readonly ["target"];
        readonly optional: readonly ["cursor", "limit"];
    };
    readonly previewChanges: {
        readonly route: "/v1/governance/preview";
        readonly read: true;
        readonly preview: true;
        readonly required: readonly ["target", "intent"];
        readonly optional: readonly [];
    };
    readonly createProposal: {
        readonly route: "/v1/governance/proposals/create";
        readonly required: readonly ["previewToken", "idempotencyKey"];
        readonly optional: readonly ["claimedOrigin"];
    };
    readonly listProposals: {
        readonly route: "/v1/governance/proposals/list";
        readonly read: true;
        readonly required: readonly [];
        readonly optional: readonly ["target", "state", "cursor", "limit"];
    };
    readonly getProposal: {
        readonly route: "/v1/governance/proposals/get";
        readonly read: true;
        readonly required: readonly ["proposalId"];
        readonly optional: readonly ["version"];
    };
    readonly editProposal: {
        readonly route: "/v1/governance/proposals/edit";
        readonly required: readonly ["proposalId", "expectedVersion", "previewToken", "idempotencyKey"];
        readonly optional: readonly ["claimedOrigin"];
    };
    readonly previewProposal: {
        readonly route: "/v1/governance/proposals/preview";
        readonly read: true;
        readonly preview: true;
        readonly required: readonly ["proposalId", "expectedVersion"];
        readonly optional: readonly [];
    };
    readonly approveProposal: {
        readonly route: "/v1/governance/proposals/approve";
        readonly required: readonly ["proposalId", "expectedVersion", "previewToken", "idempotencyKey"];
        readonly optional: readonly [];
    };
    readonly rejectProposal: {
        readonly route: "/v1/governance/proposals/reject";
        readonly required: readonly ["proposalId", "expectedVersion", "idempotencyKey"];
        readonly optional: readonly [];
    };
};
export type GovernanceOperation = keyof typeof governanceOperations;
export type GovernanceRoute = typeof governanceOperations[GovernanceOperation]['route'];
export declare const object: (x: unknown) => x is Record<string, unknown>;
export declare const nonempty: (x: unknown) => x is string;
export declare const exact: (x: unknown, required: readonly string[], optional?: readonly string[]) => x is Record<string, unknown>;
export declare const isTarget: (x: unknown) => x is Target;
export declare const isActor: (x: unknown) => x is Actor;
export declare const texts: (x: unknown) => x is string[];
export declare function isGovernanceCapability(x: unknown): x is GovernanceCapability;
export declare function isIntent(x: unknown, limits?: GovernanceLimits): x is Intent;
export declare function validGovernanceArgs(name: GovernanceOperation, x: unknown, limits: GovernanceLimits): boolean;
export declare const isRead: (name: GovernanceOperation) => boolean;
export declare const sameTarget: (a: Target, b: Target) => boolean;
export declare const sameActor: (a: Actor, b: Actor) => boolean;
export declare const conflicts: (x: unknown) => boolean;
export declare function isPreview(x: unknown): boolean;
export declare function isProposal(x: unknown): boolean;
export declare function isApproval(x: unknown): boolean;
export declare function isHistory(x: unknown): boolean;
export declare const utf8Length: (text: string) => number;
