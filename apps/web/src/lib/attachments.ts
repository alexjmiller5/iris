import { createHttpHub } from 'life-ui-core/client';
import { retainedBlob, type RetainedFileResolver } from './retained-files';
export type Attachment = {
	id: string;
	key: string;
	name: string;
	mime: string;
	bytes: number;
	sha256: string;
	state: 'queued' | 'uploading' | 'failed' | 'uploaded';
	endpoint: string | null;
};
const limit = 128 * 1024 * 1024;
const sha = async (file: Blob) =>
	Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', await file.arrayBuffer())), (b) =>
		b.toString(16).padStart(2, '0')
	).join('');
export function attachmentMarkdown(entry: Attachment, source: string): string {
	const name = entry.name
		.replaceAll('\\', '\\\\')
		.replaceAll('[', '\\[')
		.replaceAll(']', '\\]')
		.replace(/[\r\n]/g, ' ');
	const image = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'].includes(entry.mime);
	return (
		source +
		(source ? '\n\n' : '') +
		(image ? '!' : '') +
		'[' +
		name +
		'](<' +
		'/v1/files/' +
		entry.key +
		'>)'
	);
}
export async function uploadAttachment(
	connection: { endpoint: string; token: string },
	entry: Attachment,
	file: Blob,
	fetcher: typeof fetch = fetch,
	signal?: AbortSignal
): Promise<void> {
	const endpoint = createHttpHub(connection.endpoint, connection.token, fetcher).endpoint;
	if (
		!/^attachments\/[A-Za-z0-9-]+$/.test(entry.key) ||
		entry.bytes < 0 ||
		entry.bytes > limit ||
		file.size !== entry.bytes ||
		(await sha(file)) !== entry.sha256 ||
		(entry.endpoint !== null && entry.endpoint !== endpoint)
	)
		throw Error('Attachment integrity or hub binding changed.');
	signal?.throwIfAborted();
	const url = endpoint + '/v1/files/' + entry.key;
	const options = { credentials: 'omit', redirect: 'error', signal } as const;
	const response = await fetcher(url, {
		...options,
		method: 'PUT',
		headers: {
			Authorization: 'Bearer ' + connection.token,
			'If-None-Match': '*',
			'X-Content-SHA256': entry.sha256,
			'Content-Type': entry.mime
		},
		body: file
	});
	if (response.status === 412) {
		await response.body?.cancel();
		const existing = await fetcher(url, {
			...options,
			headers: { Authorization: 'Bearer ' + connection.token }
		});
		if (
			!existing.ok ||
			existing.headers.get('Content-Type')?.split(';')[0] !== entry.mime ||
			Number(existing.headers.get('Content-Length') ?? entry.bytes) !== entry.bytes
		) {
			await existing.body?.cancel();
			throw Error('Existing attachment integrity could not be verified.');
		}
		const reader = existing.body?.getReader();
		const chunks: Uint8Array<ArrayBuffer>[] = [];
		let count = 0;
		try {
			while (reader) {
				signal?.throwIfAborted();
				const next = await reader.read();
				if (next.done) break;
				count += next.value.byteLength;
				if (count > entry.bytes) throw Error('Attachment integrity mismatch.');
				chunks.push(new Uint8Array(next.value));
			}
		} finally {
			await reader?.cancel();
		}
		if (count !== entry.bytes || (await sha(new Blob(chunks))) !== entry.sha256)
			throw Error('Attachment integrity mismatch.');
		return;
	}
	if (
		response.status !== 201 ||
		response.headers.get('Content-Type')?.split(';')[0] !== 'application/json'
	) {
		await response.body?.cancel();
		throw Error('File upload was not accepted. Retry when connected.');
	}
	const reader = response.body?.getReader();
	const chunks: Uint8Array<ArrayBuffer>[] = [];
	let count = 0;
	try {
		while (reader) {
			const next = await reader.read();
			if (next.done) break;
			count += next.value.byteLength;
			if (count > 65536) throw Error('Invalid upload receipt.');
			chunks.push(new Uint8Array(next.value));
		}
	} finally {
		await reader?.cancel();
	}
	const receipt = JSON.parse(await new Blob(chunks).text());
	if (
		receipt.key !== entry.key ||
		receipt.mime !== entry.mime ||
		receipt.bytes !== entry.bytes ||
		receipt.sha256 !== entry.sha256
	)
		throw Error('Attachment integrity mismatch.');
}

