import { expect, test } from "bun:test";
import { createRequire } from "node:module";
import { createGovernanceAPI, createHttpHub } from "iris-core/client";
import type { GovernanceCapability } from "iris-core/contract";
const { bindGovernanceService } = (await import(
  process.env.IRIS_TEST_SERVICE_BINDING ||
    "../apps/web/src/lib/governance/service-binding"
)) as typeof import("../apps/web/src/lib/governance/service-binding");
import type {
  ApprovalJournal,
  GovernanceAPI,
  PendingApproval,
} from "../apps/web/src/lib/governance/api";
import type {
  ApprovalReceipt,
  Preview,
  Proposal,
} from "../apps/web/src/lib/governance/contract";
const { createProposalReview } = (await import(
  process.env.IRIS_TEST_SERVICE_REVIEW ||
    "../apps/web/src/lib/governance/proposal-review"
)) as typeof import("../apps/web/src/lib/governance/proposal-review");

const webDependency = createRequire(
  new URL("../apps/web/package.json", import.meta.url),
).resolve;
const { get } = (await import(
  webDependency("svelte/store")
)) as typeof import("svelte/store");

// Exercise the real canonical HTTP adapter and presentation model together.
// Only the external HTTP response and durable-store seam are synthetic here.
// Actual IndexedDB persistence is covered by the separately accepted browser fixture.
const scope = {
  deploymentId: "deployment-1",
  sessionId: "session-1",
  principalId: "user-1",
};
const principal = { principalId: scope.principalId, kind: "user" as const };
const capability: GovernanceCapability = {
  deploymentId: "deployment-1",
  sessionId: "session-1",
  protocol: "selected-inverse-proposals-v1",
  principal,
  authority: { propose: true, approve: true },
  limits: {
    maxSelectedEvents: 100,
    maxChangedColumns: 64,
    maxRequestBytes: 65536,
    maxPageSize: 100,
    previewTtlSeconds: 300,
  },
};
const target = { table: "items", rowId: "row-1" };
const revision = { updated_at: "2026-01-01T00:00:00.000Z", hub_at: null };
const proposal: Proposal = {
  id: "proposal-1",
  version: "version-1",
  target,
  intent: { kind: "selected_inverse", eventIds: ["event-1"] },
  changes: [
    {
      column: "state",
      before: { type: "text", value: "closed" },
      after: { type: "text", value: "open" },
    },
  ],
  baseRevision: revision,
  state: "pending",
  proposedBy: { principalId: "agent-1", kind: "agent" },
  claimedOrigin: "synthetic-origin",
  createdAt: revision.updated_at,
  updatedAt: revision.updated_at,
};
const preview: Preview = {
  target,
  revision: { updated_at: "2026-02-01T00:00:00.000Z", hub_at: null },
  changes: proposal.changes,
  selectedEventIds: ["event-1"],
  conflicts: [],
  previewToken: "opaque-preview",
  expiresAt: "2099-01-01T00:00:00.000Z",
};
const receipt: ApprovalReceipt = {
  operationId: "operation-1",
  proposalId: proposal.id,
  proposalVersion: proposal.version,
  target,
  revision,
  historyEventIds: [],
  approvedBy: principal,
  committedAt: revision.updated_at,
};

const identifiedCapability = () => ({
  ...structuredClone(capability),
  deploymentId: "deployment-1",
  sessionId: "session-1",
});
const approval = {
  proposalId: "proposal-1",
  expectedVersion: "version-1",
  previewToken: "opaque-preview",
  idempotencyKey: "retained-key",
};

test("binding copies only canonical service identities and authority, without retaining connection fields", () => {
  const binding = bindGovernanceService(
    {
      endpoint: "https://service.example.test",
      token: "synthetic-client-token",
    },
    identifiedCapability(),
    async () => {
      throw Error("Construction must not access the network");
    },
  );
  expect(binding).not.toBeNull();
  expect(binding!.scope).toEqual({
    deploymentId: "deployment-1",
    sessionId: "session-1",
    principalId: "user-1",
  });
  expect(binding!.authority).toEqual({ propose: true, approve: true });
  expect(Object.keys(binding!).sort()).toEqual(["api", "authority", "scope"]);
  Reflect.set(binding!.scope, "sessionId", "caller-replacement");
  Reflect.set(binding!.authority, "approve", false);
  expect(binding!.scope.sessionId).toBe("session-1");
  expect(binding!.authority.approve).toBe(true);
});

test("mutating connection or advertisement cannot rebind an already-created service", async () => {
  const connection = {
    endpoint: "https://service.example.test",
    token: "original-credential",
  };
  const advertisement = identifiedCapability();
  const sent: Array<{
    url: string;
    authorization: string | null;
    body: unknown;
  }> = [];
  const binding = bindGovernanceService(
    connection,
    advertisement,
    async (url, init) => {
      sent.push({
        url,
        authorization: new Headers(init.headers).get("Authorization"),
        body: JSON.parse(String(init.body)),
      });
      return Response.json({ kind: "success", value: receipt });
    },
  );
  expect(binding).not.toBeNull();
  connection.endpoint = "https://replacement.example.test";
  connection.token = "replacement-credential";
  advertisement.sessionId = "replacement-session";
  advertisement.deploymentId = "replacement-deployment";
  advertisement.principal.principalId = "replacement-principal";
  advertisement.authority.approve = false;
  expect(await binding!.api.approveProposal(approval)).toEqual({
    kind: "success",
    value: receipt,
  });
  expect(sent).toEqual([
    {
      url: "https://service.example.test/v1/governance/proposals/approve",
      authorization: "Bearer original-credential",
      body: approval,
    },
  ]);
  expect(binding!.scope).toEqual(scope);
  expect(binding!.authority.approve).toBe(true);
});

