#if os(iOS)
  import CoreSpotlight
  import LifeExtensionSupport
  import SwiftUI

  /// The configured daily section at the top of the sidebar, above every table and pin.
  /// It reads the Today widget's own protected publication, so both show the same day.
  struct DailySection: View {
    let model: WorkspaceModel
    let open: (NativeDestination) -> Void
    @State private var presentation: WidgetPresentation?
    @State private var now = Date()

    var body: some View {
      if let source = model.integrations?.dailySource, let widgets = model.widgets {
        Section {
          if let presentation {
            ForEach(presentation.rows) { row in
              Button(row.title) { open(NativeDestination(table: source.table, rowID: row.recordID)) }
                .accessibilityIdentifier("daily-row")
            }
            if let empty = presentation.emptyLabel {
              Text(empty).foregroundStyle(.secondary)
            }
            if !presentation.notice.isEmpty {
              Text(presentation.notice).font(.caption).foregroundStyle(.secondary)
            }
          } else {
            Text("Enable this view in Widgets and Search to show it here.")
              .font(.caption).foregroundStyle(.secondary)
          }
        } header: {
          Button {
            open(NativeDestination(table: source.table, viewID: source.viewID))
          } label: {
            Label(presentation?.title ?? "Today", systemImage: "calendar")
          }
          .accessibilityIdentifier("daily-section")
        }
        .task(id: "\(source.id)|\(widgets.publicationRevision)") {
          // Rebind at the configured day boundary even while the app stays open.
          while !Task.isCancelled {
            now = Date()
            let read = widgets.presentation(source, now: now)
            presentation = read?.0
            let wake = read?.nextBoundary.map { max($0.timeIntervalSinceNow, 1) } ?? 300
            do { try await Task.sleep(for: .seconds(min(wake, 300))) } catch { return }
          }
        }
      }
    }
  }

  /// Spotlight results and foreground intents arrive as ordinary pending links.
  struct NativeIntegrationHandlers: ViewModifier {
    let model: WorkspaceModel
    let receive: (URL) -> Void
    private var inbox: NativeIntentInbox { .shared }

    func body(content: Content) -> some View {
      content
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
          guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            let url = URL(string: id)
          else { return }
          receive(url)
        }
        .onChange(of: inbox.openTodayRequests) { openToday() }
        .onChange(of: inbox.link?.revision) {
          if let url = inbox.link?.url { receive(url) }
        }
        .task(id: model.integrations.map { ObjectIdentifier($0) }) {
          inbox.lookup = model.integrations.map { settings in { try await settings.lookUp($0) } }
        }
    }

    private func openToday() {
      guard let source = model.integrations?.dailySource else {
        model.error = "Choose a daily view in Widgets and Search settings first."
        return
      }
      do {
        receive(
          try NativeDeepLink(
            destination: NativeDestination(table: source.table, viewID: source.viewID),
            workspace: model.linkBinding
          ).url)
      } catch { model.error = error.localizedDescription }
    }
  }

  /// Spotlight, Shortcuts lookup and daily-section choices in the Widgets sheet.
  struct IntegrationSettingsSections: View {
    let model: WorkspaceModel
    let widgets: NativeWidgetSettings
    let settings: NativeIntegrationSettings

    private var tables: [String] {
      model.tables.filter { $0["readOnly"] != .bool(true) }.compactMap { $0["id"]?.text }
    }

    var body: some View {
      Section {
        ForEach(tables, id: \.self) { table in
          Toggle(
            table,
            isOn: Binding(
              get: { settings.spotlightTables.contains(table) },
              set: { enabled in
                let next =
                  enabled
                  ? settings.spotlightTables + [table] : settings.spotlightTables.filter { $0 != table }
                Task { await settings.setSpotlightTables(next) }
              })
          ).accessibilityIdentifier("spotlight-" + table)
        }
      } header: {
        Text("Spotlight")
      } footer: {
        Text("Enabled tables offer record titles to Spotlight on this device. Opening a result goes through Life UI.")
      }
      .disabled(settings.busy)
      Section {
        Picker(
          "Lookup table",
          selection: Binding(
            get: { settings.lookupTable ?? "" },
            set: { settings.setLookupTable($0.isEmpty ? nil : $0) })
        ) {
          Text("None").tag("")
          ForEach(tables, id: \.self) { Text($0).tag($0) }
        }.accessibilityIdentifier("lookup-table")
        Picker(
          "Daily section",
          selection: Binding(
            get: { settings.dailySource?.id ?? "" },
            set: { id in settings.setDailySource(widgets.selections.first { $0.id == id }) })
        ) {
          Text("None").tag("")
          ForEach(widgets.selections.filter { $0.viewID != nil }) {
            Text(widgets.publishedTitle($0) ?? $0.table).tag($0.id)
          }
        }.accessibilityIdentifier("daily-source")
      } header: {
        Text("Shortcuts")
      } footer: {
        Text("Look Up searches titles in the lookup table. Open Today and the daily section above your tables use an enabled saved view.")
      }
      if let error = settings.error {
        Section { Text(error).foregroundStyle(.red) }
      }
    }
  }
#endif
