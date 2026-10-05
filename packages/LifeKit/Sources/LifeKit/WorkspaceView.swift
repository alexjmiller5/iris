import SwiftUI
import UniformTypeIdentifiers

public struct WorkspaceView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = WorkspaceModel()
  @State private var importing = false
  @State private var settings = false
  @State private var options = false
  @State private var savedViews = false
  @State private var showingGraph = false
  @State private var showingStatus = false
  @State private var pendingGraphTable: (table: String, generation: Int)?
  @State private var preferredColumn: NavigationSplitViewColumn = .detail
  @State private var navigationRequest = 0
  @State private var openingDestination = false
  @State private var navigationError: String?
  @State private var tableSearchPresented = false
  @State private var editor: EditorTarget?
  @State private var online: OnlineBrowseModel?
  @State private var quickFind: QuickFindCoordinator?
  @State private var rejectionInbox: RejectionInboxModel?
  @State private var rejectionError: String?
  @State private var pendingRejection: (review: PreparedRejectionReview, request: Int)?
  @State private var pendingSearchEditor:
    (target: EditorTarget, generation: Int, destination: NativeDestination)?
  @State private var pendingReferenceEditor:
    (destination: ReferenceDestination, source: WorkspaceEditingContext, generation: Int)?
  @State private var pendingLink = PendingNativeLink()
  @State private var pendingDuplicateEditor: (target: EditorTarget, generation: Int)?
  private let demo: Bool

  public init(demo: Bool = false) { self.demo = demo }

  public var body: some View {
    // Stacked, not a safe-area inset: navigation bars ignore insets added outside them.
    VStack(spacing: 0) {
      pendingLinkBanner
      if openingDestination {
        HStack(spacing: 12) {
          ProgressView().accessibilityLabel("Opening destination…")
          VStack(alignment: .leading, spacing: 4) {
            Text("Opening destination…")
            if model.syncing {
              Text("Waiting for sync to finish.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button("Cancel") {
            // Queued core calls retain transaction ownership. Ignore their late replies.
            navigationRequest += 1
            openingDestination = false
            navigationError = nil
          }
          .accessibilityIdentifier("cancel-destination")
          .accessibilityLabel("Cancel opening destination")
        }
        .padding()
        .background(.bar)
      }
      content
    }
    // Receiving a URL only retains it; navigation waits for an explicit Open.
    .onOpenURL { pendingLink.receive($0) }
    // An open window keeps its workspace context instead of spawning an empty one.
    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
  }

  private var content: some View {
    Group {
      if model.client == nil {
        welcome
      } else {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
          List {
            Button(action: showQuickFind) {
              Label("Find records", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!canFind)
            .accessibilityIdentifier("quick-find-sidebar")
            Button {
              showingGraph = true
            } label: {
              Label("Schema graph", systemImage: "point.3.connected.trianglepath.dotted")
            }.disabled(!canFind).accessibilityIdentifier("schema-graph-sidebar")
            WorkspaceSidebar(
              tables: NativeSidebarTables(model.tables), recents: model.recents,
              selectedTable: model.table, disabled: !canFind,
              error: navigationError,
              onOpen: { openDestination($0) })
          }
          .navigationTitle("Life UI")
          .navigationSplitViewColumnWidth(min: 200, ideal: 240)
          #if os(iOS)
            .toolbar {
              ToolbarItem(placement: .bottomBar) { statusButton }
              ToolbarItem(placement: .bottomBar) { Spacer() }
              ToolbarItem(placement: .bottomBar) { workspaceMenu }
            }
          #else
            .safeAreaInset(edge: .bottom) {
              VStack(alignment: .leading, spacing: 8) {
                Text(model.location).font(.caption).foregroundStyle(.secondary)
                if model.isReplica {
                  SyncSummary(model: model)
                  Button(model.syncing ? "Syncing…" : "Sync now") {
                    Task { await model.synchronize() }
                  }
                  .disabled(model.syncing).accessibilityIdentifier("sync-now")
                }
                Button("Hub connection") { settings = true }.disabled(openingDestination)
                Button("Close workspace") { Task { await model.close() } }
              }.padding().frame(maxWidth: .infinity, alignment: .leading)
              .background(.bar)
            }
          #endif
        } detail: {
          #if os(macOS)
            if showingGraph, let catalog = model.catalog {
              SchemaGraphView(
                catalog: catalog, groups: model.groups,
                openTable: { table in
                  openDestination(NativeDestination(table: table))
                }, saveGroups: model.saveGroups
              )
              .disabled(openingDestination)
              .navigationTitle("Schema graph")
            } else {
              records
            }
          #else
            records
          #endif
        }
        .onChange(of: model.table) { showingGraph = false }
      }
    }
    .task { if demo { await model.open(demo: true) } else { await model.resumeConnection() } }
    .task(id: "\(model.services.generation)|\(scenePhase == .active)") {
      guard scenePhase == .active else { return }
      await model.services.poll()
    }
    .task(id: model.queryKey) { await model.reload() }
    .task(id: "\(model.workspaceGeneration)|\(scenePhase == .active)") {
      guard scenePhase == .active else { return }
      await model.recents?.refresh()
      guard !Task.isCancelled else { return }
      await model.runAutomaticSync()
    }
    .onChange(of: model.syncing) {
      if !model.syncing {
        let recents = model.recents
        let inbox = rejectionInbox
        Task {
          await recents?.refresh()
          await inbox?.refresh()
        }
      }
    }
    .sheet(item: $editor, onDismiss: finishEditorDismissal) { target in
      RecordEditor(
        model: model, original: target.row, context: target.context, recovered: target.recovered,
        preparedEditor: target.preparedEditor, linkWaiting: pendingLink.request != nil,
        isCurrent: { editor?.id == target.id },
        onReference: { destination in
          guard editor?.id == target.id, let source = target.context,
            source.workspace === model.client, source.table == model.table
          else { return }
          pendingReferenceEditor = (destination, source, model.workspaceGeneration)
          editor = nil
        },
        onDuplicate: { copy in
          guard editor?.id == target.id, let source = target.context,
            source.workspace === model.client, source.table == model.table
          else { return }
          pendingDuplicateEditor = (
            EditorTarget(row: nil, context: source, preparedEditor: copy),
            model.workspaceGeneration
          )
          editor = nil
        }, onSaved: { editor = nil })
    }
    .sheet(
      item: $online,
      onDismiss: {
        online?.cancel()
        online = nil
      }
    ) { browser in
      OnlineBrowseView(model: browser, fields: model.properties.map(CatalogField.init))
    }
    .onChange(of: model.table) {
      online?.cancel()
      online = nil
    }
    .onChange(of: model.isReplica) {
      online?.cancel()
      online = nil
    }
    #if os(iOS)
      .sheet(
        isPresented: $showingGraph,
        onDismiss: {
          guard let pending = pendingGraphTable else { return }
          pendingGraphTable = nil
          guard pending.generation == model.workspaceGeneration else { return }
          openDestination(NativeDestination(table: pending.table))
        }
      ) {
        NavigationStack {
          if let catalog = model.catalog {
            SchemaGraphView(
              catalog: catalog, groups: model.groups,
              openTable: { table in
                guard showingGraph, canFind else { return }
                pendingGraphTable = (table, model.workspaceGeneration)
                showingGraph = false
              }, saveGroups: model.saveGroups
            )
            .navigationTitle("Schema graph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showingGraph = false }.accessibilityIdentifier("graph-done")
              }
            }
          }
        }
      }
      .sheet(isPresented: $showingStatus) { WorkspaceStatusSheet(model: model) }
    #endif
    .sheet(isPresented: $settings) { HubConnectionView(model: model) }
    .sheet(isPresented: $options) { WorkspaceOptionsView(model: model) }
    .sheet(isPresented: $savedViews) {
      SavedViewsView(model: model, onChoose: recordNavigationSucceeded)
    }
    .sheet(item: $quickFind, onDismiss: openSearchEditor) { find in
      QuickFindView(model: find, incomplete: !model.skippedTables.isEmpty) { resolved in
        guard find.isCurrent, quickFind === find, editor == nil, let client = model.client else {
          throw CancellationError()
        }
        let generation = model.workspaceGeneration
        let context = try model.activateDestination(
          resolved, workspace: client, generation: generation)
        if let row = resolved.row {
          pendingSearchEditor = (
            EditorTarget(row: row.record, context: context), generation, resolved.destination
          )
        }
        tableSearchPresented = false
        showingGraph = false
        preferredColumn = .detail
        model.error = nil
        navigationError = nil
        quickFind = nil
        if resolved.row == nil { recordNavigationSucceeded(resolved.destination) }
      }
    }
    .sheet(item: $rejectionInbox, onDismiss: finishRejectionDismissal) { inbox in
      NavigationStack {
        List {
          if let rejectionError {
            Text(rejectionError).foregroundStyle(.red).textSelection(.enabled)
          }
          RejectionInboxView(model: inbox, isBusy: openingDestination) { entry in
            reviewRejected(entry, inbox: inbox)
          }
        }
        .navigationTitle("Issues")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") { rejectionInbox = nil }
          }
        }
      }
      #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
      #endif
      .task { await inbox.refresh() }
      .onDisappear { inbox.dispose() }
    }
    .onChange(of: model.workspaceGeneration) {
      navigationRequest += 1
      openingDestination = false
      navigationError = nil
      showingGraph = false
      pendingGraphTable = nil
      preferredColumn = .detail
      online?.cancel()
      online = nil
      quickFind?.cancel()
      quickFind = nil
      pendingSearchEditor = nil
      pendingReferenceEditor = nil
      pendingDuplicateEditor = nil
      rejectionInbox?.dispose()
      rejectionInbox = nil
      pendingRejection = nil
      rejectionError = nil
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
      switch result {
      case .success(let url): Task { await model.open(url: url) }
      case .failure(let error): model.error = error.localizedDescription
      }
    }
  }

  private var canFind: Bool {
    model.client != nil && !openingDestination && editor == nil && online == nil && quickFind == nil
      && pendingSearchEditor == nil && pendingDuplicateEditor == nil
      && pendingReferenceEditor == nil && rejectionInbox == nil && pendingRejection == nil
      && !settings && !options && !savedViews && !importing
  }

  private func recordNavigationSucceeded(_ destination: NativeDestination) {
    guard let recents = model.recents else { return }
    let generation = model.workspaceGeneration
    Task {
      guard generation == model.workspaceGeneration else { return }
      await recents.navigationSucceeded(destination)
    }
  }

  private func openRecord(_ row: WorkspaceRow) {
    guard let table = model.table else { return }
    // Resolve by ID. The loaded page may have an old revision or omit fields.
    openDestination(NativeDestination(table: table, rowID: row.id), preservingQuery: true)
  }

  private func openDestination(
    _ destination: NativeDestination, preservingQuery: Bool = false,
    onOpened: (() -> Void)? = nil, onFailed: ((String) -> Void)? = nil
  ) {
    guard canFind, let workspace = model.client else { return }
    let generation = model.workspaceGeneration
    let query = model.queryKey
    navigationRequest += 1
    let request = navigationRequest
    let recent =
      preservingQuery
      ? NativeDestination(
        table: destination.table, viewID: model.appliedView?.id, rowID: destination.rowID)
      : destination
    openingDestination = true
    navigationError = nil
    let current = {
      model.client === workspace && model.workspaceGeneration == generation
        && navigationRequest == request && model.queryKey == query
        && editor == nil && quickFind == nil && online == nil
        && rejectionInbox == nil && pendingRejection == nil
        && !settings && !options && !savedViews && !importing
    }
    Task {
      defer { if navigationRequest == request { openingDestination = false } }
      do {
        let resolved = try await NativeDestinationResolver(workspace: workspace).resolve(
          destination, isCurrent: current)
        guard current() else { return }
        let context: WorkspaceEditingContext
        if preservingQuery {
          context = try model.refreshedRecordContext(
            resolved, workspace: workspace, generation: generation)
        } else {
          context = try model.activateDestination(
            resolved, workspace: workspace, generation: generation)
        }
        if !preservingQuery { tableSearchPresented = false }
        showingGraph = false
        preferredColumn = .detail
        if let row = resolved.row { editor = EditorTarget(row: row.record, context: context) }
        model.error = nil
        recordNavigationSucceeded(recent)
        onOpened?()
      } catch is CancellationError {
        // A closed or superseded workspace owns the next UI state.
      } catch {
        guard current() else { return }
        navigationError = error.localizedDescription
        model.error = error.localizedDescription
        onFailed?(error.localizedDescription)
        await model.recents?.refresh()
      }
    }
  }

  @ViewBuilder private var pendingLinkBanner: some View {
    if pendingLink.request != nil || pendingLink.error != nil {
      VStack(alignment: .leading, spacing: 6) {
        if pendingLink.request != nil {
          Text(
            model.client == nil
              ? "A link is waiting. Open the workspace it belongs to, then open the link."
              : "A link is waiting to open.")
        }
        if let error = pendingLink.error {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
            .accessibilityIdentifier("pending-link-error")
        }
        HStack {
          if pendingLink.request != nil {
            Button("Open link", action: openPendingLink).disabled(!canFind)
              .accessibilityIdentifier("open-pending-link")
          }
          Button("Dismiss") { pendingLink.dismiss() }
            .accessibilityIdentifier("dismiss-pending-link")
        }
      }
      .font(.callout).padding(.horizontal).padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
  }

  private func openPendingLink() {
    guard let request = pendingLink.requestToOpen(allowed: canFind) else { return }
    do {
      let destination = try model.linkedDestination(request.link)
      openDestination(
        destination, onOpened: { pendingLink.complete(request.id) },
        onFailed: { pendingLink.fail(request.id, message: $0) })
    } catch { pendingLink.fail(request.id, message: error.localizedDescription) }
  }

  private func copyLink(
    _ destination: NativeDestination, context: WorkspaceEditingContext?
  ) throws {
    let url = try model.linkURL(for: destination, context: context)
    CopyDraftButton.copy(url.absoluteString)
  }

  private func showRejections() {
    guard canFind else { return }
    rejectionError = nil
    rejectionInbox = model.makeRejectionInbox()
  }

  private func reviewRejected(_ entry: CoreRejectedEdit, inbox: RejectionInboxModel) {
    guard rejectionInbox === inbox, !openingDestination, editor == nil,
      pendingRejection == nil, let workspace = model.client
    else { return }
    let generation = model.workspaceGeneration
    let query = model.queryKey.map { Data($0.utf8) }
    navigationRequest += 1
    let request = navigationRequest
    openingDestination = true
    rejectionError = nil
    let current = {
      rejectionInbox === inbox && navigationRequest == request
        && model.client === workspace && model.workspaceGeneration == generation
        && model.queryKey.map({ Data($0.utf8) }) == query
        && editor == nil && quickFind == nil && online == nil
        && pendingSearchEditor == nil && pendingReferenceEditor == nil
        && !settings && !options && !savedViews && !importing
    }
    Task {
      defer { if navigationRequest == request { openingDestination = false } }
      do {
        let review = try await model.prepareRejectionReview(
          entry, workspace: workspace, generation: generation, isCurrent: current)
        guard current() else { return }
        pendingRejection = (review, request)
        rejectionInbox = nil
      } catch is CancellationError {
        // The saved draft survives a cancelled handoff; the newer context owns the UI.
      } catch {
        guard current() else { return }
        rejectionError = error.localizedDescription
      }
    }
  }

  private func finishRejectionDismissal() {
    guard let pending = pendingRejection else { return }
    pendingRejection = nil
    let current = {
      navigationRequest == pending.request && rejectionInbox == nil
        && editor == nil && quickFind == nil && online == nil
        && pendingSearchEditor == nil && pendingReferenceEditor == nil
        && !settings && !options && !savedViews && !importing
    }
    do {
      try model.activateRejectionReview(pending.review, isCurrent: current)
      editor = EditorTarget(
        row: pending.review.resolved.row?.record, context: pending.review.context,
        preparedEditor: pending.review.editor)
      tableSearchPresented = false
      showingGraph = false
      preferredColumn = .detail
      model.error = nil
      navigationError = nil
      recordNavigationSucceeded(pending.review.resolved.destination)
    } catch is CancellationError {
      model.refreshDrafts()
    } catch {
      guard current() else { return }
      model.refreshDrafts()
      model.error = error.localizedDescription
    }
  }

  private func showQuickFind() {
    guard canFind else { return }
    quickFind = model.makeCommandPalette()
  }

  private func openSearchEditor() {
    guard let pending = pendingSearchEditor else { return }
    pendingSearchEditor = nil
    guard editor == nil, pending.generation == model.workspaceGeneration,
      pending.target.context?.workspace === model.client,
      pending.target.context?.table == model.table
    else { return }
    editor = pending.target
    recordNavigationSucceeded(pending.destination)
  }

  private func finishEditorDismissal() {
    model.refreshDrafts()
    if let pending = pendingDuplicateEditor {
      pendingDuplicateEditor = nil
      // A superseded copy keeps its journal and stays available as an unsaved draft.
      guard editor == nil, pending.generation == model.workspaceGeneration,
        pending.target.context?.workspace === model.client,
        pending.target.context?.table == model.table
      else { return }
      editor = pending.target
      return
    }
    guard let pending = pendingReferenceEditor else { return }
    pendingReferenceEditor = nil
    guard editor == nil, pending.generation == model.workspaceGeneration,
      pending.source.workspace === model.client, pending.source.table == model.table
    else { return }
    do {
      tableSearchPresented = false
      let context = try model.activateSearchTable(
        pending.destination.table,
        workspace: pending.source.workspace, generation: pending.generation)
      showingGraph = false
      editor = EditorTarget(row: pending.destination.row.record, context: context)
      recordNavigationSucceeded(
        NativeDestination(
          table: pending.destination.table, viewID: model.appliedView?.id,
          rowID: pending.destination.row.id))
    } catch { model.error = error.localizedDescription }
  }

  private var welcome: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 22) {
        Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.tint)
        Text("Your workspace, locally.").font(.largeTitle.bold())
        Text(
          "Browse your catalog, write a note, and keep its Markdown source. Work locally or connect a hub to sync across devices."
        )
        .foregroundStyle(.secondary)
        Button("Connect to hub") { settings = true }.buttonStyle(.borderedProminent)
        Button("Open local workspace") { Task { await model.open() } }
          .buttonStyle(.borderedProminent).accessibilityIdentifier("open-local")
        Button("Try sample workspace") { Task { await model.open(demo: true) } }
          .accessibilityIdentifier("open-sample")
        #if os(macOS)
          Button("Open a local database…") { importing = true }
        #endif
        Text("A new local workspace includes a sample note. The sample preview is temporary.")
          .font(.caption).foregroundStyle(.secondary)
        if model.loading { ProgressView() }
        if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      }
      .disabled(model.loading)
      .padding(32).frame(maxWidth: 560, alignment: .leading)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Life UI")
    }
  }

  @ViewBuilder private var recordNotices: some View {
    #if os(macOS)
      Button(action: showRejections) {
        Label("Issues", systemImage: "exclamationmark.bubble")
      }.disabled(!canFind).accessibilityIdentifier("workspace-issues")
    #else
      if let message = model.partialTableNotice, let context = model.downloadContext,
        let table = model.table
      {
        PartialReplicaNotice(model: model, context: context, table: table, message: message)
      }
      if let reason = model.editingUnavailable {
        Text(reason).font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("editing-availability")
      }
    #endif
    if let action = model.undoAction {
      Button {
        let context = model.editingContext
        Task {
          do { try await model.undo(action, context: context) } catch {
            model.error = error.localizedDescription
          }
        }
      } label: {
        Label("Undo last saved change", systemImage: "arrow.uturn.backward")
      }.disabled(model.undoing || !canFind).accessibilityIdentifier("undo-saved-change")
    }
    ForEach(model.recoverableDrafts.filter { $0.table == model.table }) { saved in
      Button {
        guard let context = model.editingContext else { return }
        Task {
          do {
            let current = try await model.recoveryRecord(saved, context: context)
            editor = EditorTarget(row: current, context: context, recovered: saved)
            if let id = current?["id"]?.text {
              recordNavigationSucceeded(
                NativeDestination(
                  table: context.table, viewID: model.appliedView?.id, rowID: id))
            }
          } catch { model.error = error.localizedDescription }
        }
      } label: {
        VStack(alignment: .leading) {
          Label("Resume unsaved draft", systemImage: "square.and.pencil")
          if let field = saved.draft.fields.first,
            let value = saved.draft.values[field.id]?.nonempty
          {
            Text(value).lineLimit(1)
          }
          Text(saved.modifiedAt.formatted(date: .abbreviated, time: .standard)).font(.caption)
        }
      }.accessibilityIdentifier("resume-unsaved-draft")
    }
    if model.isReplica,
      model.syncResult?.rejected.isEmpty == false || !model.skippedTables.isEmpty
    {
      SyncDetails(model: model)
    }
    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
    if let purpose = model.tables.first(where: { $0["id"]?.text == model.table })?["purpose"]?
      .text.nonempty
    {
      Text(purpose).font(.callout).foregroundStyle(.secondary)
    }
  }

  private var recordList: some View {
    List {
      recordNotices
      if model.rows.isEmpty && !model.loading {
        ContentUnavailableView(
          model.trash ? "Trash is empty" : "No records", systemImage: "tray",
          description: Text(
            model.search.isEmpty && model.filters.isEmpty
              ? "Create a record to get started." : "Try a different search or filter."))
      }
      ForEach(model.rows, id: \.byteExactID) { row in
        Button {
          openRecord(row)
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            Text(row.label).foregroundStyle(.primary).font(.headline).lineLimit(2)
            if let columns = model.visibleRecordColumns {
              ForEach(columns, id: \.self) { column in
                LabeledContent(
                  model.properties.first { $0["col"]?.text == column }?["label"]?.text ?? column
                ) {
                  Text(row.record[column]?.text ?? "").lineLimit(2)
                }.font(.caption).foregroundStyle(.secondary)
              }
            } else if let date = row.record["updated_at"]?.text {
              Text(date).font(.caption).foregroundStyle(.secondary)
            }
          }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(
            .rect)
        }.buttonStyle(.plain)
      }
      if model.canLoadMore { Button("Load more") { Task { await model.reload(more: true) } } }
      if model.loading { ProgressView().frame(maxWidth: .infinity) }
    }
    #if os(iOS)
      .contentMargins(.top, 0, for: .scrollContent)
    #endif
  }

  @ViewBuilder private var recordContent: some View {
    #if os(macOS)
      if #available(macOS 14.4, *) {
        VStack(alignment: .leading, spacing: 0) {
          // Size to the notices, scrolling only beyond 180 points.
          ScrollView { macRecordNotices }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
          MacRecordTable(
            rows: model.rows,
            columns: NativeGridColumn.columns(
              properties: model.properties, selected: model.visibleRecordColumns,
              widths: model.appliedView?.definition?.widths ?? [:]),
            onOpen: openRecord
          )
          .id(model.queryKey + [String(model.workspaceGeneration)])
          .overlay {
            if model.rows.isEmpty && !model.loading {
              ContentUnavailableView(
                model.trash ? "Trash is empty" : "No records", systemImage: "tray",
                description: Text("Create a record or try a different search or filter."))
            }
          }
          HStack {
            Text(
              model.rows.count == 1 ? "1 record loaded" : "\(model.rows.count) records loaded"
            ).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            if model.canLoadMore {
              Button("Load more") { Task { await model.reload(more: true) } }
                .disabled(model.loading)
            }
          }.padding(12)
        }
      } else {
        recordList
      }
    #else
      recordList
    #endif
  }

  private var macRecordNotices: some View {
    VStack(alignment: .leading, spacing: 10) { recordNotices }
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
  }

  #if os(iOS)
    private var statusButton: some View {
      Button {
        showingStatus = true
      } label: {
        Label(
          model.syncing ? "Syncing" : "Workspace status",
          systemImage: model.syncing ? "arrow.triangle.2.circlepath" : "info.circle"
        )
        .labelStyle(.iconOnly)
      }.accessibilityIdentifier("workspace-status")
    }

    private var workspaceMenu: some View {
      Menu {
        if model.isReplica {
          Button {
            Task { await model.synchronize() }
          } label: {
            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
          }.disabled(model.syncing).accessibilityIdentifier("sync-now")
          Button {
            guard canFind else { return }
            tableSearchPresented = false
            online = model.makeOnlineBrowser()
          } label: {
            Label("Browse online", systemImage: "cloud")
          }
          .disabled(!canFind || model.table == nil).accessibilityIdentifier("browse-online")
        }
        Button {
          settings = true
        } label: {
          Label("Hub connection", systemImage: "gearshape")
        }
        Button(action: showRejections) { Label("Issues", systemImage: "exclamationmark.bubble") }
          .disabled(!canFind).accessibilityIdentifier("workspace-issues")
        Divider()
        Button {
          guard let table = model.table else { return }
          do {
            try copyLink(
              NativeDestination(table: table, viewID: model.appliedView?.id),
              context: model.editingContext)
          } catch { model.error = error.localizedDescription }
        } label: {
          Label("Copy link", systemImage: "link")
        }
        .disabled(!canFind || !model.canCopyLink || model.table == nil).accessibilityIdentifier(
          "copy-workspace-link")
        Button {
          model.trash.toggle()
        } label: {
          Label(
            model.trash ? "Show active records" : "Show trash",
            systemImage: model.trash ? "tray" : "trash")
        }.accessibilityIdentifier("toggle-trash")
        Divider()
        Button {
          Task { await model.close() }
        } label: {
          Label("Close workspace", systemImage: "xmark.circle")
        }
      } label: {
        Label("Workspace actions", systemImage: "ellipsis")
          .labelStyle(.iconOnly)
      }
      .accessibilityIdentifier("workspace-menu")
    }
  #endif

  private var records: some View {
    recordContent
      .safeAreaInset(edge: .top, spacing: 0) {
        #if os(macOS)
          VStack(alignment: .leading, spacing: 8) {
            if model.isReplica { SyncSummary(model: model) }
            if let message = model.partialTableNotice, let context = model.downloadContext,
              let table = model.table
            {
              PartialReplicaNotice(model: model, context: context, table: table, message: message)
            }
            if model.isReplica, model.table != nil {
              Button {
                guard canFind else { return }
                tableSearchPresented = false
                online = model.makeOnlineBrowser()
              } label: {
                Label("Browse online", systemImage: "cloud")
              }.disabled(!canFind).accessibilityIdentifier("browse-online")
            }
            if let reason = model.editingUnavailable {
              Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .accessibilityIdentifier("editing-availability")
            }
            HStack {
              Button {
                savedViews = true
              } label: {
                Label("Views", systemImage: "rectangle.stack")
              }.disabled(editor != nil || model.client == nil)
                .accessibilityIdentifier("saved-views")
              Button {
                options = true
              } label: {
                HStack {
                  Label("Sort and filter", systemImage: "line.3.horizontal.decrease")
                  if !model.sortColumn.isEmpty {
                    Image(systemName: model.sortAscending ? "arrow.up" : "arrow.down")
                  }
                  if !model.filters.isEmpty { Text("\(model.filters.count) active") }
                }
              }.accessibilityIdentifier("view-options")
              Spacer()
              Button {
                guard let table = model.table else { return }
                do {
                  try copyLink(
                    NativeDestination(table: table, viewID: model.appliedView?.id),
                    context: model.editingContext)
                } catch { model.error = error.localizedDescription }
              } label: {
                Label("Copy link", systemImage: "link").labelStyle(.iconOnly)
              }.disabled(!canFind || !model.canCopyLink || model.table == nil)
                .accessibilityIdentifier("copy-workspace-link")
              Button(action: showQuickFind) { Label("Find", systemImage: "magnifyingglass") }
                .disabled(!canFind).accessibilityIdentifier("quick-find")
            }
            if let applied = model.appliedView {
              Text(applied.name + (model.viewModified ? " · Modified" : ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal).padding(.vertical, 8)
          .background(.regularMaterial)
        #else
          if let applied = model.appliedView {
            Text(applied.name + (model.viewModified ? " · Modified" : ""))
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        #endif
      }
      .navigationTitle(model.table ?? "Workspace")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .searchable(
        text: $model.search, isPresented: $tableSearchPresented, prompt: "Search this table"
      )
      .refreshable { await model.reload() }
      .toolbar {
        #if os(iOS)
          ToolbarItemGroup(placement: .primaryAction) {
            statusButton
            workspaceMenu
            if model.canWrite && !model.trash {
              Button {
                editor = EditorTarget(row: nil, context: model.editingContext)
              } label: {
                Label("New record", systemImage: "plus").labelStyle(.iconOnly).frame(
                  minWidth: 44, minHeight: 44)
              }.accessibilityIdentifier("new-record")
            }
          }
          ToolbarItemGroup(placement: .bottomBar) {
            Button {
              savedViews = true
            } label: {
              Label("Views", systemImage: "rectangle.stack").labelStyle(.iconOnly).frame(
                minWidth: 44, minHeight: 44)
            }.disabled(editor != nil || model.client == nil).accessibilityIdentifier("saved-views")
            Spacer()
            Button {
              options = true
            } label: {
              Label(
                "Sort and filter",
                systemImage: model.filters.isEmpty
                  ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill"
              )
              .labelStyle(.iconOnly)
            }.accessibilityIdentifier("view-options")
              .accessibilityValue("\(model.filters.count) active filters")
            Spacer()
            Button(action: showQuickFind) {
              Label("Find", systemImage: "magnifyingglass").labelStyle(.iconOnly).frame(
                minWidth: 44, minHeight: 44)
            }
            .disabled(!canFind).accessibilityIdentifier("quick-find")
            Spacer()
            Button {
              showingGraph = true
            } label: {
              Label("Schema graph", systemImage: "point.3.connected.trianglepath.dotted")
                .labelStyle(.iconOnly)
            }.disabled(!canFind).accessibilityIdentifier("schema-graph")
          }
        #else
          ToolbarItemGroup(placement: .primaryAction) {
            if model.isReplica {
              Button {
                Task { await model.synchronize() }
              } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
              }
              .disabled(model.syncing).accessibilityIdentifier("sync-now")
            }
            Button {
              settings = true
            } label: {
              Label("Hub connection", systemImage: "gearshape")
            }
            Button {
              model.trash.toggle()
            } label: {
              Label(
                model.trash ? "Show active records" : "Show trash",
                systemImage: model.trash ? "tray" : "trash")
            }.accessibilityIdentifier("toggle-trash")
            if model.canWrite && !model.trash {
              Button {
                editor = EditorTarget(row: nil, context: model.editingContext)
              } label: {
                Label("New record", systemImage: "plus")
              }
              .accessibilityIdentifier("new-record")
            }
          }
        #endif
      }
      .disabled(openingDestination)
  }
}

private struct EditorTarget: Identifiable {
  let id = UUID()
  let row: WorkspaceRecord?
  let context: WorkspaceEditingContext?
  var recovered: StoredEditorDraft? = nil
  var preparedEditor: RecordEditorModel? = nil
}

private struct RecordEditor: View {
  let model: WorkspaceModel
  let context: WorkspaceEditingContext?
  let onSaved: () -> Void
  let recordFields: [CatalogField]
  let linkWaiting: Bool
  let onDuplicate: (RecordEditorModel) -> Void
  let isCurrent: @MainActor () -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var editor: RecordEditorModel
  @State private var referenceNavigation: ReferenceNavigationModel?
  @State private var confirmReference = false
  @State private var saving = false
  @State private var discard = false
  @State private var actionFailure: String?
  @State private var duplicating = false
  @State private var preparedCopy: RecordEditorModel?
  @State private var confirmDuplicate = false
  @FocusState private var focusedField: String?

  init(
    model: WorkspaceModel, original: WorkspaceRecord?, context: WorkspaceEditingContext?,
    recovered: StoredEditorDraft?, preparedEditor: RecordEditorModel? = nil,
    linkWaiting: Bool = false, isCurrent: @escaping @MainActor () -> Bool,
    onReference: @escaping (ReferenceDestination) -> Void,
    onDuplicate: @escaping (RecordEditorModel) -> Void = { _ in },
    onSaved: @escaping () -> Void
  ) {
    self.model = model
    self.context = context
    self.onSaved = onSaved
    self.isCurrent = isCurrent
    self.linkWaiting = linkWaiting
    self.onDuplicate = onDuplicate
    recordFields = model.properties.map(CatalogField.init)
    let source =
      preparedEditor
      ?? RecordEditorModel(
        properties: model.properties,
        original: original, table: context?.table ?? "", store: context?.draftStore,
        recovered: recovered
      ) { patch, baseline in
        try await model.save(patch, original: baseline, context: context)
      }
    _editor = State(initialValue: source)
    _referenceNavigation = State(
      initialValue: context.map {
        model.makeReferenceNavigation(
          editor: source, context: $0, isCurrent: isCurrent,
          onOpen: onReference)
      })
  }

  var body: some View {
    NavigationStack {
      Form {
        if linkWaiting {
          Section {
            Text("A link is waiting. Save or close this record to open it.")
              .foregroundStyle(.secondary).accessibilityIdentifier("link-waiting-editor")
          }
        }
        if let action = model.undoAction {
          Section {
            Button {
              focusedField = nil
              Task {
                do {
                  try await editor.performUndo(action, isCurrent: editorIsCurrent) {
                    try await model.undo(action, context: context)
                  }
                  actionFailure = nil
                } catch { actionFailure = error.localizedDescription }
              }
            } label: {
              Label("Undo last saved change", systemImage: "arrow.uturn.backward")
            }
            .disabled(
              editor.saving || editor.recovery != nil || editor.needsReview || model.undoing
            )
            .accessibilityIdentifier("undo-editor")
          }
        }
        if editor.autosavePaused || editor.isTrashed {
          Section {
            Text(editor.status).foregroundStyle(.secondary)
            if editor.isTrashed && model.canWrite, let id = editor.draft.original?["id"] {
              Button("Restore record") { save(["id": id, "deleted_at": .null]) }
                .disabled(editor.recovery != nil || editor.needsReview)
                .accessibilityIdentifier("trash-record")
            }
          }
        }
        if editor.recovery != nil {
          Section("Unsaved draft") {
            Text("Continue your unsaved changes or start with the saved record.")
            ForEach(editor.recoveryChoices) { saved in
              if editor.recoveryChoices.count > 1 {
                Text(saved.modifiedAt.formatted(date: .abbreviated, time: .standard)).font(.caption)
                if let first = saved.draft.fields.first,
                  let value = saved.draft.values[first.id]
                {
                  Text(value).lineLimit(2)
                }
              }
              Button("Resume draft") { editor.resumeDraft(saved) }
              Button("Discard draft", role: .destructive) {
                do { try editor.discardRecovery(saved) } catch {
                  actionFailure = error.localizedDescription
                }
              }
            }
            Button(editor.isNew ? "Start new record" : "Open saved record") {
              editor.openSavedRecord()
            }
            Text("Your unsaved drafts will remain available until you discard them.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        if editor.needsReview {
          Section("Review recovered changes") {
            Text(
              "Copy the values you want to keep, then keep the draft and close. Open the saved record to review and paste your changes."
            )
          }
        }
        if !model.rules.isEmpty {
          Section("Catalog rules") {
            ForEach(model.rules, id: \.["id"]) { rule in
              Text(rule["text"]?.text ?? rule["id"]?.text ?? "")
            }
          }
        }
        if let reason = model.editingUnavailable {
          Section { Text(reason).foregroundStyle(.secondary) }
        }
        if model.canWrite && !editor.isTrashed {
          ForEach(editor.draft.fields) { field in
            Section {
              FieldInput(
                field: field, workspace: context?.workspace, focus: $focusedField,
                editor: editor, onOpenReference: openReference,
                undoAction: model.undoAction, undo: { try await model.undo($0, context: context) },
                isCurrent: editorIsCurrent,
                referenceAvailability: referenceAvailability(field),
                value: Binding(
                  get: { editor.draft.values[field.id] ?? "" },
                  set: { editor.setValue($0, for: field.id) }))
              if editor.failure != nil {
                CopyDraftButton(
                  title: "Copy \(field.label)", value: editor.draft.values[field.id] ?? "")
              }
              ForEach(editor.violations.filter { $0.col == field.id }, id: \.rule) { violation in
                Text(violation.message).foregroundStyle(.red).font(.callout)
              }
            } header: {
              Text(field.label)
            } footer: {
              VStack(alignment: .leading, spacing: 4) {
                if !field.help.isEmpty { Text(field.help) }
                if editor.isNew, let preview = field.defaultPreview {
                  if editor.draft.usesDefault(field.id) {
                    // Choice pickers already name the default as their empty choice.
                    if !["select", "multi_select"].contains(field.type) {
                      Text("Default: \(preview)")
                    }
                    Button("Leave empty") { editor.setValue("", for: field.id, explicit: true) }
                      .accessibilityIdentifier("leave-empty-\(field.id)")
                  } else if (editor.draft.values[field.id] ?? "").isEmpty {
                    Text("Saved empty instead of the default.")
                      .accessibilityIdentifier("empty-instead-of-default-\(field.id)")
                  }
                }
              }
            }
            .disabled(editor.recovery != nil)
          }
        }
        if editor.isTrashed && editor.dirty {
          Section("Kept draft") {
            Text("Restore the record first, then review and save these changes.")
            ForEach(editor.draft.fields.filter { editor.draft.patch[$0.id] != nil }) { field in
              LabeledContent(field.label) {
                Text(editor.draft.values[field.id] ?? "").textSelection(.enabled)
              }
              CopyDraftButton(
                title: "Copy \(field.label)", value: editor.draft.values[field.id] ?? "")
            }
          }
        }
        if !editor.draft.unknownValues.isEmpty {
          Section("Unavailable fields") {
            Text("These draft values have been kept and will not be included when saving.")
            ForEach(editor.draft.unknownValues.keys.sorted(), id: \.self) { key in
              LabeledContent(key) {
                Text(editor.draft.unknownValues[key] ?? "").textSelection(.enabled)
              }
              CopyDraftButton(title: "Copy \(key)", value: editor.draft.unknownValues[key] ?? "")
            }
          }
        }
        if let original = editor.draft.original {
          if let identity = model.incomingReferencesIdentity(context: context, row: original) {
            IncomingReferencesView(
              makeModel: {
                model.makeIncomingReferences(
                  context: context, row: original, isCurrent: editorIsCurrent)
              },
              canOpen: !editor.saving, onOpenRecord: openReference
            )
            .id(identity)
          }
          Section("Record") {
            ForEach(original.keys.sorted(), id: \.self) { key in
              if !editor.draft.fields.contains(where: { $0.id == key }) || !model.canWrite
                || editor.isTrashed
              {
                if let field = recordFields.first(where: { $0.id == key }),
                  ["ref", "multi_ref"].contains(field.type), let workspace = context?.workspace,
                  field.property["ref_table"]?.text.nonempty != nil
                {
                  VStack(alignment: .leading, spacing: 8) {
                    Text(field.label)
                    ReferenceField(
                      field: field, value: .constant(original[key]?.text ?? ""),
                      workspace: workspace, canEdit: false,
                      canOpen: !editor.saving,
                      availability: referenceAvailability(field), onOpenRecord: openReference)
                  }
                } else {
                  LabeledContent(key) { Text(original[key]?.text ?? "").textSelection(.enabled) }
                }
              }
            }
          }
          if model.canWrite && !editor.isTrashed {
            Section {
              Button("Duplicate record", action: duplicate)
                .disabled(
                  duplicating || editor.saving || editor.recovery != nil || editor.needsReview
                )
                .accessibilityIdentifier("duplicate-record")
              Button(
                "Move to trash", role: .destructive
              ) {
                save(["id": original["id"]!, "deleted_at": .bool(true)])
              }.accessibilityIdentifier("trash-record").disabled(editor.recovery != nil)
            }
          }
        }
        if let failure = actionFailure ?? editor.failure {
          Section {
            Text(failure).foregroundStyle(.red).textSelection(.enabled)
            if !editor.isNew && editor.recovery == nil && !editor.needsReview
              && !editor.autosavePaused && !editor.isTrashed
            {
              Button("Retry Markdown save") {
                Task {
                  do {
                    try await editor.flushMarkdown(retry: true)
                    actionFailure = nil
                  } catch { actionFailure = error.localizedDescription }
                }
              }.disabled(editor.saving)
            }
          }
        } else if editor.dirty && !editor.isNew && editor.markdownSaved {
          Section { Text("Markdown saved. Other changes are unsaved.").foregroundStyle(.secondary) }
        }
      }
      .formStyle(.grouped)
      .accessibilityIdentifier("record-form")
      .navigationTitle(editor.isNew ? "New record" : "Record")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if editor.failure != nil || editor.autosavePaused {
            Button("Keep draft and close") {
              do {
                try editor.keepDraft()
                dismiss()
              } catch { actionFailure = error.localizedDescription }
            }.accessibilityIdentifier("keep-record-draft")
          } else {
            Button("Cancel") {
              if editor.dirty { discard = true } else { dismiss() }
            }.disabled(editor.saving)
          }
        }
        if let id = editor.draft.original?["id"]?.text, let context {
          ToolbarItem(placement: .primaryAction) {
            Button {
              do {
                let url = try model.linkURL(
                  for: NativeDestination(table: context.table, rowID: id), context: context)
                CopyDraftButton.copy(url.absoluteString)
                actionFailure = nil
              } catch { actionFailure = error.localizedDescription }
            } label: {
              Label("Copy link", systemImage: "link")
            }.disabled(!model.canCopyLink).accessibilityIdentifier("copy-record-link")
          }
        }
        if model.canWrite && !editor.isTrashed {
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }.disabled(
              saving || editor.recovery != nil || editor.needsReview
            )
            .accessibilityIdentifier("save-record")
          }
        }
      }
      .disabled(saving || editor.undoing || referenceNavigation?.loading == true)
      .interactiveDismissDisabled(saving || editor.saving || editor.dirty || editor.recovery != nil)
      .confirmationDialog(
        "Discard unsaved changes and duplicate?", isPresented: $confirmDuplicate,
        titleVisibility: .visible
      ) {
        Button("Discard changes and duplicate", role: .destructive) {
          guard let copy = preparedCopy else { return }
          preparedCopy = nil
          do {
            try editor.discardDraft()
            onDuplicate(copy)
          } catch {
            discardPreparedCopy(copy)
            actionFailure = error.localizedDescription
          }
        }
      }
      .onChange(of: confirmDuplicate) {
        // Keeping the source draft also removes the unused copy's journal.
        if !confirmDuplicate, let copy = preparedCopy {
          preparedCopy = nil
          discardPreparedCopy(copy)
        }
      }
      .confirmationDialog(
        "Discard unsaved changes?", isPresented: $discard, titleVisibility: .visible
      ) {
        Button("Discard changes", role: .destructive) { discardSavedDraft(close: true) }
        Button("Keep editing", role: .cancel) {}
      }
      .alert(
        referenceNavigation?.error == nil
          ? "Discard unsaved changes and open the related record?" : "Cannot open record",
        isPresented: $confirmReference
      ) {
        if referenceNavigation?.error != nil {
          Button("OK") { referenceNavigation?.cancel() }
        } else {
          Button("Discard changes and open", role: .destructive) {
            Task { _ = await referenceNavigation?.discardAndOpen() }
          }
          Button("Keep editing", role: .cancel) { referenceNavigation?.cancel() }
        }
      } message: {
        if let error = referenceNavigation?.error { Text(error) }
      }
      .onChange(of: referenceNavigation?.confirmation) {
        confirmReference = referenceNavigation?.confirmation != nil
      }
      .onChange(of: referenceNavigation?.error) {
        if referenceNavigation?.error != nil { confirmReference = true }
      }
      .onDisappear { referenceNavigation?.cancel() }
      .onChange(of: model.workspaceGeneration) { referenceNavigation?.cancel() }
      .onChange(of: model.table) { referenceNavigation?.cancel() }
    }
    #if os(macOS)
      .frame(minWidth: 520, minHeight: 560)
    #endif
  }

  private func editorIsCurrent() -> Bool {
    isCurrent() && context?.workspace === model.client && context?.table == model.table
  }

  private func referenceAvailability(_ field: CatalogField) -> String? {
    guard let table = field.property["ref_table"]?.text else { return nil }
    if !model.tables.contains(where: { $0["id"]?.text == table }) {
      return "The related table is not available on this device."
    }
    return model.skippedTables.contains(table)
      ? "Some records in this table were skipped during sync. Stored records can still be opened."
      : nil
  }

  private func openReference(table: String, id: String) {
    focusedField = nil
    Task {
      _ = await referenceNavigation?.open(table: table, id: id)
    }
  }

  private func duplicate() {
    guard let context, let id = editor.draft.original?["id"]?.text, !duplicating else { return }
    focusedField = nil
    duplicating = true
    actionFailure = nil
    Task {
      defer { duplicating = false }
      do {
        // Copy a fresh full row, never the possibly stale or projected editor baseline.
        let resolved = try await NativeDestinationResolver(workspace: context.workspace).resolve(
          NativeDestination(table: context.table, rowID: id), isCurrent: editorIsCurrent)
        guard let row = resolved.row?.record, row["deleted_at"]?.text.nonempty == nil else {
          throw WorkspaceError(
            message: "This record is no longer available locally.", violations: [])
        }
        guard model.canWrite else {
          throw WorkspaceError(
            message: model.editingUnavailable ?? "This table is read-only.", violations: [])
        }
        let copy = RecordEditorModel(
          properties: model.properties, original: nil, table: context.table,
          store: context.draftStore, recovered: nil
        ) { patch, baseline in
          try await model.save(patch, original: baseline, context: context)
        }
        try copy.installDuplicateDraft(from: row, isCurrent: editorIsCurrent)
        guard editorIsCurrent() else {
          discardPreparedCopy(copy)
          return
        }
        if editor.dirty {
          preparedCopy = copy
          confirmDuplicate = true
        } else {
          onDuplicate(copy)
        }
      } catch is CancellationError {
      } catch { actionFailure = error.localizedDescription }
    }
  }

  private func discardPreparedCopy(_ copy: RecordEditorModel) {
    do { try copy.discardDraft() } catch { actionFailure = error.localizedDescription }
  }

  private func discardSavedDraft(close: Bool) {
    do {
      try editor.discardDraft()
      if close { dismiss() }
    } catch { actionFailure = error.localizedDescription }
  }

  private func save(_ patch: WorkspaceRecord? = nil) {
    saving = true
    actionFailure = nil
    Task {
      do {
        try await editor.saveAll(patch)
        if editor.dirty {
          actionFailure =
            "The saved fields are up to date. Your remaining draft values have been kept."
        } else {
          onSaved()
        }
      } catch { actionFailure = error.localizedDescription }
      saving = false
    }
  }
}

