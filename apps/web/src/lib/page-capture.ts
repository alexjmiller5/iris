import { retainedFileKey, type RetainedFileResolver } from './retained-files';

export type CaptureKind = 'png' | 'html';
type Artifact = { key: string; mime: string; bytes: number; sha256: string };
export type PageCapture = {
	id: string;
	originalURL: string;
	sourceURL: string | null;
	sourceTable: string;
	sourceRow: string;
	sourceColumn: string;
	attemptedAt: string;
	capturedAt: string | null;
	status: string;
	warning: string | null;
	failure: string | null;
	artifacts: Partial<Record<CaptureKind, Artifact>>;
};
export const CAPTURE_PREVIEW_LIMIT = 8 * 1024 * 1024;
export const CAPTURE_DOWNLOAD_LIMIT = 128 * 1024 * 1024;

/** Invoked explicitly for one saved row; never inferred from its table or key names. */
export function parseCapture(row: Record<string, unknown>): PageCapture {
	const invalid = () => {
		throw Error('Capture metadata is missing or invalid.');
	};
	const text = (key: string): string =>
		typeof row[key] === 'string' && row[key] !== '' ? (row[key] as string) : invalid();
	const timestamp = (key: string) => {
		const value = text(key);
		if (!value.endsWith('Z') || !Number.isFinite(Date.parse(value))) invalid();
		return value;
	};
	const originalURL = text('source_url');
	let sourceURL: string | null = null;
	try {
		const url = new URL(originalURL);
		if (
			['http:', 'https:'].includes(url.protocol) &&
			!url.username &&
			!url.password &&
			!/[\s\\]/u.test(originalURL)
		)
			sourceURL = url.href;
	} catch {
		/* Unsupported history still preserves the original text. */
	}
	for (const key of ['capture_id', 'event_id', 'subscription_id']) text(key);
	try {
		const revision = JSON.parse(text('observed_source_revision'));
		if (!revision || Array.isArray(revision) || typeof revision !== 'object') invalid();
	} catch {
		invalid();
	}
	const status = text('status');
	if (!['succeeded', 'partial', 'failed', 'blocked', 'unsupported'].includes(status)) invalid();
	const artifacts: PageCapture['artifacts'] = {};
	let warning: string | null = null,
		failure: string | null = null,
		capturedAt: string | null = null;
	if (status === 'succeeded' || status === 'partial') {
		capturedAt = timestamp('captured_at');
		if (status === 'partial') {
			if (row.failure_code !== 'partial') invalid();
			warning = text('failure_detail');
			const resources = '[1-9][0-9]* resource requests could not be saved';
			const sections =
				'(?:1 section was still loading|(?:[2-9]|[1-9][0-9]+) sections were still loading)';
			if (
				!new RegExp(`^Incomplete archive: (?:${resources}(?:; ${sections})?|${sections})\\.$`).test(
					warning
				)
			)
				invalid();
		} else if (row.failure_code !== null || row.failure_detail !== null) invalid();
		for (const kind of ['png', 'html'] as const) {
			const key = text(`${kind}_key`),
				mime = text(`${kind}_mime`),
				sha256 = text(`${kind}_sha256`),
				bytes = row[`${kind}_bytes`];
			if (
				retainedFileKey('/v1/files/' + key.split('/').map(encodeURIComponent).join('/')) !== key ||
				mime !== (kind === 'png' ? 'image/png' : 'text/html') ||
				!/^[a-f0-9]{64}$/.test(sha256) ||
				typeof bytes !== 'number' ||
				!Number.isSafeInteger(bytes) ||
				bytes <= 0 ||
				bytes > 250 * 1024 * 1024
			)
				invalid();
			artifacts[kind] = { key, mime, bytes: bytes as number, sha256 };
		}
	} else {
		if (row.captured_at !== null) invalid();
		for (const kind of ['png', 'html'])
			for (const field of ['key', 'mime', 'bytes', 'sha256'])
				if (row[`${kind}_${field}`] !== null) invalid();
		failure = text('failure_code');
		if (row.failure_detail !== null && typeof row.failure_detail !== 'string') invalid();
		if (typeof row.failure_detail === 'string') failure = row.failure_detail;
	}
	return {
		id: text('id'),
		originalURL,
		sourceURL,
		sourceTable: text('source_table'),
		sourceRow: text('source_row_id'),
		sourceColumn: text('source_column'),
		attemptedAt: timestamp('attempted_at'),
		capturedAt,
		status,
		warning,
		failure,
		artifacts
	};
}

/** Each action calls the enrolled resolver again; metadata is never file authorization. */
export async function readCaptureArtifact(
	capture: PageCapture,
	kind: CaptureKind,
	resolve: RetainedFileResolver,
	signal: AbortSignal,
	maximum = CAPTURE_DOWNLOAD_LIMIT
): Promise<Blob> {
	const expected = capture.artifacts[kind];
	if (!expected) throw Error('This attempt has no retained artifact.');
	if (expected.bytes > Math.min(maximum, CAPTURE_DOWNLOAD_LIMIT))
		throw Error(
			'This artifact exceeds the viewing limit. You can still save a larger original within the download limit.'
		);
	signal.throwIfAborted();
	const file = await resolve(expected.key, signal, false);
	try {
		signal.throwIfAborted();
		if (file.contentType !== expected.mime || !file.url.startsWith('blob:'))
			throw Error('The artifact does not match its capture metadata.');
		const response = await fetch(file.url, { signal, credentials: 'omit' });
		const blob = await response.blob();
		if (blob.size !== expected.bytes)
			throw Error('The artifact does not match its capture metadata.');
		const hash = await crypto.subtle.digest('SHA-256', await blob.arrayBuffer());
		const actual = Array.from(new Uint8Array(hash))
			.map((x) => x.toString(16).padStart(2, '0'))
			.join('');
		signal.throwIfAborted();
		if (actual !== expected.sha256)
			throw Error('The artifact does not match its capture metadata.');
		return new Blob([blob], { type: expected.mime });
	} finally {
		file.dispose();
	}
}

/** Only use inside an iframe with an empty sandbox. No same-origin or script permission. */
export function archiveDocument(html: string): string {
	return `<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; form-action 'none'; base-uri 'none'; object-src 'none'; frame-src 'none'; connect-src 'none'">${html}`;
}

export async function checkCapturePNG(blob: Blob): Promise<void> {
	const header = new DataView(await blob.slice(0, 24).arrayBuffer());
	if (
		header.byteLength < 24 ||
		header.getUint32(0) !== 0x89504e47 ||
		header.getUint32(4) !== 0x0d0a1a0a ||
		header.getUint32(12) !== 0x49484452
	)
		throw Error('PNG preview is unavailable. You can still save the original.');
	const width = header.getUint32(16),
		height = header.getUint32(20);
	if (!width || !height || width > 100000 || height > 100000 || width * height > 100000000)
		throw Error('PNG dimensions exceed the preview limit. You can still save the original.');
}
