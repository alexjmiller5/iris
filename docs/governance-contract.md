# Governance contract proposal

Status: contract examples for owner review. No historical Undo, proposal store,
approval endpoint, dry-run endpoint or MCP server is implemented by this change.
Soma owns validation, authoritative revisions, authentication and writes.
Iris will consume its supported contract. Workflow schema belongs to its
workflow owner. Existing volatile session Undo remains a separate operation.

## Executable boundary

The smallest conditional HTTP patch prerequisite is Soma main
`5e785bcf96d9ecfc37d00bb33515969f6bd876cc` plus its direct child
`9121ef66df4dcc3a72c63f87d400a8e9555c17f9`. At proposal review, that child is
unmerged and deployment is unverified. The local-change sync fix `298e8da`
and the rest of the workflow branch are not prerequisites.

Run from the Iris checkout with an existing Soma Git checkout containing
that commit (no checkout changes, dependency install or network needed):

```sh
SOMA_CONTRACT_ROOT='<soma-checkout>' bun scripts/check-governance-contract.ts --mutations
```

The runner exports the pinned Worker and core into a temporary directory, calls
the real `worker.fetch` through the owner's `D1Shim`, and removes the directory.
All rows, subscriptions and credentials are synthetic and memory-only. It never
calls a live hub. Five mutations remove each revision guard, omit invariants,
leak a row value in the receipt, or erase retained history. Each must fail an assertion; restored source
must pass again. To check a newer *working tree* explicitly:

```sh
SOMA_CONTRACT_ROOT='<soma-checkout>' bun test scripts/governance-contract.test.ts
```

These focused checks are separate from the existing Iris test command until
the integration owner assigns an upstream checkout to CI. Passing them proves
the pending patch boundary, not availability in the bundled UI core or live hub.

### Conditional patch, as implemented by that prerequisite

```json
{
  "table": "items",
  "id": "a",
  "values": {"status": "closed"},
  "expected_revision": {
    "updated_at": "2025-01-01T00:00:00.000Z",
    "hub_at": "2025-01-01T00:00:00.000Z"
  }
}
```

`POST /v1/rows/patch` accepts one existing live row and a nonempty sparse field
patch. Both exact revision values are required; `hub_at` may be null. It rejects
creation, restoration and structural fields. The response contains only `id`
and the committed `{updated_at, hub_at}` revision. A replay after success returns
409, not the previous success receipt. A write-only grant does not gain row reads.

Tests cover initial and commit-time races for either revision component, current
catalog validation, invariant rollback, tombstones, absent rows, read-only and
revoked credentials, out-of-scope tables, receipt shape, and unchanged durable
row/history/change-event state after failure. They also reject unsupported
`actor`, `origin` and `pretend` request keys.

The fixture initializes normal service bookkeeping before comparing snapshots
and drains `waitUntil` work. Failed writes are not evidence of a side-effect-free
preview: cold requests can initialize service tables, authentication can update
token usage, and successful admin patches can schedule derivations.

## Selected product behavior

Historical Undo reverses selected historical changes and preserves unrelated
later edits. Agents propose, then the user approves ONLINE so validation and
apply commit atomically. The first MCP workflow is propose/review/online commit.
These selections are final; whole-row restoration and direct agent commits are
outside this slice. Offline cached review may inform a later online review but
cannot approve or apply.

The executable inverse example first commits status=open to status=closed,
retains that event's complete history record, then changes the unrelated name
from Original to Later title. A hand-authored status=open candidate uses the
current revision, preserves Later title and the prior event, and appends a new
event. This tests the write boundary, not historical reconstruction.

The canonical inverse must check selected cells against their event's resulting
values; a same-column edit after that event is a conflict. Use the revision of
the *reviewed current row*, validate under current rules, and append a new
revision. Any change after preview conflicts, including unrelated fields; a new
preview may explicitly construct a fresh candidate. Current TEXT cell history
has no authoritative typed transaction envelope or complete old-row snapshot.
Equal timestamps must not be used to invent a transaction. Missing or ambiguous
evidence is unavailable. Lifecycle changes and purged history need an owner
contract beyond field patch. The core owner defines exact supported coverage.

## Proposed shared semantics for owner review

These are acceptance requirements, not new routes or schema definitions.

- When a preview is requested, the service shall validate a candidate against
  a captured row revision and current catalog/rules, return normalized changes
  and violations, and persist no proposal, receipt, row, history, outbox or
  derivation work. Preview still authenticates, authorizes and checks revocation.
  Domain writes, auth usage writes and outbound delivery must be suppressed
  before execution; provider access/security logs are not promised absent.
  Rolling back one SQLite connection is insufficient. A
  preview is advisory and never grants authority to commit later.
