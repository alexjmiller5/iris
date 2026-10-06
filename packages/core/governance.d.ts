import type { CellValue, Change, Conflict, HistoryEvent, Revision, Target } from './contract.generated.ts';
/** Trusted service-loader input, not a wire request. Events must be the complete
 * canonical commit-ordered suffix covering every selected event through the
 * current row revision. A paginated history result cannot establish completeness.
 * This planner does not authorize, validate catalog rules, issue tokens or write. */
export interface InverseEvidence {
    target: Target;
    revision: Revision;
    current: Readonly<Record<string, CellValue>>;
    events: readonly HistoryEvent[];
    complete: boolean;
}
export interface InverseSelection {
    target: Target;
    eventIds: readonly string[];
}
export interface InversePlan {
    changes: Change[];
    selectedEventIds: string[];
    conflicts: Conflict[];
}
export declare function isCellValue(value: unknown): value is CellValue;
/** Produce only selected-column inverse differences. The future writer must
 * reacquire and guard this evidence in its transaction; a plan is not approval. */
export declare function planSelectedInverse(selection: InverseSelection, evidence: InverseEvidence): InversePlan;
