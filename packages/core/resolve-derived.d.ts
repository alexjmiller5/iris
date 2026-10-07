import type { Hub, SqlDriver } from './driver.ts';
import type { ResolveDerivedArgs, ResolveDerivedResult } from './contract.generated.ts';
type Args = Omit<ResolveDerivedArgs, 'endpoint'>;
/** No replica writes and no transaction held across HTTP. The existing remote
 * read validates main-schema hub binding and full row shape before authorization.
 * The distinct server route enforces the displayed revision inside its guarded
 * derivation snapshot, including provider-time races. Hosts sync for readback. */
export declare function resolveDerived(db: SqlDriver, hub: Hub, args: Args): Promise<ResolveDerivedResult>;
export {};
