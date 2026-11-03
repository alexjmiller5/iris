import type { JournalKind, JournalTransport, JournalProxy, JournalEntry } from './journal-protocol';
/** Page-side opaque handle only. Crypto and authenticated scope binding live in the worker. */
export async function openJournalProxy<K extends JournalKind>(
	kind: K,
	request: JournalTransport
): Promise<JournalProxy<K>> {
	const handle = await request({ method: 'open', kind });
	if (typeof handle !== 'string' || !handle.length || handle.length > 128)
		throw new Error('Invalid journal worker handle.');
	let closed = false,
		closing: Promise<void> | undefined;
	const guard = () => {
		if (closed) throw new Error('Journal proxy is closed.');
	};
	return {
		async load() {
			guard();
			const entry = await request({ method: 'load', handle });
			guard();
			if (entry !== null && (typeof entry !== 'object' || Array.isArray(entry)))
				throw new Error('Invalid journal worker response.');
			return entry as JournalEntry<K> | null;
		},
		async retain(entry) {
			guard();
			await request({ method: 'retain', handle, entry });
			guard();
		},
		async resolve(entry) {
			guard();
			await request({ method: 'resolve', handle, entry });
			guard();
		},
		close() {
			if (closing) return closing;
			closed = true;
			closing = request({ method: 'close', handle }).then(() => {});
			return closing;
		}
	};
}