/** Outbox bytes and metadata are private OPFS files, never life-data rows. */
export class AttachmentOutbox extends EventTarget {
	entries: Attachment[] = [];
	busy = false;
	error = '';
	private disposed = false;
	private abort = new AbortController();
	private constructor(
		private root: FileSystemDirectoryHandle,
		private connection: () => { endpoint: string; token: string } | null
	) {
		super();
	}
	static async open(
		scope: string,
		connection: () => { endpoint: string; token: string } | null
	): Promise<AttachmentOutbox> {
		const root = await (
			await navigator.storage.getDirectory()
		).getDirectoryHandle('life-ui-attachments', { create: true });
		const key = await sha(new Blob([scope]));
		const box = new AttachmentOutbox(
			await root.getDirectoryHandle(key, { create: true }),
			connection
		);
		await box.refresh();
		return box;
	}
	private async directory(id: string) {
		if (!/^[a-f0-9-]{36}$/.test(id)) throw Error('Invalid attachment metadata.');
		return this.root.getDirectoryHandle(id);
	}
	private async save(entry: Attachment, publish = false) {
		const file = await this.root.getFileHandle(
			publish ? '.stage-' + entry.id : entry.id + '.json',
			{ create: true }
		);
		const writer = await file.createWritable();
		try {
			await writer.write(JSON.stringify(entry));
			await writer.close();
		} catch (error) {
			await writer.abort();
			throw error;
		}
		if (publish)
			await (file as FileSystemFileHandle & { move(name: string): Promise<void> }).move(
				entry.id + '.json'
			);
	}
	async refresh() {
		const entries: Attachment[] = [];
		for await (const [name, handle] of this.root as unknown as AsyncIterable<
			[string, FileSystemHandle]
		>) {
			if (handle.kind !== 'file' || !name.endsWith('.json')) continue;
			const id = name.slice(0, -5);
			const entry = JSON.parse(
				await (await (handle as FileSystemFileHandle).getFile()).text()
			) as Attachment;
			if (
				entry.id !== id ||
				entry.key !== 'attachments/' + id ||
				!Number.isSafeInteger(entry.bytes) ||
				entry.bytes < 0 ||
				entry.bytes > limit ||
				!/^[a-f0-9]{64}$/.test(entry.sha256) ||
				typeof entry.name !== 'string' ||
				typeof entry.mime !== 'string' ||
				!['queued', 'uploading', 'failed', 'uploaded'].includes(entry.state) ||
				(entry.endpoint !== null && typeof entry.endpoint !== 'string')
			)
				throw Error('The attachment outbox contains unreadable metadata. Files have been kept.');
			if (entry.state === 'uploading' && !this.busy) {
				entry.state = 'queued';
				await this.save(entry);
			}
			entries.push(entry);
		}
		await navigator.locks.request(
			'life-ui-attachments:' + this.root.name,
			{ ifAvailable: true },
			async (lock) => {
				if (!lock) return;
				for await (const [name, handle] of this.root as unknown as AsyncIterable<
					[string, FileSystemHandle]
				>) {
					if (name.startsWith('.stage-')) await this.root.removeEntry(name);
					else if (handle.kind === 'directory') {
						try {
							await this.root.getFileHandle(name + '.json');
						} catch (error) {
							if (!(error instanceof DOMException) || error.name !== 'NotFoundError') throw error;
							await this.root.removeEntry(name, { recursive: true });
						}
					}
				}
			}
		);
		if (!this.disposed) {
			this.entries = entries;
			this.dispatchEvent(new Event('change'));
		}
	}
	async stage(file: File): Promise<Attachment> {
		return navigator.locks.request('life-ui-attachments:' + this.root.name, () =>
			this.stageLocked(file)
		);
	}
	private async stageLocked(file: File): Promise<Attachment> {
		if (this.disposed || file.size > limit)
			throw Error('File exceeds the 128 MB attachment limit.');
		const id = crypto.randomUUID(),
			directory = await this.root.getDirectoryHandle(id, { create: true });
		let published = false;
		try {
			const bytes = await directory.getFileHandle('bytes', { create: true });
			const writer = await bytes.createWritable();
			try {
				await writer.write(file);
				await writer.close();
			} catch (error) {
				await writer.abort();
				throw error;
			}
			const retained = await bytes.getFile();
			if (retained.size !== file.size) throw Error('The complete file could not be kept.');
			const entry: Attachment = {
				id,
				key: 'attachments/' + id,
				name: file.name,
				mime: file.type || 'application/octet-stream',
				bytes: file.size,
				sha256: await sha(retained),
				state: 'queued',
				endpoint: this.connection()?.endpoint ?? null
			};
			await this.save(entry, true);
			published = true;
			await this.refresh();
			void this.retry();
			return entry;
		} catch (error) {
			if (!published) {
				await this.root.removeEntry(id, { recursive: true });
				try {
					await this.root.removeEntry('.stage-' + id);
				} catch (cleanup) {
					if (!(cleanup instanceof DOMException) || cleanup.name !== 'NotFoundError') throw cleanup;
				}
			}
			throw error;
		}
	}
	private async file(entry: Attachment) {
		const file = await (await (await this.directory(entry.id)).getFileHandle('bytes')).getFile();
		if (file.size !== entry.bytes || (await sha(file)) !== entry.sha256)
			throw Error('Staged attachment integrity mismatch.');
		return new Blob([file], { type: entry.mime });
	}
	async resolve(key: string, signal?: AbortSignal, preview = false) {
		const entry = this.entries.find((e) => e.key === key);
		if (!entry) return null;
		signal?.throwIfAborted();
		if (entry.bytes > (preview ? 8 : 128) * 1024 * 1024)
			throw Error('File exceeds the preview size limit.');
		return retainedBlob(await this.file(entry), signal, preview);
	}
	resolver(remote?: RetainedFileResolver): RetainedFileResolver {
		return async (key, signal, preview) => {
			const local = await this.resolve(key, signal, preview);
			if (local) return local;
			if (!remote) throw Error('Connect to your hub to open this file.');
			return remote(key, signal, preview);
		};
	}
	async retry() {
		if (this.busy || this.disposed || !this.connection()) return;
		try {
			await this.refresh();
		} catch {
			this.error = 'The attachment outbox could not be read or saved. Its files have been kept.';
			if (!this.disposed) this.dispatchEvent(new Event('change'));
			return;
		}
		if (this.busy || this.disposed) return;
		this.busy = true;
		this.error = '';
		this.dispatchEvent(new Event('change'));
		try {
			for (const entry of this.entries.filter(
				(e) => e.state === 'queued' || e.state === 'failed'
			)) {
				if (this.disposed || this.abort.signal.aborted) break;
				const connection = this.connection();
				if (!connection) break;
				try {
					if (entry.endpoint === null) entry.endpoint = connection.endpoint;
					entry.state = 'uploading';
					await this.save(entry);
					await uploadAttachment(
						connection,
						entry,
						await this.file(entry),
						fetch,
						this.abort.signal
					);
					entry.state = 'uploaded';
					await this.save(entry);
				} catch {
					entry.state = 'failed';
					await this.save(entry);
					this.error = 'Some files could not upload. Their bytes are kept. Retry when connected.';
				}
				this.dispatchEvent(new Event('change'));
			}
		} catch {
			this.error = 'The attachment outbox could not be read or saved. Its files have been kept.';
		} finally {
			this.busy = false;
			if (!this.disposed) this.dispatchEvent(new Event('change'));
		}
	}
	dispose() {
		this.disposed = true;
		this.abort.abort();
	}
}
