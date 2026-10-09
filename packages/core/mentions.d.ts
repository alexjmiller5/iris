import type { MentionLabel, MentionLabelsArgs, MentionedByArgs, MentionedByPage, ViewEmbed, ViewEmbedArgs } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
export type IrisLink = {
    kind: 'row' | 'view';
    table: string;
    id: string;
};
/** The stored, future-proof form of a mention or view embed: a plain Markdown link destination. */
export declare function irisHref(kind: IrisLink['kind'], table: string, id: string): string;
export declare function parseIrisHref(href: string): IrisLink | null;
/** Inline-link destinations only. Bare URLs and reference definitions are not mentions. */
export declare function markdownMentions(markdown: string): {
    table: string;
    id: string;
}[];
/** Backlinks come from the derived `_core_search_mentions` index that search
 * maintains from Markdown properties; nothing new is stored or synced. */
export declare function mentionedBy(db: SqlDriver, args: MentionedByArgs): Promise<MentionedByPage>;
export declare function mentionLabels(db: SqlDriver, args: MentionLabelsArgs): Promise<MentionLabel[]>;
export declare function viewEmbed(db: SqlDriver, args: ViewEmbedArgs): Promise<ViewEmbed>;
