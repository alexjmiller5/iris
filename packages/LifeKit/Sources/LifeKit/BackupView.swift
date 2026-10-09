import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#endif

/// One row of the restore preview: what replacing the replica does to a table.
struct RestoreRow: Identifiable, Equatable {
  enum Change: String { case added = "Added", removed = "Removed", replaced = "Replaced", same = "Unchanged" }
  let table: String
  let backup: CoreBackupTableSummary?
  let current: CoreBackupTableSummary?
  var id: String { table }
  var change: Change {
    guard let backup else { return .removed }
    guard let current else { return .added }
    return backup == current ? .same : .replaced
  }

  static func rows(_ preview: CoreRestorePreview) -> [RestoreRow] {
    let names = Set(preview.backup.tables.map(\.table) + preview.current.tables.map(\.table))
    return names.sorted().map { name in
      RestoreRow(
        table: name, backup: preview.backup.tables.first { $0.table == name },
        current: preview.current.tables.first { $0.table == name })
    }
  }
}

struct RecoveryCopy: Identifiable, Equatable {
  let url: URL
  let modified: Date
  let bytes: Int
  var id: URL { url }
}

/// Backup state for one open workspace. Every file operation goes through core;
/// this host only owns files, the hub download and presentation.
@MainActor @Observable final class BackupModel {
  struct Preview: Equatable {
    let source: String
    let file: URL
    let data: CoreRestorePreview
    let rows: [RestoreRow]
  }

  let workspace: WorkspaceModel
  private(set) var busy: String?
  private(set) var progress: (phase: String, done: Int64, total: Int64)?
  private(set) var message: String?
  private(set) var failure: String?
  private(set) var hubBackups: [CoreHubBackup]?
  private(set) var hubError: String?
  private(set) var recovery: [RecoveryCopy] = []
  private(set) var preview: Preview?
  var confirmation = ""

  init(workspace: WorkspaceModel) { self.workspace = workspace }

  /// The CLI owns an explicitly opened file; the sample has no file at all.
  var sharedFile: URL? { workspace.openedExternalFile ? workspace.databaseFile : nil }
  var canCopyReplica: Bool { workspace.databaseFile != nil && sharedFile == nil }
  var canRestore: Bool { sharedFile == nil && workspace.canReplaceReplica }
  var progressText: String? {
    guard let busy else { return nil }
    guard let progress else { return busy + "…" }
    if progress.total > 0 {
      return "\(progress.phase) \(min(100, Int(progress.done * 100 / progress.total)))%"
    }
    return "\(progress.phase) · \(ByteCountFormatter.string(fromByteCount: progress.done, countStyle: .file))"
  }

