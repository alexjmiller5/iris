import type { GovernanceTransport } from './governance-service.ts';
import type { Hub } from "./driver.ts";
/** Native hosts implement GET with the same credential/redirect rules as POST. */
export interface ServiceHub extends Hub {
    governancePost?: GovernanceTransport;
    get(route: string): Promise<{
        data: unknown;
        date?: string;
    }>;
}
import type { UsageSummary, NotificationFeed, NotificationReadSelector, NotificationReadResult, NotificationPresentation } from './contract.generated.ts';
export type { UsageSummary, HubNotification, NotificationFeed } from './contract.generated.ts';
export declare function readUsage(hub: ServiceHub): Promise<UsageSummary>;
/** Refetch from zero every time: read state can change on another client. A
 * failed/bounded walk never returns a partial feed or a presentation checkpoint. */
export declare function readNotifications(hub: ServiceHub): Promise<NotificationFeed>;
export declare function markNotificationsRead(hub: Hub, selector: Omit<NotificationReadSelector, 'ids'> & {
    ids?: Readonly<NotificationReadSelector['ids']>;
}): Promise<NotificationReadResult>;
/** Pure proposal. Hosts persist baseline per endpoint only after successful
 * presentation, and manage notification permissions, timers and storage. */
export declare function notificationPresentation(feed: NotificationFeed, previousBaseline: number | null): NotificationPresentation;
