import type { CoreArgs, CoreResult } from 'life-ui-core/client';
import type { RejectionSnapshot } from './rejection-inbox';

// Host lifecycle and credentials are local to the browser. Shared operations
// refer to the generated contract, including their argument/result pairing.
export interface WorkspaceSnapshot {
	catalog: CoreResult<'catalog'>;
	status: CoreResult<'status'>;
	lastSync: CoreResult<'status'>['lastSuccessfulSync'];
	skipped: string[];
	rejected: RejectionSnapshot;
	undo: CoreResult<'undoStatus'>['action'];
}
export interface DatabaseOperations {
	saveCatalogProperty: {
		args: CoreArgs<'saveCatalogProperty'>;
		result: CoreResult<'saveCatalogProperty'>;
	};
	saveCatalogRule: { args: CoreArgs<'saveCatalogRule'>; result: CoreResult<'saveCatalogRule'> };
	listSidebarPins: { args: CoreArgs<'listSidebarPins'>; result: CoreResult<'listSidebarPins'> };
	pinTable: { args: CoreArgs<'pinTable'>; result: CoreResult<'pinTable'> };
	unpinTable: { args: CoreArgs<'unpinTable'>; result: CoreResult<'unpinTable'> };
	moveTablePin: { args: CoreArgs<'moveTablePin'>; result: CoreResult<'moveTablePin'> };

	runRowAction: { args: CoreArgs<'runRowAction'>; result: CoreResult<'runRowAction'> };
	enrollmentEndpoint: { args: { endpoint: string }; result: string };
	enrollmentApproval: {
		args: CoreArgs<'enrollmentApproval'>;
		result: CoreResult<'enrollmentApproval'>;
	};
	validateDeviceSession: {
		args: CoreArgs<'validateDeviceSession'>;
		result: CoreResult<'validateDeviceSession'>;
	};
	enrollmentPollResult: {
		args: CoreArgs<'enrollmentPollResult'>;
		result: CoreResult<'enrollmentPollResult'>;
	};
	sessionRevocationResult: {
		args: CoreArgs<'sessionRevocationResult'>;
		result: CoreResult<'sessionRevocationResult'>;
	};
	open: { args: { demo?: boolean }; result: WorkspaceSnapshot };
	close: { args: Record<string, never>; result: null };
	snapshot: { args: Record<string, never>; result: WorkspaceSnapshot };
	rejections: { args: CoreArgs<'rejections'>; result: CoreResult<'rejections'> };
	rows: { args: { view: CoreArgs<'rows'> }; result: CoreResult<'rows'>[number]['record'][] };
	referenceSources: { args: CoreArgs<'referenceSources'>; result: CoreResult<'referenceSources'> };
	referencedBy: { args: CoreArgs<'referencedBy'>; result: CoreResult<'referencedBy'> };
	resolveSourceLink: {
		args: CoreArgs<'resolveSourceLink'>;
		result: CoreResult<'resolveSourceLink'>;
	};
	search: { args: CoreArgs<'search'>; result: CoreResult<'search'> };
	remoteRows: {
		args: CoreArgs<'remoteRows'> & { token: string };
		result: CoreResult<'remoteRows'>;
	};
	remoteRow: { args: CoreArgs<'remoteRow'> & { token: string }; result: CoreResult<'remoteRow'> };
	resolveDerived: {
		args: CoreArgs<'resolveDerived'> & { token: string };
		result: CoreResult<'resolveDerived'>;
	};
	resolveViewDefinition: {
		args: CoreArgs<'resolveViewDefinition'>;
		result: CoreResult<'resolveViewDefinition'>;
	};
	listViews: { args: CoreArgs<'listViews'>; result: CoreResult<'listViews'> };
	getRelatedViewDefault: {
		args: CoreArgs<'getRelatedViewDefault'>;
		result: CoreResult<'getRelatedViewDefault'>;
	};
	setRelatedViewDefault: {
		args: CoreArgs<'setRelatedViewDefault'>;
		result: CoreResult<'setRelatedViewDefault'>;
	};
	getViewDefault: { args: CoreArgs<'getViewDefault'>; result: CoreResult<'getViewDefault'> };
	ensureDefaultView: {
		args: CoreArgs<'ensureDefaultView'>;
		result: CoreResult<'ensureDefaultView'>;
	};
	setViewDefault: { args: CoreArgs<'setViewDefault'>; result: CoreResult<'setViewDefault'> };
	saveView: { args: CoreArgs<'saveView'>; result: CoreResult<'saveView'> };
	deleteView: { args: CoreArgs<'deleteView'>; result: CoreResult<'deleteView'> };
	options: { args: CoreArgs<'options'>; result: CoreResult<'options'> };
	write: { args: CoreArgs<'write'>; result: CoreResult<'write'> };
	undo: { args: CoreArgs<'undo'>; result: CoreResult<'undo'> };
	undoStatus: { args: CoreArgs<'undoStatus'>; result: CoreResult<'undoStatus'> };
	status: { args: Record<string, never>; result: CoreResult<'status'> };
	writeability: { args: CoreArgs<'writeability'>; result: CoreResult<'writeability'> };
	sync: { args: CoreArgs<'sync'> & { token: string }; result: CoreResult<'sync'> };
}
export type DatabaseMethod = keyof DatabaseOperations;
export type DatabaseArgs<M extends DatabaseMethod> = DatabaseOperations[M]['args'];
export type DatabaseResult<M extends DatabaseMethod> = DatabaseOperations[M]['result'];
export type DatabaseRequest = {
	[M in DatabaseMethod]: { method: M; args: DatabaseArgs<M> };
}[DatabaseMethod];