test("a new session binding cannot retry a journal retained under the old session", async () => {
  const advertisement = identifiedCapability();
  const store = journal();
  let approvals = 0;
  const fetcher = async (url: string) => {
    if (url.endsWith("/preview"))
      return Response.json({ kind: "success", value: preview });
    approvals++;
    throw Error("Response lost");
  };
  const old = bindGovernanceService(
    { endpoint: "https://service.example.test", token: "old-credential" },
    advertisement,
    fetcher,
  );
  expect(old).not.toBeNull();
  const first = createProposalReview(old!.api, store, old!.scope);
  first.setOnline(true);
  await first.open(proposal);
  await first.approve();
  const retained = await store.load();
  expect(retained).not.toBeNull();
  first.dispose();
  const replacement = bindGovernanceService(
    { endpoint: "https://service.example.test", token: "new-credential" },
    { ...advertisement, sessionId: "new-session" },
    fetcher,
  );
  expect(replacement).not.toBeNull();
  const second = createProposalReview(
    replacement!.api,
    store,
    replacement!.scope,
  );
  second.setOnline(true);
  await second.ready;
  await second.approve();
  expect(approvals).toBe(1);
  expect(await store.load()).toEqual(retained);
  second.dispose();
});

test("agent proposal authority is preserved separately from unavailable user approval authority", async () => {
  let sent = 0;
  const binding = bindGovernanceService(
    { endpoint: "https://service.example.test", token: "agent-credential" },
    {
      ...identifiedCapability(),
      principal: { principalId: "agent-1", kind: "agent" },
      authority: { propose: true, approve: false },
    },
    async () => {
      sent++;
      throw Error("No authorized approval request");
    },
  );
  expect(binding).not.toBeNull();
  expect(binding!.authority).toEqual({ propose: true, approve: false });
  expect(await binding!.api.approveProposal(approval)).toEqual({
    kind: "error",
    code: "permission_denied",
    resolution: "unresolved",
    conflicts: [],
  });
  expect(sent).toBe(0);
});

test("missing canonical identities, authority or transport never creates a binding", () => {
  let sent = 0;
  const fetcher = async () => {
    sent++;
    throw Error("No request expected");
  };
  const valid = identifiedCapability();
  const {
    deploymentId: _deployment,
    sessionId: _session,
    ...legacyCapability
  } = valid;
  for (const cap of [
    undefined,
    null,
    legacyCapability,
    { ...valid, deploymentId: "" },
    { ...valid, sessionId: "" },
    { ...valid, protocol: "unsupported" },
    { ...valid, authority: { propose: false, approve: false } },
  ]) {
    expect(
      bindGovernanceService(
        { endpoint: "https://service.example.test", token: "synthetic" },
        cap,
        fetcher,
      ),
    ).toBeNull();
  }
  for (const connection of [
    { endpoint: "http://unsafe.example.test", token: "synthetic" },
    { endpoint: "https://service.example.test", token: "" },
  ]) {
    expect(bindGovernanceService(connection, valid, fetcher)).toBeNull();
  }
  expect(
    bindGovernanceService(
      { endpoint: "https://service.example.test", token: "synthetic" },
      valid,
      undefined as unknown as Parameters<typeof bindGovernanceService>[2],
    ),
  ).toBeNull();
  expect(sent).toBe(0);
});

function journal() {
  let pending: PendingApproval | null = null;
  const store: ApprovalJournal = {
    load: async () => structuredClone(pending),
    retain: async (entry) => {
      if (pending && JSON.stringify(entry) !== JSON.stringify(pending))
        throw Error("Occupied journal");
      pending = structuredClone(entry);
    },
    resolve: async (entry) => {
      if (JSON.stringify(entry) !== JSON.stringify(pending))
        throw Error("Mismatched journal");
      pending = null;
    },
  };
  return store;
}

function fixture(
  replies: Array<() => Response | Promise<Response>>,
  cap: unknown = capability,
) {
  const requests: Array<{ url: string; init: RequestInit; body: unknown }> = [];
  let previews = 0;
  const hub = createHttpHub(
    "https://service.example.test",
    "synthetic-client-token",
    async (url, init) => {
      const body = JSON.parse(String(init.body));
      if (url.endsWith("/v1/governance/proposals/preview")) {
        previews++;
        return Response.json({ kind: "success", value: preview });
      }
      requests.push({ url, init, body });
      const reply = replies.shift();
      if (!reply) throw Error("Unexpected request");
      return await reply();
    },
  );
  // Compile-time parity with all nine presentation methods, not a second adapter.
  const api: GovernanceAPI | null = createGovernanceAPI(
    cap,
    hub.governancePost,
  );
  return { api, requests, previews: () => previews };
}

