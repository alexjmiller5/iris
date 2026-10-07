import type { GetViewDefaultArgs, SetViewDefaultArgs, ViewDefault } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
import { type WriteCapture } from './write.ts';
export declare function getViewDefault(db: SqlDriver, input: GetViewDefaultArgs): Promise<ViewDefault>;
export declare function setViewDefault(db: SqlDriver, input: SetViewDefaultArgs, options?: {
    origin?: string;
}, capture?: (value: WriteCapture) => void): Promise<ViewDefault>;
