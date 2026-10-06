import type { CoreArgs, CoreResult, GovernanceCapability, SessionReply } from './contract.generated.ts';
import type { GovernanceOperation, GovernanceRoute } from './governance-wire.ts';
export type { GovernanceOperation, GovernanceRoute } from './governance-wire.ts';
export type GovernanceAPI = {
    [M in GovernanceOperation]: (args: CoreArgs<M>) => Promise<CoreResult<M>>;
};
/** The host may report notDispatched only before HTTP starts. Exceptions after
 * dispatch, including a timeout or dropped response, remain indeterminate. */
export type GovernanceTransport = (route: GovernanceRoute, body: unknown) => Promise<SessionReply | {
    notDispatched: true;
}>;
/** Only this exhaustive status/body pairing may settle a dispatched mutation. */
export declare function parseGovernanceReply<M extends GovernanceOperation>(name: M, args: CoreArgs<M>, reply: unknown, capability: GovernanceCapability): CoreResult<M>;
export declare function unavailableGovernance(): GovernanceAPI;
/** Capability and raw transport must both be supplied for this credential.
 * Hosts replace this instance on deployment/session/workspace change. */
export declare function createGovernanceAPI(capability: unknown, transport: GovernanceTransport | undefined): GovernanceAPI | null;