const lost = () => {
  throw Error("Response lost after dispatch");
};
const committed = () => Response.json({ kind: "success", value: receipt });

for (const [label, response] of [
  [
    "401 authority loss",
    () =>
      Response.json(
        {
          kind: "error",
          code: "permission_denied",
          resolution: "unresolved",
          conflicts: [],
        },
        { status: 401 },
      ),
  ],
  [
    "403 scope denial",
    () =>
      Response.json(
        {
          kind: "error",
          code: "permission_denied",
          resolution: "unresolved",
          conflicts: [],
        },
        { status: 403 },
      ),
  ],
  [
    "429 usage cap",
    () =>
      Response.json(
        {
          kind: "error",
          code: "unavailable",
          resolution: "unresolved",
          conflicts: [],
        },
        { status: 429, headers: { "Retry-After": "3" } },
      ),
  ],
  [
    "missing resolution",
    () =>
      Response.json(
        { kind: "error", code: "revision_changed", conflicts: [] },
        { status: 409 },
      ),
  ],
  [
    "wrong HTTP success status",
    () => Response.json({ kind: "success", value: receipt }, { status: 503 }),
  ],
  [
    "wrong authenticated actor",
    () =>
      Response.json({
        kind: "success",
        value: {
          ...receipt,
          approvedBy: { ...principal, principalId: "other-user" },
        },
      }),
  ],
  [
    "wrong retained target",
    () =>
      Response.json({
        kind: "success",
        value: { ...receipt, target: { ...target, rowId: "other-row" } },
      }),
  ],
  [
    "false negative authorization receipt",
    () =>
      Response.json(
        {
          kind: "error",
          code: "permission_denied",
          resolution: "not_committed",
          conflicts: [],
        },
        { status: 401 },
      ),
  ],
] as const) {
  test(`HTTP ${label} cannot erase a lost approval; reopen retries its exact key`, async () => {
    const transport = fixture([lost, response, committed]);
    const store = journal();
    const first = createProposalReview(transport.api, store, scope);
    first.setOnline(true);
    await first.open(proposal);
    await first.approve();
    const retained = await store.load();
    expect(retained).not.toBeNull();
    first.dispose();
    const reopened = createProposalReview(transport.api, store, scope);
    reopened.setOnline(true);
    await reopened.ready;
    await reopened.approve();
    expect(await store.load()).toEqual(retained);
    expect(get(reopened).unresolved).toBe(true);
    await reopened.approve();
    expect(await store.load()).toBeNull();
    expect(get(reopened).receipt).toEqual(receipt);
    expect(transport.previews()).toBe(1);
    expect(transport.requests.map((r) => r.body)).toEqual([
      retained!.request,
      retained!.request,
      retained!.request,
    ]);
    expect(
      transport.requests.every(
        (r) =>
          r.url ===
          "https://service.example.test/v1/governance/proposals/approve",
      ),
    ).toBe(true);
    expect(transport.requests[0].init).toMatchObject({
      redirect: "error",
      credentials: "omit",
    });
    reopened.dispose();
  });
}

for (const [label, response] of [
  [
    "durable negative",
    () =>
      Response.json(
        {
          kind: "error",
          code: "revision_changed",
          resolution: "not_committed",
          conflicts: [],
        },
        { status: 409 },
      ),
  ],
  ["purged", () => Response.json({ kind: "purged" })],
  ["committed older revision with empty history", committed],
] as const) {
  test(`HTTP ${label} settles its original journal after navigation without updating the new view`, async () => {
    let resolve!: (response: Response) => void;
    const waiting = new Promise<Response>((done) => {
      resolve = done;
    });
    let dispatched!: () => void;
    const started = new Promise<void>((done) => {
      dispatched = done;
    });
    const transport = fixture([
      lost,
      () => {
        dispatched();
        return waiting;
      },
    ]);
    const store = journal();
    let applied = 0;
    const model = createProposalReview(transport.api, store, scope, () => {
      applied++;
    });
    model.setOnline(true);
    await model.open(proposal);
    await model.approve();
    const retained = await store.load();
    const retry = model.approve();
    await started;
    model.reset();
    resolve(response());
    await retry;
    expect(await store.load()).toBeNull();
    expect(transport.requests.map((r) => r.body)).toEqual([
      retained!.request,
      retained!.request,
    ]);
    expect(applied).toBe(0);
    expect(get(model).receipt).toBeNull();
    model.dispose();
  });
}

test("unsupported capability leaves presentation unable to preview or dispatch approval", async () => {
  const transport = fixture([], { ...capability, protocol: "unsupported" });
  expect(transport.api).toBeNull();
  const model = createProposalReview(transport.api, journal(), scope);
  model.setOnline(true);
  await model.open(proposal);
  await model.approve();
  expect(get(model).preview).toBeNull();
  expect(transport.requests).toEqual([]);
  expect(transport.previews()).toBe(0);
  model.dispose();
});
