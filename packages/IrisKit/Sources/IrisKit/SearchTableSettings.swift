import SwiftUI

extension WorkspaceModel {
  /// Stores this device's choice for one table (core `setSearchTable`) and runs the index
  /// loop, which backfills a table that joined the index or removes one that left it.
  func setSearchTable(_ table: CoreSearchTable, indexed: Bool, on client: NativeWorkspace)
    async throws -> CoreSearchTableList
  {
    let list = try await client.setSearchTable(
      CoreSetSearchTableArgs(
        table: table.table, indexed: SearchTableText.choice(table, indexed: indexed)))
    if self.client === client { scheduleSearchIndex() }
    return list
  }
}

enum SearchTableText {
  /// One line under a table's switch: what indexing it costs and why its default is off.
  static func detail(_ table: CoreSearchTable, sizeLimit: Int) -> String {
    var parts = ["\(table.rows.formatted()) \(table.rows == 1 ? "record" : "records")"]
    if table.textBytes > 0 {
      let size = ByteCountFormatter()
      size.countStyle = .file
      parts.append("about \(size.string(fromByteCount: Int64(table.textBytes))) of text")
    }
    switch table.defaultExclusion {
    case .provenance: parts.append("Off by default: provenance links")
    case .size: parts.append("Off by default: over \(sizeLimit.formatted()) records")
    case nil: break
    }
    return parts.joined(separator: " · ")
  }

  /// Matching the default clears the choice, so the table follows the default again.
  static func choice(_ table: CoreSearchTable, indexed: Bool) -> Bool? {
    indexed == (table.defaultExclusion == nil) ? nil : indexed
  }
}

/// Which tables Quick Find searches on this device, beside the Spotlight choices.
struct SearchTablesSection: View {
  let model: WorkspaceModel
  @State private var list: CoreSearchTableList?
  @State private var busy = false
  @State private var failure: String?

  var body: some View {
    Section {
      if let list {
        if list.tables.isEmpty {
          Text("No table has text to search.").foregroundStyle(.secondary)
        }
        ForEach(list.tables, id: \.table) { table in
          Toggle(isOn: Binding(get: { table.indexed }, set: { choose(table, indexed: $0) })) {
            VStack(alignment: .leading, spacing: 2) {
              Text(table.table)
              Text(SearchTableText.detail(table, sizeLimit: list.sizeLimit))
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("search-table-" + table.table)
        }
      } else if failure == nil {
        SkeletonRows(count: 3, label: "Reading tables")
      }
      if let failure {
        Text(failure).foregroundStyle(.red).accessibilityIdentifier("search-tables-error")
      }
    } header: {
      Text("Search")
    } footer: {
      Text(
        "Tables Quick Find searches on this device. Turning one on indexes its text in the background; turning one off removes it from results."
      )
    }
    .disabled(busy)
    .task(id: model.workspaceGeneration) { await load() }
  }

  private func load() async {
    guard let client = model.client else { return }
    do {
      let result = try await client.searchTables()
      guard model.client === client else { return }
      list = result
      failure = nil
    } catch {
      if model.client === client { failure = error.localizedDescription }
    }
  }

  private func choose(_ table: CoreSearchTable, indexed: Bool) {
    guard let client = model.client, !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        let result = try await model.setSearchTable(table, indexed: indexed, on: client)
        guard model.client === client else { return }
        list = result
        failure = nil
      } catch {
        if model.client === client { failure = error.localizedDescription }
      }
    }
  }
}

#if os(macOS)
  /// The Mac has no Widgets sheet; its search choices sit in Settings beside Backup.
  struct SearchTablesView: View {
    let model: WorkspaceModel

    var body: some View {
      Form { SearchTablesSection(model: model) }
        .formStyle(.grouped)
        .navigationTitle("Search index")
    }
  }
#endif