private struct FieldInput: View {
  let field: CatalogField
  let workspace: NativeWorkspace?
  let focus: FocusState<String?>.Binding
  let editor: RecordEditorModel
  let onOpenReference: (String, String) -> Void
  let undoAction: CoreUndoAction?
  let undo: (CoreUndoAction) async throws -> WorkspaceRecord
  let isCurrent: @MainActor () -> Bool
  let referenceAvailability: String?
  @Binding var value: String

  var body: some View {
    Group {
      if ["ref", "multi_ref"].contains(field.type) {
        if let workspace, field.property["ref_table"]?.text.nonempty != nil {
          ReferenceField(
            field: field, value: $value, workspace: workspace, onOpen: { focus.wrappedValue = nil },
            canOpen: !editor.saving, availability: referenceAvailability,
            onOpenRecord: onOpenReference)
        } else {
          Text("Reference choices are unavailable. The original value has been preserved.")
            .foregroundStyle(.secondary)
        }
      } else if field.type == "markdown" {
        NavigationLink {
          MarkdownEditorScreen(
            value: $value, label: field.label, editor: editor,
            undoAction: undoAction, undo: undo, isCurrent: isCurrent
          )
          .onAppear { focus.wrappedValue = nil }
        } label: {
          VStack(alignment: .leading, spacing: 6) {
            Text("Edit Markdown")
            if !value.isEmpty {
              Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
          }
        }.accessibilityIdentifier("field-\(field.id)")
      } else if ["select", "multi_select"].contains(field.type) {
        NativeChoiceField(
          field: field, isNew: editor.isNew, value: $value, workspace: workspace,
          focus: focus, isCurrent: isCurrent)
      } else if let kind = NativeDateKind(rawValue: field.type) {
        NativeDateField(field: field, kind: kind, focus: focus, value: $value)
      } else if ["url", "email", "phone"].contains(field.type) {
        NativeLinkField(field: field, focus: focus, value: $value)
      } else if field.type == "json" {
        VStack(alignment: .leading, spacing: 8) {
          Text("JSON source").font(.caption)
            .foregroundStyle(.secondary)
          TextEditor(text: $value).font(.system(.body, design: .monospaced)).frame(minHeight: 180)
            .focused(focus, equals: field.id)
            .accessibilityLabel(field.label).accessibilityIdentifier("field-\(field.id)")
        }
      } else if field.type == "bool" {
        Picker(field.label, selection: $value) {
          Text("Not set").tag("")
          Text("True").tag("true")
          Text("False").tag("false")
        }.accessibilityIdentifier("field-\(field.id)")
      } else {
        TextField(field.label, text: $value, axis: .vertical)
          .focused(focus, equals: field.id)
          .accessibilityIdentifier("field-\(field.id)")
          .autocorrectionDisabled(field.type != "text")
      }
    }
  }
}

#Preview { WorkspaceView(demo: true) }
