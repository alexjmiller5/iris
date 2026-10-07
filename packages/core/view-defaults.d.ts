import type { GetViewDefaultArgs, SetViewDefaultArgs, ViewDefault } from './contract.generated.ts';
import type { SqlDriver } from './driver.ts';
import { type WriteCapture } from './write.ts';
export declare function getViewDefault(db: SqlDriver, input: GetViewDefaultArgs, storage?: {
    ddl: string[];
    table: {
        id: string;
        kind: string;
        display: string;
    };
    properties: ({
        id: string;
        tbl: string;
        col: string;
        type: string;
        required: number;
        ref_table: string;
        sort: number;
        source?: undefined;
        source_ref?: undefined;
    } | {
        id: string;
        tbl: string;
        col: string;
        type: string;
        ref_table: string;
        sort: number;
        source: string;
        source_ref: string;
        required?: undefined;
    })[];
}): Promise<ViewDefault>;
export declare function setViewDefault(db: SqlDriver, input: SetViewDefaultArgs, options?: {
    origin?: string;
}, capture?: (value: WriteCapture) => void, storage?: {
    ddl: string[];
    table: {
        id: string;
        kind: string;
        display: string;
    };
    properties: ({
        id: string;
        tbl: string;
        col: string;
        type: string;
        required: number;
        ref_table: string;
        sort: number;
        source?: undefined;
        source_ref?: undefined;
    } | {
        id: string;
        tbl: string;
        col: string;
        type: string;
        ref_table: string;
        sort: number;
        source: string;
        source_ref: string;
        required?: undefined;
    })[];
}): Promise<ViewDefault>;
export declare const getRelatedViewDefault: (db: SqlDriver, input: GetViewDefaultArgs) => Promise<ViewDefault>;
export declare const setRelatedViewDefault: (db: SqlDriver, input: SetViewDefaultArgs, options?: {
    origin?: string;
}, capture?: (value: WriteCapture) => void) => Promise<ViewDefault>;
