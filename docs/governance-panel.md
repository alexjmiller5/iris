# Governance presentation boundary

This slice provides an isolated history/proposal review panel, a presentation model,
and an approval recovery journal. It does not deliver historical Undo, proposal
storage, the MCP workflow, or a usable approval service. The host passes `api: null`
and `journal: null` until the integration gates below pass. No host is mounted here.

The selected workflow is to reverse selected historical changes, preserving unrelated
later fields, and to have agents propose changes for authenticated user approval
online. The service owns inverse planning, validation, actor identity, preview tokens,
proposal state and the atomic writer. Clients never reconstruct an inverse or write
replica SQL as a substitute.

## Narrow host interface

`GovernancePanel.svelte` accepts:

- `api: GovernanceAPI | null`: an immutable adapter bound to the current authenticated
  deployment/session/principal. Null until the real service advertises support.
- `scope: {deploymentId, sessionId, principalId}` and `target: {table, rowId}`:
  exact service-issued identities. Scope changes recreate the model and journal;
  target changes recreate the presentation. Old requests keep their original scope.
- `journal: ApprovalJournal | null`: a verified durable store for that exact scope.
  Do not inject a generic preference writer, in-memory store or stub.
- `online: boolean`: actual connection state. The server still authenticates and
  authorizes every request, including committed retries.
- `onApplied(receipt)`: invalidate the matching workspace/row after a current receipt,
  preserving unrelated editor drafts. Old-context responses still reconcile their
  journal but do not refresh the new context.

The panel has historical selection/preview and pending proposal review presentation.
Create/edit/reject controls, complete activity filtering, host mounting, native
mirror and MCP remain integration work. Server differences and typed cell values
are displayed without interpreting markup. Unknown historical values, SQL null,
empty text and lossless integer strings remain distinct. Purge/authority loss clears
cached display content and invalidates late page/preview responses.

`contract.ts` re-exports the canonical generated Life Data wire types; `api.ts`
uses generated argument and result types for every method. The generic read
envelope remains only for local presentation helpers. The bundle is generated from
Life Data `f0ed465d230c96dd63c2610691274034c34c79e9`, contract hash
`323ba793aeb8962d9555f48d80ccf486bf1010116f1f1b89d8c33f9491c26d12`.
This is the generated DTO source prerequisite, separate from the proposed transport
routes/capability in its `docs/governance-transport-contract.md`. It adds no advertised
governance HTTP API or CoreOperations. The foundation's inverse
planner requires trusted complete ordered typed evidence; clients must not supply
untrusted evidence to manufacture an authorized preview.

## Service integration

The integration uses `createGovernanceAPI` and `createHttpHub` from
`life-ui-core/client`. The service owns route selection, capability/authority
validation, exact request/result shapes and HTTP response classification. Its
`governancePost` transport preserves status, JSON data and Retry-After; ordinary
`hub.post` is not interchangeable because it throws away the typed error response.
No client classifier, fallback endpoint, local writer or automatic retry is added.

Before constructing a production binding, the host must obtain a validated
capability and stable non-secret deployment/session identity for the exact active
connection. A principal ID, token display name, full scope or replica eligibility
alone is insufficient. Do not derive journal identity from the URL or a credential
hash. The required canonical source for this integration is Life Data
`cd9af7a9398e95844d85c7e6dc8052c9e91c49c4`, contract hash
`e935ee9223797c2910128fcaef91cce70acfeb0baa329dc848074f45b9bf4ff3`.
It includes required `GovernanceCapability.deploymentId` and `sessionId` fields;
the earlier DTO-only source described above is insufficient. This is a source
prerequisite, not a deployment receipt. Until the configured live capability and
identity are verified, API and journal injection remain null.

The dedicated `scripts/governance-service-binding.test.ts` composes the real
canonical HTTP adapter with the existing proposal model. Synthetic HTTP responses
exercise lost-response recovery followed by authentication/scope/cap errors,
malformed resolution, status-mismatched success and mismatched actor/target.
Positive cases settle the captured journal after navigation, including older
receipt revisions and empty history IDs. Construction tests check server identity
copying, immutable connection/scope/authority, session replacement and agent
proposal authority without user approval authority. They require the root-owned
canonical bundle above. Synthetic scope values do not authorize a production
identity convention or host activation.

`bindGovernanceService(connection, session.governance, fetcher)` returns null for
an unsupported capability or invalid connection/transport. Otherwise it returns
`{api, scope, authority}`, with immutable scope/authority copied from the canonical
advertisement and credentials captured only inside the canonical HTTP transport.
The host must tie that advertisement to the same authenticated connection; the
constructor performs no session request, storage access or network operation.

Only `authority.approve` permits the host to offer approval with a journal; proposal
authority does not grant user approval. This is an authority check, not an activation
flag. The service still reauthorizes every operation. Verified browser enrollment
establishes user authority; operator-created agents and legacy unrecorded credentials
must not be promoted by token name or full/table-write scopes.

The binding snapshots the supported connection and canonical scope.
Replacing a connection must leave the old journal parked and cannot redirect an
old request to replacement credentials. Server identity stays stable for the same
credential through reopen and reauthorization; enrollment with a replacement
credential receives a new session identity. An in-flight old response may settle
only its captured journal; it cannot update the replacement workspace. Root owns
generated dependencies and host mounting; this slice owns only the isolated binding,
its tests and this section. Browser real-flow acceptance and a native transport remain
separate handoffs. No host starts using this binding merely because it is imported.

## Durable approval journal

The app-owned IndexedDB database stores one unresolved entry per exact deployment,
session and principal. Each entry includes proposal ID/version, target, typed intent,
revision/candidate/selected events and the original preview token/idempotency key.
It stores no credentials or claimed actor authority. This is operational recovery
state, never a replica table, schema change, source-controlled record or export.

