export declare const CORE_CONTRACT_HASH = "8f429c330ff1c9acf42371e2a662d6ea4a8b20c38a513299801a7cdd20441045";
export type JSONValue = unknown;
export type Row = Record<string, JSONValue>;
export type Count = number;
export type FilterOp = "eq" | "ne" | "contains" | "gt" | "gte" | "lt" | "lte" | "empty" | "not_empty";
export type FilterValue = string | number | boolean | null;
export type SortDirection = "asc" | "desc";
export type Sort = {
    column: string;
    direction: SortDirection;
    mode?: SortMode;
};
export type Filter = {
    column: string;
    op: FilterOp;
    value?: FilterValue;
    relative?: FilterRelative;
};
export type View = {
    table: string;
    columns?: string[];
    filters?: Filter[];
    sort?: Sort[];
    limit?: Count;
    offset?: Count;
    trash?: boolean;
    search?: string;
    groups?: FilterGroup[];
    calendar?: CalendarContext;
};
export type OptionDef = {
    v: string;
    d?: string;
    sort?: number;
};
export type PropertyFlag = number | boolean;
export type Property = {
    tbl?: string;
    col: string;
    label?: string | null;
    sort?: number | null;
    type?: string | null;
    required?: PropertyFlag | null;
    default_value?: string | null;
    options?: OptionDef[] | null;
    options_sql?: string | null;
    min_items?: number | null;
    max_items?: number | null;
    pattern?: string | null;
    ref_table?: string | null;
    derived_by?: string | null;
    inputs?: string[] | null;
    immutable?: PropertyFlag | null;
    deprecated?: PropertyFlag | null;
    description?: string | null;
    source?: string | null;
    source_ref?: string | null;
    id?: string;
    updated_at?: string | null;
};
export type Violation = {
    col: string;
    rule: string;
    message: string;
};
export type WriteViolation = {
    col: string;
    rule: string;
    message: string;
    tbl: string;
    row_id: string | null;
};
export type Catalog = {
    tables: Row[];
    properties: Property[];
    rules: Row[];
};
export type WorkspaceRow = {
    record: Row;
    label: string;
};
export type SyncSettings = {
    maxRows?: Count;
    tables?: Record<string, boolean>;
};
export type SyncResult = {
    pulled: Count;
    pushed: Count;
    skipped: string[];
    rejected: Row[];
};
export type SyncStatus = {
    lastSuccessfulSync: string | null;
    pendingUiEdits: Count;
    rejected: Count;
    skippedTables: string[];
};
export type UsagePeriod = {
    start: string;
    end: string;
    anchor_day: Count;
};
export type UsageMetricKind = "cumulative" | "gauge";
export type UsageMetric = {
    kind: UsageMetricKind;
    unit: string;
    used: number | null;
    allowance: number | null;
    cap: number | null;
    alert_at: number[];
    measured_at: string | null;
};
export type UsageCap = {
    metric: string;
    used: number;
    cap: number;
    resets_at: string;
};
export type UsagePrincipal = {
    id: string;
    label: string | null;
    kind: string;
    rows_read: number;
    rows_written: number;
    requests: number;
};
export type UsageSummary = {
    period: UsagePeriod;
    measured_at: string | null;
    capped: UsageCap | null;
    metrics: Record<string, UsageMetric>;
    by_principal: UsagePrincipal[];
};
export type HubNotification = {
    seq: Count;
    id: string;
    created_at: string;
    producer: string;
    type: string;
    severity: string;
    title: string;
    body: string;
    data: JSONValue;
    read_at: string | null;
};
export type NotificationFeed = {
    notifications: HubNotification[];
    next_cursor: null;
    latest_cursor: Count;
    unread_count: Count;
};
export type NotificationPresentation = {
    notifications: HubNotification[];
    baseline: Count;
};
export type NotificationReadSelector = {
    ids?: string[];
    through?: Count;
};
export type NotificationReadResult = {
    unread_count: Count;
};
export type EmptyArgs = {};
export type EndpointArgs = {
    endpoint: string;
};
export type SyncArgs = {
    endpoint: string;
    maxRows?: Count;
    tables?: Record<string, boolean>;
};
export type OptionsArgs = {
    table: string;
    column: string;
};
export type WriteArgs = {
    table: string;
    patch: Row;
    expectedUpdatedAt?: string;
};
export type NotificationReadArgs = {
    endpoint: string;
    selector: NotificationReadSelector;
};
export type NotificationPresentationArgs = {
    feed: NotificationFeed;
    baseline: Count | null;
};
export type SearchArgs = {
    text: string;
    table?: string;
    limit?: Count;
    offset?: Count;
};
export type SearchHit = {
    table: string;
    id: string;
    label: string;
    excerpt: string;
};
export type SavedViewDefinition = {
    version: Count;
    columns?: string[];
    filters?: Filter[];
    sort?: Sort[];
    search?: string;
    trash?: boolean;
    widths?: Record<string, number>;
    groups?: FilterGroup[];
    timeZone?: string;
    dayStartMinutes?: number;
    actions?: RowAction[];
    layout?: ViewLayoutItem[];
    presentation?: ViewPresentation;
};
export type SavedViewRecord = {
    id: string;
    name: string;
    tbl: string;
    updated_at: string | null;
    deleted_at: string | null;
    definition: SavedViewDefinition | null;
    view: View | null;
    unavailable: string | null;
};
export type SavedViewList = {
    views: SavedViewRecord[];
    unavailable: string | null;
};
export type ListViewsArgs = {
    table: string;
    trash?: boolean;
};
export type SaveViewArgs = {
    table: string;
    name: string;
    definition: SavedViewDefinition;
    id?: string;
    expectedUpdatedAt?: string;
};
export type DeleteViewArgs = {
    id: string;
    expectedUpdatedAt: string;
};
export type WriteabilityArgs = {
    table: string;
};
export type Writeability = {
    writable: boolean;
    reason: WriteViolation | null;
};
export type RemoteRecord = {
    record: Row;
    label: string;
    deleted: boolean;
};
export type RemoteRowsArgs = {
    endpoint: string;
    table: string;
    limit?: Count;
    cursor?: string;
};
export type RemoteRowsPage = {
    rows: RemoteRecord[];
    nextCursor: string | null;
};
export type RemoteRowArgs = {
    endpoint: string;
    table: string;
    id: string;
};
export type RemoteRowResult = {
    row: RemoteRecord | null;
};
export type UndoKind = "create" | "edit" | "trash" | "restore";
export type UndoAction = {
    receiptId: string;
    table: string;
    rowId: string;
    kind: UndoKind;
};
export type UndoStatus = {
    action: UndoAction | null;
};
export type UndoArgs = {
    receiptId: string;
};
export type EnrollmentApprovalArgs = {
    fingerprint: string;
    name: string;
    profile?: string;
};
export type EnrollmentPolicy = {
    pollIntervalSeconds: Count;
    timeoutSeconds: Count;
    maxResponseBytes: Count;
};
export type EnrollmentApproval = {
    path: string;
    approvalCode: string;
    deviceName: string;
    policy: EnrollmentPolicy;
};
export type ReplicaIneligibilityCode = "full_scope_required" | "invalid_capabilities" | "schema_unavailable" | "replica_sync_disabled";
export type ReplicaIneligibility = {
    code: ReplicaIneligibilityCode;
    message: string;
};
export type ReplicaEligibility = {
    allowed: boolean;
    reason: ReplicaIneligibility | null;
};
export type SessionInfo = {
    name: string;
    scopes: string[];
    replica: ReplicaEligibility;
    governance?: GovernanceCapability;
    enrollmentProfile?: EnrollmentProfileReceipt;
    pushRegistration?: PushRegistrationCapability;
    pushProfiles?: PushAppProfile[];
};
export type SessionDataArgs = {
    data: JSONValue;
    expectedProfile?: EnrollmentProfileExpectation;
};
export type SessionReply = {
    status: Count;
    data: JSONValue;
    retryAfterSeconds?: Count;
};
export type EnrollmentPollArgs = {
    reply: SessionReply;
    expectedFingerprint: string;
    expectedProfile?: EnrollmentProfileExpectation;
};
export type EnrollmentPollState = "pending" | "approved";
export type EnrollmentPollResult = {
    state: EnrollmentPollState;
    session: SessionInfo | null;
    retryAfterSeconds: Count | null;
};
export type SessionRevocationState = "revoked" | "unauthorized";
export type SessionRevocationResult = {
    state: SessionRevocationState;
};
export type ReferenceSourcesArgs = {
    table: string;
};
export type ReferenceSource = {
    table: string;
    column: string;
    label: string;
    type: "ref" | "multi_ref";
    incomplete: boolean;
};
export type ReferencedByArgs = {
    table: string;
    rowId: string;
    sourceTable: string;
    column: string;
    limit?: Count;
    offset?: Count;
};
export type ReferencedByPage = {
    source: ReferenceSource;
    rows: WorkspaceRow[];
    nextOffset: Count | null;
};
export type RejectedEdit = {
    table: string;
    rowID: string;
    submitted: Row;
    errors: Row[];
};
export type RejectionsArgs = {
    limit?: Count;
    offset?: Count;
};
export type RejectionsPage = {
    rejections: RejectedEdit[];
    nextOffset: Count | null;
};
export type HubCapabilities = {
    row_api: "v1";
    schema: "none" | "full-ddl-v1";
    replica_sync: boolean;
    subscriptions: "durable-pull-v1" | null;
    files: "opaque-key-v1";
    conditional_patch?: "revision-v1";
    subscription_features?: "scalar-lifecycle-v1";
    governance?: GovernanceCapability;
    rowCreation?: RowCreationCapability;
    push_registration?: PushRegistrationCapability;
    push_profiles?: PushAppProfile[];
    changesets?: ChangesetCapability;
};
export type HubSession = {
    name: string;
    scopes: string[];
    capabilities?: HubCapabilities;
};
export type ScopedReplicaUnsupported = {
    error: "scoped_replica_unsupported";
    message: string;
};
export type SortMode = "value" | "options";
export type FilterRelative = "today";
export type FilterGroup = {
    match: "all" | "any";
    filters: Filter[];
};
export type CalendarContext = {
    today: string;
    start: string;
    end: string;
};
export type RowAction = {
    id: string;
    label: string;
    values: Row;
};
export type ViewLayoutItem = {
    kind: "column" | "action";
    id: string;
};
export type RunRowActionArgs = {
    viewId: string;
    actionId: string;
    rowId: string;
    expectedUpdatedAt: string;
    expectedViewUpdatedAt: string;
};
export type SourceLinkArgs = {
    url: string;
};
export type SourceRecordDestination = {
    table: string;
    row: string;
};
export type SourceLinkResult = {
    destination?: SourceRecordDestination;
};
export type Target = {
    table: string;
    rowId: string;
};
export type Revision = {
    updated_at: string;
    hub_at: string | null;
};
export type NullCell = {
    type: "null";
};
export type TextCell = {
    type: "text";
    value: string;
};
export type IntegerCell = {
    type: "integer";
    value: string;
};
export type RealCell = {
    type: "real";
    value: number;
};
export type CellValue = NullCell | TextCell | IntegerCell | RealCell;
export type ActorKind = "user" | "agent" | "service";
export type Actor = {
    principalId: string;
    kind: ActorKind;
};
export type Change = {
    column: string;
    before: CellValue;
    after: CellValue;
};
export type ConflictCode = "later_column_change" | "history_unavailable" | "revision_changed" | "validation_failed" | "proposal_changed" | "unavailable";
export type Conflict = {
    code: ConflictCode;
    column: string | null;
    eventIds: string[];
    message: string;
};
export type SelectedInverseIntent = {
    kind: "selected_inverse";
    eventIds: string[];
};
export type ProposedCellChange = {
    column: string;
    after: CellValue;
};
export type PatchIntent = {
    kind: "patch";
    changes: ProposedCellChange[];
};
export type Intent = SelectedInverseIntent | PatchIntent;
export type PreviewRequest = {
    target: Target;
    intent: Intent;
};
export type Preview = {
    target: Target;
    revision: Revision;
    changes: Change[];
    selectedEventIds: string[];
    conflicts: Conflict[];
    previewToken: string | null;
    expiresAt: string | null;
};
export type HistoryEvent = {
    id: string;
    operationId: string | null;
    target: Target;
    column: string;
    before: CellValue | null;
    after: CellValue | null;
    occurredAt: string;
    actor: Actor | null;
    claimedOrigin: string | null;
    reversible: boolean;
    unavailableReason: string | null;
};
export type ProposalState = "pending" | "approved" | "rejected";
export type Proposal = {
    id: string;
    version: string;
    target: Target;
    intent: Intent;
    changes: Change[];
    baseRevision: Revision;
    state: ProposalState;
    proposedBy: Actor;
    claimedOrigin: string | null;
    createdAt: string;
    updatedAt: string;
};
export type ApprovalReceipt = {
    operationId: string;
    proposalId: string;
    proposalVersion: string;
    target: Target;
    revision: Revision;
    historyEventIds: string[];
    approvedBy: Actor;
    committedAt: string;
};
export type MutationErrorCode = "proposal_changed" | "revision_changed" | "history_unavailable" | "validation_failed" | "permission_denied" | "unavailable" | "expired_preview" | "idempotency_conflict";
export type MutationResolution = "unresolved" | "not_committed";
export type MutationError = {
    kind: "error";
    code: MutationErrorCode;
    resolution: MutationResolution;
    conflicts: Conflict[];
};
export type PurgedResult = {
    kind: "purged";
};
export type TransportErrorCode = "offline" | "indeterminate";
export type TransportError = {
    kind: "transport_error";
    code: TransportErrorCode;
};
export type UnavailableResult = {
    kind: "unavailable";
};
export type ProposalSuccess = {
    kind: "success";
    value: Proposal;
};
export type ApprovalSuccess = {
    kind: "success";
    value: ApprovalReceipt;
};
export type ProposalMutationResult = ProposalSuccess | PurgedResult | MutationError | TransportError;
export type ApprovalResult = ApprovalSuccess | PurgedResult | MutationError | TransportError;
export type ProposalResult = ProposalSuccess | UnavailableResult | TransportError;
export type PreviewSuccess = {
    kind: "success";
    value: Preview;
};
export type PreviewResult = PreviewSuccess | UnavailableResult | TransportError;
export type HistoryEventsPage = {
    events: HistoryEvent[];
    nextCursor: string | null;
};
export type HistoryEventsSuccess = {
    kind: "success";
    value: HistoryEventsPage;
};
export type HistoryEventsResult = HistoryEventsSuccess | UnavailableResult | TransportError;
export type ProposalsPage = {
    proposals: Proposal[];
    nextCursor: string | null;
};
export type ProposalsSuccess = {
    kind: "success";
    value: ProposalsPage;
};
export type ProposalsResult = ProposalsSuccess | UnavailableResult | TransportError;
export type HistoryEventsArgs = {
    target: Target;
    cursor?: string;
    limit?: Count;
};
export type CreateProposalArgs = {
    previewToken: string;
    idempotencyKey: string;
    claimedOrigin?: string;
};
export type ListProposalsArgs = {
    target?: Target;
    state?: ProposalState;
    cursor?: string;
    limit?: Count;
};
export type GetProposalArgs = {
    proposalId: string;
    version?: string;
};
export type EditProposalArgs = {
    proposalId: string;
    expectedVersion: string;
    previewToken: string;
    idempotencyKey: string;
    claimedOrigin?: string;
};
export type PreviewProposalArgs = {
    proposalId: string;
    expectedVersion: string;
};
export type ApproveProposalArgs = {
    proposalId: string;
    expectedVersion: string;
    previewToken: string;
    idempotencyKey: string;
};
export type RejectProposalArgs = {
    proposalId: string;
    expectedVersion: string;
    idempotencyKey: string;
};
export type GovernanceLimits = {
    maxSelectedEvents: Count;
    maxChangedColumns: Count;
    maxRequestBytes: Count;
    maxPageSize: Count;
    previewTtlSeconds: Count;
};
export type GovernanceAuthority = {
    propose: boolean;
    approve: boolean;
};
export type GovernanceCapability = {
    protocol: "selected-inverse-proposals-v1";
    principal: Actor;
    authority: GovernanceAuthority;
    limits: GovernanceLimits;
    deploymentId: string;
    sessionId: string;
};
export type EnrollmentProfileReceipt = {
    id: string;
    revision: string;
};
export type EnrollmentProfileExpectation = {
    id: string;
    scopes: string[];
};
export type CreationPolicyRef = {
    id: string;
    revision: string;
};
export type RowCreationCapability = {
    protocol: "atomic-origin-v1";
    policies: CreationPolicyRef[];
};
export type RowCreationTarget = {
    kind: "generated" | "adopted";
    id: string;
};
export type RowCreationRequest = {
    policy: CreationPolicyRef;
    sourceId: string;
    occurrenceKey?: CreationOccurrenceKey;
    target: RowCreationTarget;
    updatedAt: string;
    values: Record<string, FilterValue>;
};
export type RowCreatedReceipt = {
    kind: "created";
    policy: CreationPolicyRef;
    id: string;
    revision: Revision;
    originId: string;
};
export type RowExistingReceipt = {
    kind: "existing";
    policy: CreationPolicyRef;
    id: string;
};
export type RowCreationReceipt = RowCreatedReceipt | RowExistingReceipt;
export type CreationOccurrenceKey = string | number;
export type ResolveDerivedArgs = {
    endpoint: string;
    table: string;
    id: string;
    column: string;
    expectedUpdatedAt: string;
};
export type DerivationFailure = {
    id: string;
    col: string;
    error: string;
    status?: number;
    retry_after?: number;
};
export type ResolveDerivedResult = {
    derived: number;
    failed: DerivationFailure[];
};
export type ViewPresentation = {
    kind: "table" | "calendar" | "gallery" | "board";
    dateColumn?: string;
    endDateColumn?: string;
    coverColumn?: string;
    groupColumn?: string;
};
export type CalendarRowsArgs = {
    rows: Row[];
    dateColumn: string;
    endDateColumn?: string;
    days: CalendarContext[];
};
export type CalendarDayRows = {
    date: string;
    rowIds: string[];
};
export type CalendarRowsResult = {
    days: CalendarDayRows[];
    undated: string[];
};
export type BoardRowsArgs = {
    rows: Row[];
    column: string;
    options: string[];
};
export type BoardColumnRows = {
    value: string | null;
    rowIds: string[];
};
export type BoardRowsResult = {
    columns: BoardColumnRows[];
};
export type SidebarPinList = {
    pins: SidebarPin[];
    unavailable: string | null;
};
export type SidebarPin = {
    id: string;
    tbl: string;
    position: number;
    updated_at: string;
    deleted_at: string | null;
    unavailable: string | null;
};
export type PinTableArgs = {
    table: string;
    expectedUpdatedAt: string | null;
};
export type UnpinTableArgs = {
    id: string;
    expectedUpdatedAt: string;
};
export type PinRevision = {
    id: string;
    updated_at: string;
};
export type MoveTablePinArgs = {
    id: string;
    direction: "up" | "down";
    expected: PinRevision[];
};
export type GetViewDefaultArgs = {
    table: string;
};
export type SetViewDefaultArgs = {
    table: string;
    viewId: string | null;
    expectedUpdatedAt: string | null;
};
export type ViewDefault = {
    table: string;
    viewId: string | null;
    updated_at: string | null;
    view: SavedViewRecord | null;
    unavailable: string | null;
};
export type PushAppProfile = {
    id: string;
    platform: PushPlatform;
};
export type PushRegistrationCapability = {
    protocol: string;
    deploymentIdentity: string;
    sessionBinding: string;
    profiles: PushAppProfile[];
};
export type PushRegistrationState = {
    installationId: string;
    revision: string;
    state: PushRegistrationStatus;
    deploymentIdentity: string;
    sessionBinding: string;
    appProfile: string;
    activatedAfterSeq: Count;
    updatedAt: string;
};
export type PushRegistrationRequest = {
    appProfile: string;
    deviceToken: string;
    expectedRevision: string | null;
    requestId: string;
};
export type PushRevocationRequest = {
    appProfile: string;
    expectedRevision: string | null;
    requestId: string;
};
export type PushRegistrationReceipt = {
    requestId: string;
    registration: PushRegistrationState;
};
export type PushPlatform = "ios" | "macos";
export type PushRegistrationStatus = "active" | "revoked";
export type ChangesetCreate = {
    kind: "create";
    table: string;
    id: string;
    expected_revision: null;
    values: Row;
};
export type ChangesetPatch = {
    kind: "patch";
    table: string;
    id: string;
    expected_revision: Revision;
    values: Row;
};
export type ChangesetSoftDelete = {
    kind: "soft_delete";
    table: string;
    id: string;
    expected_revision: Revision;
};
export type ChangesetOperation = ChangesetCreate | ChangesetPatch | ChangesetSoftDelete;
export type ChangesetReadSet = {
    table: string;
    where: Record<string, FilterValue>;
    expected: ChangesetReadMember[];
};
export type ChangesetInput = {
    operations: ChangesetOperation[];
    reads: ChangesetReadSet[];
};
export type ChangesetChange = {
    table: string;
    id: string;
    kind: "create" | "patch" | "soft_delete";
    before: Row | null;
    after: Row | null;
};
export type ChangesetPreview = {
    changes: ChangesetChange[];
    previewToken: string;
    expiresAt: string;
};
export type ChangesetProposal = {
    id: string;
    version: string;
    state: ProposalState;
    input: ChangesetInput;
    changes: ChangesetChange[];
    dependencies: string;
    proposedBy: Actor;
    claimedOrigin: string | null;
    createdAt: string;
    updatedAt: string;
};
export type ChangesetRowReceipt = {
    table: string;
    id: string;
    kind: "create" | "patch" | "soft_delete";
    revision: Revision;
};
export type ChangesetApproval = {
    operationId: string;
    proposalId: string;
    proposalVersion: string;
    rows: ChangesetRowReceipt[];
    historyEventIds: string[];
    approvedBy: Actor;
    committedAt: string;
};
export type ChangesetPreviewSuccess = {
    kind: "success";
    value: ChangesetPreview;
};
export type ChangesetPreviewResult = ChangesetPreviewSuccess | UnavailableResult | PurgedResult | MutationError | TransportError;
export type ChangesetProposalSuccess = {
    kind: "success";
    value: ChangesetProposal;
};
export type ChangesetProposalResult = ChangesetProposalSuccess | UnavailableResult | PurgedResult | MutationError | TransportError;
export type ChangesetApprovalSuccess = {
    kind: "success";
    value: ChangesetApproval;
};
export type ChangesetApprovalResult = ChangesetApprovalSuccess | UnavailableResult | PurgedResult | MutationError | TransportError;
export type ChangesetLimits = {
    maxOperations: number;
    maxTables: number;
    maxBytes: number;
    maxReadSets: number;
    maxMembershipRows: number;
    maxReadRows: number;
    previewTtlSeconds: number;
};
export type ChangesetCapability = {
    protocol: "bounded-changeset-proposals-v1";
    principal: Actor;
    authority: GovernanceAuthority;
    limits: ChangesetLimits;
    deploymentId: string;
    sessionId: string;
};
export type ChangesetReadMember = {
    id: string;
    revision: Revision;
};
export type ConsumerConfig = {
    version: number;
    namespace: string;
    bindings: Record<string, unknown>;
};
export type ConsumerConfigReply = {
    profile: EnrollmentProfileReceipt;
    config: ConsumerConfig;
};
export type CatalogProjectionRequest = {
    table: string;
    columns: string[];
};
export type CatalogProjectionOption = {
    v: string;
    d?: string;
    sort?: number;
};
export type CatalogProjectedProperty = {
    column: string;
    type: string;
    description: string | null;
    required: boolean;
    readOnly: boolean;
    options?: CatalogProjectionOption[];
};
export type CatalogProjectionReply = {
    table: string;
    properties: CatalogProjectedProperty[];
};
export type RowsQueryOrder = {
    column: string;
    direction: "asc" | "desc";
};
export type RowsQueryRequest = {
    table: string;
    columns: string[];
    filter?: unknown;
    order?: RowsQueryOrder[];
    limit?: number;
    cursor?: string;
};
export type RowsQueryReply = {
    rows: Row[];
    next_cursor: string | null;
};
export type CaptureInput = {
    text?: string;
    url?: string;
};
export type CaptureItem = {
    kind: string;
    id: string;
};
export type CaptureRequest = {
    request_id: string;
    input: CaptureInput;
    intent: "save" | "record_consumption";
    fields?: Record<string, unknown>;
};
export type CaptureReceipt = {
    request_id: string;
    state: "received" | "processing" | "saved" | "needs_review" | "failed" | "uncertain";
    item?: CaptureItem;
};
export type SQLScalar = string | number | null;
export type CalendarSlot = "today" | "start" | "end";
export type ReadPlanLiteral = {
    kind: "literal";
    value: SQLScalar;
};
export type ReadPlanCalendar = {
    kind: "calendar";
    slot: CalendarSlot;
};
export type ReadPlanParameter = ReadPlanLiteral | ReadPlanCalendar;
export type ReadPlanKind = "list" | "count";
export type ReadPlanCalendarPolicy = {
    timeZone: string;
    dayStartMinutes: Count;
};
export type ReadPlanGuard = {
    kind: "schema" | "catalog" | "view" | "identity";
    sql: string;
    parameters: SQLScalar[];
    expectedRows: Row[];
};
export type PrepareReadPlanArgs = {
    workspaceID: string;
    replicaID: string;
    table: string;
    kind: ReadPlanKind;
    viewID?: string;
    expectedViewUpdatedAt?: string;
};
export type ReadPlan = {
    version: Count;
    workspaceID: string;
    replicaID: string;
    table: string;
    viewID: string | null;
    viewUpdatedAt: string | null;
    kind: ReadPlanKind;
    sql: string;
    parameters: ReadPlanParameter[];
    columns: string[];
    displayColumn: string | null;
    maximumRows: Count;
    calendarPolicy: ReadPlanCalendarPolicy | null;
    guards: ReadPlanGuard[];
};
export type SaveCatalogPropertyArgs = {
    table: string;
    column: string;
    expectedUpdatedAt: string | null;
    fields: Row;
    addColumn?: boolean;
};
export type SaveCatalogRuleArgs = {
    table: string;
    id: string;
    expectedUpdatedAt: string | null;
    fields: Row;
};
export interface CoreOperations {
    catalog: {
        args: EmptyArgs;
        result: Catalog;
    };
    rows: {
        args: View;
        result: WorkspaceRow[];
    };
    options: {
        args: OptionsArgs;
        result: string[];
    };
    write: {
        args: WriteArgs;
        result: Row;
    };
    status: {
        args: EmptyArgs;
        result: SyncStatus;
    };
    sync: {
        args: SyncArgs;
        result: SyncResult;
    };
    serviceUsage: {
        args: EndpointArgs;
        result: UsageSummary;
    };
    serviceNotifications: {
        args: EndpointArgs;
        result: NotificationFeed;
    };
    markNotificationsRead: {
        args: NotificationReadArgs;
        result: NotificationReadResult;
    };
    notificationPresentation: {
        args: NotificationPresentationArgs;
        result: NotificationPresentation;
    };
    search: {
        args: SearchArgs;
        result: SearchHit[];
    };
    listViews: {
        args: ListViewsArgs;
        result: SavedViewList;
    };
    saveView: {
        args: SaveViewArgs;
        result: SavedViewRecord;
    };
    deleteView: {
        args: DeleteViewArgs;
        result: SavedViewRecord;
    };
    writeability: {
        args: WriteabilityArgs;
        result: Writeability;
    };
    remoteRows: {
        args: RemoteRowsArgs;
        result: RemoteRowsPage;
    };
    remoteRow: {
        args: RemoteRowArgs;
        result: RemoteRowResult;
    };
    undoStatus: {
        args: EmptyArgs;
        result: UndoStatus;
    };
    undo: {
        args: UndoArgs;
        result: Row;
    };
    enrollmentApproval: {
        args: EnrollmentApprovalArgs;
        result: EnrollmentApproval;
    };
    validateDeviceSession: {
        args: SessionDataArgs;
        result: SessionInfo;
    };
    enrollmentPollResult: {
        args: EnrollmentPollArgs;
        result: EnrollmentPollResult;
    };
    sessionRevocationResult: {
        args: SessionReply;
        result: SessionRevocationResult;
    };
    referenceSources: {
        args: ReferenceSourcesArgs;
        result: ReferenceSource[];
    };
    referencedBy: {
        args: ReferencedByArgs;
        result: ReferencedByPage;
    };
    rejections: {
        args: RejectionsArgs;
        result: RejectionsPage;
    };
    runRowAction: {
        args: RunRowActionArgs;
        result: Row;
    };
    resolveSourceLink: {
        args: SourceLinkArgs;
        result: SourceLinkResult;
    };
    historyEvents: {
        args: HistoryEventsArgs;
        result: HistoryEventsResult;
    };
    previewChanges: {
        args: PreviewRequest;
        result: PreviewResult;
    };
    createProposal: {
        args: CreateProposalArgs;
        result: ProposalMutationResult;
    };
    listProposals: {
        args: ListProposalsArgs;
        result: ProposalsResult;
    };
    getProposal: {
        args: GetProposalArgs;
        result: ProposalResult;
    };
    editProposal: {
        args: EditProposalArgs;
        result: ProposalMutationResult;
    };
    previewProposal: {
        args: PreviewProposalArgs;
        result: PreviewResult;
    };
    approveProposal: {
        args: ApproveProposalArgs;
        result: ApprovalResult;
    };
    rejectProposal: {
        args: RejectProposalArgs;
        result: ProposalMutationResult;
    };
    resolveDerived: {
        args: ResolveDerivedArgs;
        result: ResolveDerivedResult;
    };
    calendarRows: {
        args: CalendarRowsArgs;
        result: CalendarRowsResult;
    };
    boardRows: {
        args: BoardRowsArgs;
        result: BoardRowsResult;
    };
    pinTable: {
        args: PinTableArgs;
        result: SidebarPinList;
    };
    listSidebarPins: {
        args: EmptyArgs;
        result: SidebarPinList;
    };
    unpinTable: {
        args: UnpinTableArgs;
        result: SidebarPinList;
    };
    moveTablePin: {
        args: MoveTablePinArgs;
        result: SidebarPinList;
    };
    getViewDefault: {
        args: GetViewDefaultArgs;
        result: ViewDefault;
    };
    setViewDefault: {
        args: SetViewDefaultArgs;
        result: ViewDefault;
    };
    prepareReadPlan: {
        args: PrepareReadPlanArgs;
        result: ReadPlan;
    };
    saveCatalogProperty: {
        args: SaveCatalogPropertyArgs;
        result: Property;
    };
    saveCatalogRule: {
        args: SaveCatalogRuleArgs;
        result: Row;
    };
}
export type CoreMethod = keyof CoreOperations;
export type CoreArgs<M extends CoreMethod> = CoreOperations[M]["args"];
export type CoreResult<M extends CoreMethod> = CoreOperations[M]["result"];
export type CoreHandlers = {
    [M in CoreMethod]: (args: CoreArgs<M>) => CoreResult<M> | Promise<CoreResult<M>>;
};
