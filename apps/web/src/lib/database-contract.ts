import type { CoreArgs, CoreResult, Row } from 'life-ui-core/client';

// Host lifecycle and credentials are local to the browser. Shared operations
// refer to the generated contract, including their argument/result pairing.
export interface WorkspaceSnapshot {
	catalog: CoreResult<'catalog'>;
	status: CoreResult<'status'>;
	lastSync: CoreResult<'status'>['lastSuccessfulSync'];
	skipped: string[];
	rejected: Row[];
}
export interface DatabaseOperations {
	open: { args: { demo?: boolean }; result: WorkspaceSnapshot };
	close: { args: Record<string, never>; result: null };
	snapshot: { args: Record<string, never>; result: WorkspaceSnapshot };
	rows: { args: { view: CoreArgs<'rows'> }; result: CoreResult<'rows'>[number]['record'][] };
	options: { args: CoreArgs<'options'>; result: CoreResult<'options'> };
	write: { args: CoreArgs<'write'>; result: CoreResult<'write'> };
	sync: { args: CoreArgs<'sync'> & { token: string }; result: CoreResult<'sync'> };
}
export type DatabaseMethod = keyof DatabaseOperations;
export type DatabaseArgs<M extends DatabaseMethod> = DatabaseOperations[M]['args'];
export type DatabaseResult<M extends DatabaseMethod> = DatabaseOperations[M]['result'];
export type DatabaseRequest = {
	[M in DatabaseMethod]: { method: M; args: DatabaseArgs<M> };
}[DatabaseMethod];
