import type { SourceLinkArgs, SourceLinkResult } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
export declare function resolveSourceLink(db: SqlDriver, args: SourceLinkArgs): Promise<SourceLinkResult>;
