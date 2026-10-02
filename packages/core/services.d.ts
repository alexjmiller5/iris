import type { Hub } from "./driver.ts";
/** Native hosts implement GET with the same credential/redirect rules as POST. */
export interface ServiceHub extends Hub {
    get(route: string): Promise<{
        data: unknown;
        date?: string;
    }>;
}
export interface UsageSummary {
    period: {
        start: string;
        end: string;
        anchor_day: number;
    };
    measured_at: string | null;
    capped: {
        metric: string;
        used: number;
        cap: number;
        resets_at: string;
    } | null;
    metrics: Record<string, {
        kind: "cumulative" | "gauge";
        unit: string;
        used: number | null;
        allowance: number | null;
        cap: number | null;
        alert_at: number[];
        measured_at: string | null;
    }>;
    by_principal: {
        id: string;
        label: string | null;
        kind: string;
        rows_read: number;
        rows_written: number;
        requests: number;
    }[];
}
export interface HubNotification {
    seq: number;
    id: string;
    created_at: string;
    producer: string;
    type: string;
    severity: string;
    title: string;
    body: string;
    /** Producer-owned JSON; clients must tolerate unknown producers and types. */
    data: unknown;
    read_at: string | null;
}
/** A complete walk, including read notifications for shared read-state reconciliation. */
export interface NotificationFeed {
    notifications: HubNotification[];
    next_cursor: null;
    latest_cursor: number;
    unread_count: number;
}
export declare function readUsage(hub: ServiceHub): Promise<UsageSummary>;
/** Refetch from zero every time: read state can change on another client. A
 * failed/bounded walk never returns a partial feed or a presentation checkpoint. */
export declare function readNotifications(hub: ServiceHub): Promise<NotificationFeed>;
export declare function markNotificationsRead(hub: Hub, selector: {
    ids?: readonly string[];
    through?: number;
}): Promise<{
    unread_count: number;
}>;
/** Pure proposal. Hosts persist baseline per endpoint only after successful
 * presentation, and manage notification permissions, timers and storage. */
export declare function notificationPresentation(feed: NotificationFeed, previousBaseline: number | null): {
    notifications: HubNotification[];
    baseline: number;
};