- When a proposal is created, the service shall bind its immutable version to
  one target, exact candidate values, base revision and authenticated proposer.
  Initial proposed API scope is one row with multiple fields; the core owner
  confirms the exact supported slice.
  Editing creates a new version; reviewing an old version cannot approve it.
- When approval is requested, the service shall require authenticated user
  approval authority and reauthorize the current caller. Propose or table-write
  authority alone cannot authorize agent self-approval. It shall
  compare both proposal version and target revision, and validate against the
  current catalog/rules inside the same guarded commit. The row mutation,
  history/activity, approval transition and receipt shall commit atomically.
  Reject shall terminate that proposal version without a target mutation.
- When an approval is retried with the same request identity, the service shall
  return the same committed receipt with no second mutation or event. Bind the
  key to deployment, authenticated principal, proposal/version, target and exact
  candidate; reuse for another request shall fail. Reauthorize, check request
  identity and return the stored committed receipt BEFORE revalidating target
  revision or catalog. A later edit cannot turn a committed retry into conflict.
  Storage representation, retention and error DTOs remain for
  Soma to define; current conditional patch alone does not meet this rule.
- History and activity shall distinguish server-authenticated proposer,
  approver and committer from caller-claimed origin/tool labels. An offline
  origin does not become an authenticated actor when synced. Existing unknown
  actors stay unknown. A client must not forge actor fields. Do not expose
  tokens; use stable opaque identities. Purge must redact every retained proposal
  version, diff and receipt payload copy. After purge, an authorized identical
  retry may return only a content-free redacted outcome marker, never resurrect
  the removed payload. This is an explicit exception to identical receipt replay.
- MCP shall remain an adapter over supported service capabilities: bounded
  structured query, propose, commit and preview. `readOnlyHint` describes query;
  authorization comes from the service, never annotations. A scoped remote
  credential must not fall back to ambient CLI/admin credentials or an unscoped
  local replica. Local trusted access is a separate mode, not scope equivalence.

## Pending acceptance vectors

The following cases cannot execute against today's API. They are deliberately
not represented by passing mocks or a second writer. Operation names describe
intent and do not reserve endpoint names. `r0` and `r1` mean distinct exact
`{updated_at, hub_at}` pairs; `v1` and `v2` are distinct proposal versions.

| ID | Given / operation sequence | Required observation |
| --- | --- | --- |
| preview-no-effects | row a at r0; preview status=closed, with and without catalog violations | authenticate/authorize/revocation-check; normalized diff/violations; no domain/proposal/history/auth usage writes or outbound delivery; also test cold service; provider security/access logging excluded |
| preview-is-advisory | preview at r0; catalog makes closed invalid; commit same candidate | current validation rejects; row/history/outbox/proposal approval/receipt unchanged |
| stale-review | proposal p/v1 for a/r0; another writer commits a/r1; approve p/v1 | conflict and no partial approval; re-review required |
| edit-then-approve | review p/v1; edit to p/v2 with a different value; approve p/v1, then review/approve p/v2 | v1 conflicts; only reviewed v2 can commit once |
| approval-retry | approve p/v1 with key k; lose response; repeat exact request with k | identical committed receipt; one row revision, one activity event; repeat after another row edit still returns original receipt |
| redacted-retry | commit p/v1 with k; purge its covered content; retry k after reauthorization | only content-free redacted outcome; all proposal versions/diffs/receipt payload copies remain redacted |
| key-reuse | same key k with changed payload, principal, target or proposal version | deny key collision or keep independent principal namespace; never return another principal's receipt or mutate wrong target |
| authenticated-actor | proposer principal-p claims origin=principal-q; approver principal-r commits | actor records p/r from authentication; q only a claim; client-supplied actor rejected; legacy actor remains unknown |
| rejected-or-revoked | reject p/v1 then approve; separately revoke approver before approval/retry; agent with propose/table-write tries self-approval | terminal/revocation/authority denial; no new row/history/outbox changes; no leaked receipt |
| approval-rollback | inject failure after candidate write but before approval receipt persists | row, history, activity, proposal transition and receipt all roll back together |
| scoped-mcp | read-only credential tries propose/commit; exact-table writer requests another table; narrow credential tries replica fallback | service denies each unauthorized operation; no ambient credential fallback; query paging/projection respects grants |

## Integration gate

Soma reviews the shared semantics and defines authoritative DTOs, capabilities
and tests before client implementation. Workflow owns any conditional-patch
integration and Tasks/Notes schema changes. Product selections are recorded above. Implement
typed history/preview/proposal/receipt work in Soma, then generate client
bindings and assign UI/MCP integration files. No competing revisions table,
client-side validator, approval boolean on a syncable row, or timestamp-inferred
transaction is authorized by this proposal.