`retain(entry)` uses one readwrite transaction with `durability: 'strict'`. It inserts
only when absent, accepts byte-identical retries, and rejects any different retained
entry. `resolve(entry)` compare-deletes only identical bytes. Both await transaction
completion. Overlapping IndexedDB readwrite transactions serialize across tabs.
See [the IndexedDB durability definition](https://w3c.github.io/IndexedDB/#transaction-durability-hint).
Unknown versions, corrupt data, schema mismatch, quota failures, blocked opening and
unsupported strict durability fail closed. Errors do not erase a conflicting entry.

The model retains before dispatch. An offline or indeterminate response keeps the
same request/key; reopening retries that exact request without a new preview. A
committed retry is reauthorized, then looked up before preview expiry/current revision
checks. Session replacement leaves the old scope parked and must never rebind its
adapter to new credentials. Navigation/disposal does not delete an uncertain request.
Only a validated success, content-free purged result or error with required
`resolution: "not_committed"` compare-deletes the journal. The negative result means
the service durably excluded every late or concurrent execution of the exact original
key/request. Current rejection, rollback, or absence of a success receipt is insufficient.
Errors with `resolution: "unresolved"` keep the complete request, even after a retry
receives authentication, authority, usage-cap, resource, revision or validation rejection.
All errors invalidate the preview independently of whether the key is settled.

The model checks the typed result envelope before settlement. Missing/unknown resolution,
bare read-only `unavailable`, malformed payloads and unknown kinds become indeterminate.
A successful receipt must match the retained proposal ID/version and target, using the
original entry even after navigation/unmount. Replayed receipts may have older revisions
or empty history IDs; neither is a reason to discard them. Failed deletion blocks new approvals
until reopening/reconciliation. A purged result carries no content and clears displayed
copies. Service-side redaction of all proposal/receipt versions remains the owner's
requirement. Local browser storage can be cleared or evicted; no storage API promises
survival of user deletion or physical device failure.

## Verification and enablement gates

Pure boundary tests run with:

```sh
bun test scripts/governance-approval.test.ts scripts/governance-journal.test.ts scripts/governance-list.test.ts scripts/governance-panel.test.ts
bun scripts/check-governance-boundaries.ts
bun --conditions=browser scripts/check-governance-panel-dom.ts
```

CI runs these presentation boundaries and the merged history-selection tests. The external
Life Data HTTP fixture remains a separate pinned-source conformance command; it requires
that owner checkout and is not silently replaced with a stub in CI. Happy DOM checks
verify mounted disablement and cache invalidation, not real browser storage.

Retry regressions exercise normalized API errors representing 401/403/429, every unresolved
mutation code, missing/malformed resolution and envelope, mismatched receipts, late responses,
reopen with the original key, and durable negative settlement requiring fresh review. They do
not exercise HTTP classification. The future core adapter must validate the complete
status/code/resolution matrix, mapping malformed or unlisted pairs to indeterminate after
dispatch. The model does not implement that matrix or infer authentication/negative-receipt
durability. Real positive and negative receipt writers and capability advertisement remain
required before activation. Importing canonical types does not enable a host, service
adapter or approval action.

Actual browser checks are prepared in `scripts/check-governance-browser.ts`. Allocate
two owned disposable targets through the existing browser helper and supply their IDs;
the script reuses `cdp-eval.mjs`, serves only synthetic content, and removes its exact
test database. It neither attaches to an arbitrary tab nor starts another browser.

```sh
bun scripts/check-governance-browser.ts --target <owned-target> --peer <owned-peer> --port <cdp-port> --helper <path-to-cdp-eval.mjs>
```

Real-browser journal acceptance passed all ten groups: strict transaction completion
before retention resolves, second-tab reads, reload/reopen with the exact request/key,
identical retries, compare-delete, competing-client retention with exactly one winner,
session isolation, malformed/unknown-version records, and injected quota/unsupported-
durability failures. An additional controlled renderer crash emitted
`Inspector.targetCrashed`; reopening both pages recovered the exact retained request/key.
Quota and unsupported durability are injected fault cases, not exhaustion of the real
storage device or a second browser engine.

Expanded malformed-record tests first exposed that `get()` cannot distinguish an
absent key from a stored `undefined` value. The journal now checks cursor presence;
all malformed values fail closed, including `undefined`, null, numbers and objects.
Four real-browser mutations were killed: early transaction resolution, replacing an
unresolved entry, deleting mismatched bytes and treating `undefined` as absent. The
restored implementation passed again. Every runner removed its exact synthetic database
and stopped its server; final database enumeration was empty and the owned group closed.

The browser fixture has no live API adapter. Host mounting and actual product-flow
verification remain integration gates; API and journal injection stay null until root
releases them and the real service advertises the operations.

Current tests do not prove service authority, preview inertness, atomic proposal/receipt
storage or end-to-end idempotency. Real service integration must additionally verify
those guarantees, stale approval, actor separation, tombstones/required-field/invariant
conflicts and purge across every retained copy. The conditional HTTP patch prerequisite
is released through Life Data PR11 at main
`12bcc915dcef7a5d0184c714cc79ddfdd5cfdf8d`. The service owner verified deploy
`37480040525` and authenticated session advertisement of `conditional_patch: revision-v1`.
The conformance fixture still pins the original minimal source slice, main
`5e785bcf96d9ecfc37d00bb33515969f6bd876cc` plus
`9121ef66df4dcc3a72c63f87d400a8e9555c17f9`. Released conditional patch does not provide
governance preview/proposals, authenticated actor history or idempotent approval receipts.
The DTO/planner foundation remains a separate prerequisite. There is no deployment or
credential provisioning in this UI slice.