  private var root: URL {
    get throws {
      let base =
        workspace.databaseFile.map {
          $0.deletingLastPathComponent().appendingPathComponent(
            "backups-" + WorkspaceModel.replicaKey(endpoint: $0.path), isDirectory: true)
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "life-ui-sample-backups", isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      return base
    }
  }
  private func folder(_ name: String) throws -> URL {
    let url = try root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private static var stamp: String {
    ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
  }

  func load() async {
    loadRecovery()
    await loadHub()
  }

  func loadRecovery() {
    guard let folder = try? folder("recovery"),
      let entries = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
    else { return }
    recovery =
      entries.filter { $0.pathExtension == "sql" }.compactMap { url in
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return RecoveryCopy(
          url: url, modified: values?.contentModificationDate ?? .distantPast,
          bytes: values?.fileSize ?? 0)
      }.sorted { $0.modified > $1.modified }
  }

  func loadHub() async {
    guard let client = workspace.client, let transport = workspace.imageTransport else {
      hubBackups = nil
      return
    }
    hubError = nil
    do { hubBackups = try await client.hubBackups(using: transport).backups } catch {
      hubError = Self.describe(error)
    }
  }

  private func run<T>(_ label: String, _ work: () async throws -> T) async -> T? {
    guard busy == nil, let client = workspace.client else { return nil }
    busy = label
    progress = nil
    message = nil
    failure = nil
    workspace.backupActivity = label
    client.onBackupProgress = { [weak self] phase, done, total in
      guard let self else { return }
      self.progress = (phase, done, total)
      self.workspace.backupActivity = self.progressText
    }
    defer {
      client.onBackupProgress = nil
      busy = nil
      progress = nil
      workspace.backupActivity = nil
    }
    do { return try await work() } catch {
      failure = Self.describe(error)
      return nil
    }
  }

  static func describe(_ error: Error) -> String {
    let text = error.localizedDescription
    if text.contains("Hub HTTP 429") { return "Back up now runs at most once an hour. Try again later." }
    if text.contains("Hub HTTP 403") {
      return "This connection cannot use hub backups. Its credential needs backup access."
    }
    return text
  }

  /// A consistent copy of the SQLite file, ready for the system save or share sheet.
  func copyReplica() async -> URL? {
    await run("Copying database") {
      let target = try folder("exports").appendingPathComponent("life-ui-\(Self.stamp).sqlite")
      try? FileManager.default.removeItem(at: target)
      try await workspace.client!.copyReplica(to: target)
      let bytes = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      message = "Copied the SQLite database (\(Self.size(bytes)))."
      return target
    }
  }

  func exportDump() async -> URL? {
    await run("Exporting") {
      let target = try folder("exports").appendingPathComponent("life-ui-\(Self.stamp).sql")
      let summary = try await workspace.client!.exportReplica(to: target)
      let bytes = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      message =
        "Exported \(summary.rows) rows from \(summary.tables.count) tables (\(Self.size(bytes)))."
      return target
    }
  }

  func backUpNow() async {
    guard let transport = workspace.imageTransport else { return }
    _ = await run("Backing up on the hub") {
      let backup = try await workspace.client!.createHubBackup(using: transport)
      message = "The hub saved a backup (\(Self.size(backup.bytes)))."
      await loadHub()
    }
  }

  func downloadHub(_ backup: CoreHubBackup) async -> URL? {
    guard let transport = workspace.imageTransport else { return nil }
    return await run("Downloading") {
      let target = try folder("exports").appendingPathComponent(
        backup.key.split(separator: "/").last.map(String.init) ?? "backup.sql.gz")
      try await transport.downloadBackup(backup, to: target)
      message = "Downloaded \(backup.key) (\(Self.size(backup.bytes))), checksum verified."
      return target
    }
  }

  private func stage(_ source: String, copying url: URL) async throws {
    let staging = try folder("staging")
    for old in (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
      try? FileManager.default.removeItem(at: old)
    }
    let target = staging.appendingPathComponent("\(Self.stamp)-\(url.lastPathComponent)")
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    try FileManager.default.copyItem(at: url, to: target)
    let data = try await workspace.client!.previewRestore(file: target)
    preview = Preview(source: source, file: target, data: data, rows: RestoreRow.rows(data))
    confirmation = ""
  }

  func previewHub(_ backup: CoreHubBackup) async {
    guard let transport = workspace.imageTransport else { return }
    _ = await run("Downloading") {
      let download = try folder("staging").appendingPathComponent("hub-download.sql.gz")
      try await transport.downloadBackup(backup, to: download)
      try await stage("Hub backup \(Self.date(backup.takenAt))", copying: download)
    }
  }

  func previewFile(_ url: URL) async {
    _ = await run("Checking backup") { try await stage("File \(url.lastPathComponent)", copying: url) }
  }

  func previewRecovery(_ copy: RecoveryCopy) async {
    _ = await run("Checking backup") {
      try await stage("Recovery copy from \(copy.modified.formatted())", copying: copy.url)
    }
  }

  func cancelPreview() {
    if let file = preview?.file { try? FileManager.default.removeItem(at: file) }
    preview = nil
    confirmation = ""
  }

  func restore() async {
    guard let preview, canRestore else { return }
    let confirm = confirmation
    _ = await run("Restoring") {
      let recoveryURL = try folder("recovery").appendingPathComponent(
        "before-restore-\(Self.stamp).sql")
      let result = try await workspace.client!.restoreReplica(
        file: preview.file, recovery: recoveryURL, confirm: confirm)
      try? FileManager.default.removeItem(at: preview.file)
      self.preview = nil
      // Keep the three newest recovery copies.
      loadRecovery()
      for old in recovery.dropFirst(3) { try? FileManager.default.removeItem(at: old.url) }
      loadRecovery()
      message =
        "Restored \(result.restored.rows) rows from \(result.restored.tables.count) tables. The previous replica is saved as a recovery copy."
      await workspace.reloadAfterRestore()
    }
  }

  static func size(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
  static func date(_ iso: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: iso)?.formatted() ?? iso
  }
}

/// Saves or shares an existing file without loading it into memory.
struct BackupFileDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.data] }
  let url: URL
  init(url: URL) { self.url = url }
  init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    try FileWrapper(url: url)
  }
}

