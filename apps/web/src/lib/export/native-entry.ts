import { serializeExport } from './serialize';

// Both arguments are JSON data. Native never interpolates rows into JavaScript source.
const bridge = {
	serialize(snapshotJSON: string, optionsJSON: string): string {
		return JSON.stringify(serializeExport(JSON.parse(snapshotJSON), JSON.parse(optionsJSON)));
	}
};

(globalThis as typeof globalThis & { LifeRecordExport: typeof bridge }).LifeRecordExport = bridge;
