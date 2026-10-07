# Offline attachment acceptance contract

Native and web editors stage attachments in private file outboxes before inserting
references into ordinary drafts. Catalog properties tagged `file` use the same
staging and authenticated open/download path.

An attachment selected without connectivity must remain available after closing
and reopening the app. Uploads use the enrolled hub's existing opaque-key files
API, independently of row synchronization. File bytes live in the app's private
outbox and the hub file store; record values contain references only.

Staging copies and hashes the entire file before publishing its reference. A
bounded staging failure leaves no usable partial attachment. The outbox retains
the original display name, MIME, size, digest, immutable key and upload state,
without credentials. Each native workspace owns its outbox directory; the web replica owns one
origin-scoped outbox. Native demo storage is temporary and isolated. Native files and
metadata use private permissions; the browser uses its existing origin storage.

An upload is create-only and supplies the digest. A retry after an uncertain
response keeps the same key and verifies the existing object rather than
creating another attachment. A successful receipt must match the staged key,
size, MIME and digest before the entry is marked uploaded. Local bytes remain available offline. Failures retain bytes,
show a retryable state and survive restart. Interrupted uploads resume as pending.

The editor shows pending uploads and can preview staged images locally. Once
uploaded, the same reference uses the existing authenticated retained-file reader.
Adding a file changes the ordinary editor draft; it never silently saves unrelated
input. Catalogued file properties use the same reference and upload controls.
Changing workspace or credentials stops new upload admission and prevents late
results from being presented in a different workspace.

Verification uses synthetic files and a synthetic hub: exact-byte staging and
restart, source removal, bounded-copy refusal, bad receipts, retry of an existing
key, concurrent admission, cancellation, visible pending/error/retry controls and
ordinary row validation. Native build and UI acceptance run on the Mac mini.

Native staging publishes a complete directory with a same-volume rename. Browser
publication atomically renames a closed manifest; a per-outbox Web Lock protects
active staging from abandoned-copy cleanup. Interrupted unpublished copies never
appear as attachments. Unreadable published metadata blocks processing visibly
without discarding retained bytes. An enrolled endpoint owns its upload namespace;
changing hubs never sends a previously bound web attachment to another hub.

Uploads are bounded to 128 MiB. Image previews retain the existing 8 MiB/static
raster limit; refusing a preview does not discard the original file. Native
Quick Look files and browser blob URLs are disposed by their owning views.
The outbox is operational app state, not a backup or a file-collection schema.

Run `python3 scripts/test-attachment-staging.py` for interrupted native publication.
`scripts/test-attachments.ts` exercises mounted web selection, ordinary row save,
offline restart, exact-byte property download and same-key reconnect against a
synthetic hub. `scripts/test-attachment-staging-web.ts` tests OPFS interruption and
corruption handling on an explicitly owned synthetic origin. Mac attachment UI
tests exercise the actual system file picker, cancellation and Markdown insertion.
