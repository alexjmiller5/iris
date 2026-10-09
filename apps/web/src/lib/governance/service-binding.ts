import {
	createGovernanceAPI,
	createHttpHub,
	isGovernanceCapability,
	type Fetcher
} from 'iris-core/client';
import type { GovernanceAuthority } from 'iris-core/contract';
import type { HubConnection } from '../device-enrollment';
import type { ApprovalScope, GovernanceAPI } from './api';

export interface GovernanceServiceBinding {
	readonly api: Readonly<GovernanceAPI>;
	readonly scope: Readonly<ApprovalScope>;
	readonly authority: Readonly<GovernanceAuthority>;
}

export function bindGovernanceService(
	connection: Readonly<HubConnection>,
	capability: unknown,
	fetcher: Fetcher
): GovernanceServiceBinding | null {
	try {
		if (!isGovernanceCapability(capability)) return null;
		const hub = createHttpHub(connection.endpoint, connection.token, fetcher);
		const api = createGovernanceAPI(capability, hub.governancePost);
		if (!api) return null;
		return Object.freeze({
			api: Object.freeze(api),
			scope: Object.freeze({
				deploymentId: capability.deploymentId,
				sessionId: capability.sessionId,
				principalId: capability.principal.principalId
			}),
			authority: Object.freeze({ ...capability.authority })
		});
	} catch {
		return null;
	}
}
