declare module 'wa-sqlite/src/examples/OPFSCoopSyncVFS.js' {
	import { Base } from 'wa-sqlite/src/VFS.js';
	export class OPFSCoopSyncVFS extends Base {
		static create(name: string, module: unknown): Promise<OPFSCoopSyncVFS>;
	}
}
