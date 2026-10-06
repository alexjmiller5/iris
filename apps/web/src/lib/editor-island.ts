export interface EditorDocument {
	id: string;
	value: string;
	label: string;
	readOnly: boolean;
}
export type EditorMessage =
	| { type: 'ready' }
	| { type: 'change'; id: string; value: string }
	| { type: 'file' | 'openFile' | 'openLink'; id: string; request: string; value: string };
export function parseEditorDocument(input: unknown): EditorDocument {
	if (!input || typeof input !== 'object' || Array.isArray(input))
		throw Error('Invalid editor document');
	const { id, value, label, readOnly } = input as Record<string, unknown>;
	if (
		typeof id !== 'string' ||
		!id ||
		typeof value !== 'string' ||
		typeof label !== 'string' ||
		!label ||
		typeof readOnly !== 'boolean'
	)
		throw Error('Invalid editor document');
	return { id, value, label, readOnly };
}
