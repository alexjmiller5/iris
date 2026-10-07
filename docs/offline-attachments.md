# Offline attachment acceptance contract

The native private-file store is implemented and has focused filesystem tests.
Editor, browser outbox, authenticated upload and reconnect mounting remain to be
integrated and verified. The requirements below describe the full feature.

An attachment selected without connectivity must remain available after closing
and reopening the app. Uploads use the enrolled hub's existing opaque-key files
API, independently of row synchronization. File bytes live in the app's private
outbox and the hub file store; record values contain references only.

Staging copies and hashes the entire file before publishing its reference. A
bounded staging failure leaves no usable partial attachment. The outbox retains
the original display name, MIME, size, digest, immutable key and upload state,
without credentials. Each workspace owns its outbox directory. Native files and
metadata use private permissions; the browser uses its existing origin storage.

An upload is create-only and supplies the digest. A retry after an uncertain
response keeps the same key and verifies the existing object rather than
creating another attachment. A successful receipt must match the staged key,
size, MIME and digest before local bytes can be released. Failures retain bytes,
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
