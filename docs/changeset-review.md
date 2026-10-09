# Related-change review

The web workspace offers **Review changes** for its connected hub. Save/discard
open drafts and sync pending local edits first. Opening checks the current
service capability and requires an enrolled USER approval principal. Operator
credentials and agent proposal credentials cannot activate approval.

Enter the proposal ID supplied by the proposing tool, or use a workspace URL
with `?proposal=<opaque-id>` to prefill it. Opening the link alone does not open a
workspace, choose credentials, load records or approve anything. **Open review**
loads the complete immutable proposal and a fresh preview. All related changes
are displayed together with before/after values and explicit creation/trash labels.
The server revalidates the whole set before commit.

Approval persists its exact request in strict IndexedDB storage before HTTP.
After an uncertain response, **Resolve previous approval** retries that same key,
even after reload. It never refreshes a preview or mints a replacement request for
an unresolved approval. Different principals, deployments or endpoints cannot
adopt or erase the entry. A purge or terminal negative receipt resolves it without
claiming a save. After a committed receipt, ordinary workspace sync refreshes
local data. Native review remains separate.

The service, catalog rules, mutation validation and transport codecs belong to
Soma. The host supplies UI, its independently enrolled connection and durable
request storage. This interface is a proposal reviewer, not a second domain editor.

## Verification

- `bun test scripts/changeset-journal.test.ts scripts/changeset-review.test.ts`
- `scripts/check-changeset-browser.ts` takes an explicitly owned CDP target,
  installed chrome-control helper and `SOMA_CONTRACT_ROOT`. It runs the real
  Worker against synthetic SQLite state, displays the review, commits a set,
  deliberately loses the response, reloads and verifies original-key recovery.
- `scripts/check-governance-browser.ts` tests the shared strict journal in two
  explicitly owned targets, including races, binding mutation and storage failure.

Both browser drivers clean their synthetic databases and stop their local server.
The caller owns and closes the browser targets. No real data or credentials enter
these fixtures.
