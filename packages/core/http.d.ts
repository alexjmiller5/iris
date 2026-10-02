import type { ServiceHub } from "./services.ts";
export type Fetcher = (url: string, init: RequestInit) => Promise<Response>;
/** Browser-compatible transport. Inject fetch explicitly; platforms can wrap it
 * with their own AbortSignal/timeout. Core creates no controllers or timers.
 */
export declare function createHttpHub(endpoint: string, token: string, fetcher: Fetcher): ServiceHub;