struct BackupView: View {
  @State private var backup: BackupModel
  @State private var exporting: BackupFileDocument?
  @State private var importing = false

  init(model: WorkspaceModel) { _backup = State(initialValue: BackupModel(workspace: model)) }

  var body: some View {
    Form {
      if let text = backup.progressText {
        Section {
          Label(text, systemImage: "externaldrive").accessibilityIdentifier("backup-progress")
        }
      }
      if let message = backup.message {
        Text(message).foregroundStyle(.green).accessibilityIdentifier("backup-message")
      }
      if let failure = backup.failure {
        Text(failure).foregroundStyle(.red).textSelection(.enabled)
          .accessibilityIdentifier("backup-failure")
      }
      if let preview = backup.preview {
        previewSection(preview)
      } else {
        deviceSection
        if backup.hubBackups != nil || backup.hubError != nil { hubSection }
        if backup.sharedFile == nil {
          Section {
            Button {
              importing = true
            } label: {
              Label("Choose a backup file…", systemImage: "doc.badge.arrow.up")
            }.disabled(backup.busy != nil).accessibilityIdentifier("backup-choose-file")
          } header: {
            Text("Restore from a file")
          } footer: {
            Text("A .sql or .sql.gz dump. It is checked before anything changes.")
          }
        }
        if !backup.recovery.isEmpty { recoverySection }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Backup")
    .task { await backup.load() }
    .fileExporter(
      isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
      document: exporting, contentType: .data,
      defaultFilename: exporting?.url.lastPathComponent
    ) { _ in exporting = nil }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
      if case .success(let url) = result { Task { await backup.previewFile(url) } }
    }
  }

  private var deviceSection: some View {
    Section {
      if let shared = backup.sharedFile {
        LabeledContent("Database", value: shared.path).textSelection(.enabled)
          .accessibilityIdentifier("backup-shared-path")
        #if os(macOS)
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shared]) }
        #endif
        Text(
          "This file belongs to the Life CLI. Back it up with `life export > life.sql`; restore it with the CLI too."
        ).font(.callout)
      } else if backup.canCopyReplica {
        Button {
          Task { if let url = await backup.copyReplica() { exporting = BackupFileDocument(url: url) } }
        } label: {
          Label("Save a copy of the database", systemImage: "square.and.arrow.down")
        }.disabled(backup.busy != nil).accessibilityIdentifier("backup-copy-replica")
      }
      Button {
        Task { if let url = await backup.exportDump() { exporting = BackupFileDocument(url: url) } }
      } label: {
        Label("Export SQL dump", systemImage: "doc.text")
      }.disabled(backup.busy != nil).accessibilityIdentifier("backup-export-sql")
    } header: {
      Text("This device")
    } footer: {
      Text(
        "Export SQL writes the same portable shape as `life export`; import it with `sqlite3 life.db < dump.sql`."
      )
    }
  }

  private var hubSection: some View {
    Section {
      if let error = backup.hubError { Text(error).foregroundStyle(.red) }
      if let list = backup.hubBackups {
        if list.isEmpty { Text("The hub has no backups yet.").foregroundStyle(.secondary) }
        ForEach(list, id: \.key) { item in
          HStack {
            VStack(alignment: .leading) {
              Text(BackupModel.date(item.takenAt))
              Text("\(item.key.split(separator: "/").first ?? "") · \(BackupModel.size(item.bytes))")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Download") {
              Task { if let url = await backup.downloadHub(item) { exporting = BackupFileDocument(url: url) } }
            }.accessibilityLabel("Download \(item.key)")
            Button("Restore…") { Task { await backup.previewHub(item) } }
              .accessibilityLabel("Restore \(item.key)")
          }
          .buttonStyle(.borderless).disabled(backup.busy != nil)
        }
      }
      Button("Back up now") { Task { await backup.backUpNow() } }
        .disabled(backup.busy != nil).accessibilityIdentifier("backup-now")
    } header: {
      Text("Hub backups")
    }
  }

  private var recoverySection: some View {
    Section {
      ForEach(backup.recovery) { copy in
        HStack {
          VStack(alignment: .leading) {
            Text(copy.modified.formatted())
            Text(BackupModel.size(copy.bytes)).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Save") { exporting = BackupFileDocument(url: copy.url) }
            .accessibilityLabel("Save recovery copy from \(copy.modified.formatted())")
          Button("Restore…") { Task { await backup.previewRecovery(copy) } }
            .accessibilityLabel("Restore recovery copy from \(copy.modified.formatted())")
        }
        .buttonStyle(.borderless).disabled(backup.busy != nil)
      }
    } header: {
      Text("Recovery copies")
    } footer: {
      Text("Saved before each restore. Restore one to undo.")
    }
  }

  private func previewSection(_ preview: BackupModel.Preview) -> some View {
    Group {
      Section {
        Text(preview.source)
        LabeledContent(
          "Backup newest change",
          value: preview.data.backup.newestUpdatedAt.map(BackupModel.date) ?? "none")
        LabeledContent(
          "This device newest change",
          value: preview.data.current.newestUpdatedAt.map(BackupModel.date) ?? "none")
        ForEach(preview.rows) { row in
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Text(row.table).bold()
              Spacer()
              Text(row.change.rawValue)
                .foregroundStyle(row.change == .removed ? .red : .secondary)
            }
            Text("Backup \(Self.count(row.backup)) · this device \(Self.count(row.current))")
              .font(.caption).foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("restore-row-\(row.table)")
        }
      } header: {
        Text("Restore preview")
      }
      Section {
        Text(
          "Restoring replaces every table on this device with the backup. A recovery copy of the current replica is saved first. The next sync uploads the restored rows; rows changed on the hub after this backup keep their newer versions."
        ).font(.callout)
        if !backup.canRestore {
          Text("Save or discard open edits and wait for local changes to sync first.")
            .foregroundStyle(.red)
        }
        TextField("Type replace to confirm", text: $backup.confirmation)
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
          .accessibilityIdentifier("restore-confirm")
        Button("Restore", role: .destructive) { Task { await backup.restore() } }
          .disabled(backup.confirmation != "replace" || !backup.canRestore || backup.busy != nil)
          .accessibilityIdentifier("restore-apply")
        Button("Cancel") { backup.cancelPreview() }.disabled(backup.busy != nil)
      }
    }
  }

  private static func count(_ table: CoreBackupTableSummary?) -> String {
    table.map { "\($0.rows) rows (\($0.liveRows) live)" } ?? "-"
  }
}
