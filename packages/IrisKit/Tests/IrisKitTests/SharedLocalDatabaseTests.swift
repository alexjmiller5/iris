#if os(macOS)
  import AppKit
  import Foundation
  import JavaScriptCore
  import SwiftUI
  import Testing
  @testable import IrisKit

  @Suite(.serialized) @MainActor
  struct SharedLocalDatabaseTests {
    private func fixture(wal: Bool = true) async throws -> (URL, URL, WorkspaceModel) {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let file = root.appendingPathComponent("soma.db")
      let seed = try NativeWorkspace(path: file.path)
      try await seed.createSample()
      try await seed.close()
      // The CLI establishes WAL before the UI opens its shared database.
      // Switching journal modes during a UI transaction requires an exclusive
      // lock and fails immediately, independently of the ordinary busy timeout.
      if wal { _ = try await sql(file, "SELECT 1") }
      let model = WorkspaceModel(
        localURL: { root.appendingPathComponent("local.sqlite") },
        credentialStore: MemoryHubCredentials(nil))
      await model.open(url: file)
      #expect(model.error == nil)
      // An open workspace indexes itself first; these cases start from an idle UI.
      await model.searchIndexSettled()
      return (root, file, model)
    }

    private func sql(_ file: URL, _ statement: String) async throws -> String {
      // A real CLI runs independently. Blocking the main actor here can hold
      // an app transaction open while this subprocess waits for its writer lock.
      let (bytes, status) = try await Task.detached {
        let process = Process()
        let cli = ProcessInfo.processInfo.environment["IRIS_TEST_SOMA_CLI"]
        process.executableURL = URL(fileURLWithPath: cli ?? "/usr/bin/env")
        process.arguments =
          cli.map { _ in ["sql", statement] } ?? [
            "python3", "-c",
            """
            import json, sqlite3, sys
            connection = sqlite3.connect(sys.argv[1])
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA journal_mode=WAL")
            rows = [dict(row) for row in connection.execute(sys.argv[2])]
            connection.commit()
            connection.close()
            print(json.dumps(rows))
            """,
            file.path, statement,
          ]
        if cli != nil {
          var environment = ProcessInfo.processInfo.environment
          environment["SOMA_DATA_DIR"] = file.deletingLastPathComponent().path
          environment["SOMA_HUB_URL"] = "https://offline-fixture.invalid"
          process.environment = environment
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (bytes, process.terminationStatus)
      }.value
      try #require(status == 0, Comment(rawValue: String(decoding: bytes, as: UTF8.self)))
      if let rows = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
        let value = rows.first?.values.first as? String
      {
        return value
      }
      return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func separateProcessWriteLetsAnAdmittedUITransactionFinish() async throws {
      let (root, file, model) = try await fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      #expect(try await sql(file, "PRAGMA journal_mode") == "wal")
      let transaction = try SQLiteBridge(path: file.path)
      let context = try #require(JSContext())
      try transaction.install(in: context)
      context.evaluateScript("IrisSql.begin()")
      try #require(context.exception == nil)
      // The app must be able to finish an admitted transaction while the real
      // external process waits for SQLite's writer lock.
      let release = Task { @MainActor in
        try await Task.sleep(for: .milliseconds(100))
        context.evaluateScript("IrisSql.commit()")
        try #require(context.exception == nil)
      }
      _ = try await sql(file, "UPDATE notes SET title='Concurrent CLI commit'")
      try await release.value
      #expect(try await sql(file, "SELECT title FROM notes LIMIT 1") == "Concurrent CLI commit")
      try transaction.close()
      await model.close()
    }

    @Test func separateProcessCommitRefreshesOfflineGridAndPreservesUnsavedDraft() async throws {
      let (root, file, model) = try await fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let original = try #require(model.rows.first?.record)
      let context = try #require(model.editingContext)
      let editor = RecordEditorModel(
        properties: model.properties, original: original, table: "notes",
        store: nil
      ) { patch, before in
        try await model.save(patch, original: before, context: context)
      }
      editor.setValue("Unsaved UI title", for: "title")
      let observing = Task { await model.runLocalObservation(interval: .milliseconds(20)) }
      defer { observing.cancel() }
      _ = try await sql(
        file, "UPDATE notes SET title='CLI commit', updated_at='2030-01-01T00:00:00.000Z'")
      for _ in 0..<100 where model.rows.first?.label != "CLI commit" {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(
        model.rows.first?.label == "CLI commit",
        "Offline commits must refresh without manual reload or hub")
      #expect(editor.draft.values["title"] == "Unsaved UI title")
      await #expect(throws: Error.self) { try await editor.saveAll() }
      #expect(try await sql(file, "SELECT title FROM notes LIMIT 1") == "CLI commit")
      #expect(editor.dirty)
      observing.cancel()
      await observing.value
      await model.close()
    }

    @Test func uiSaveIsImmediatelyVisibleToSeparateProcessAndSelectionSurvivesRelaunch()
      async throws
    {
      let (root, file, model) = try await fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let row = try #require(model.rows.first?.record)
      _ = try await model.save(
        ["id": row["id"]!, "title": .string("UI commit")], original: row,
        context: model.editingContext)
      #expect(try await sql(file, "SELECT title FROM notes LIMIT 1") == "UI commit")
      await model.close()
      let relaunched = WorkspaceModel(
        localURL: { root.appendingPathComponent("local.sqlite") },
        credentialStore: MemoryHubCredentials(nil))
      await relaunched.resumeConnection()
      #expect(relaunched.rows.first?.label == "UI commit")
      await relaunched.close()
    }

    @Test func missingSelectedDatabaseDoesNotSilentlyCreateAnEmptyReplacement() async throws {
      let (root, file, model) = try await fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      await model.close()
      try FileManager.default.removeItem(at: file)
      let relaunched = WorkspaceModel(
        localURL: { root.appendingPathComponent("local.sqlite") },
        credentialStore: MemoryHubCredentials(nil))
      await relaunched.resumeConnection()
      #expect(relaunched.client == nil)
      #expect(relaunched.error != nil)
      #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    @Test func externalCatalogChangesRefreshWithoutDiscardingTheSelectedTable() async throws {
      // Also cover an idle legacy file whose external writer first enables WAL.
      let (root, file, model) = try await fixture(wal: false)
      defer { try? FileManager.default.removeItem(at: root) }
      // Enable WAL while the already-open UI is idle, before starting its read loop.
      _ = try await sql(file, "UPDATE catalog_tables SET purpose='Changed by CLI' WHERE id='notes'")
      let observing = Task { await model.runLocalObservation(interval: .milliseconds(20)) }
      defer { observing.cancel() }
      for _ in 0..<100
      where model.tables.first(where: { $0["id"]?.text == "notes" })?["purpose"]?.text
        != "Changed by CLI"
      {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(
        model.tables.first(where: { $0["id"]?.text == "notes" })?["purpose"]?.text
          == "Changed by CLI")
      #expect(model.table == "notes")
      #expect(!model.rows.isEmpty)
      observing.cancel()
      await observing.value
      await model.close()
    }

    @Test func switchingWorkspacesStopsOldFileObservation() async throws {
      let (root, file, model) = try await fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let observing = Task { await model.runLocalObservation(interval: .milliseconds(20)) }
      await Task.yield()
      await model.open(demo: true)
      _ = try await sql(file, "UPDATE notes SET title='Obsolete file'")
      await observing.value
      #expect(model.rows.first?.label != "Obsolete file")
      #expect(model.location == "Sample workspace · temporary")
      await model.close()
    }

    @Test func mountedWorkspaceObservesASeparateProcessWithoutManualReload() async throws {
      let (root, file, model) = try await fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: WorkspaceView(model: model)
          .environment(\.scenePhase, .active))
      window.orderFront(nil)
      defer { window.close() }
      let openedGeneration = model.workspaceGeneration
      // Let the actual startup scene task reopen the persisted file first.
      try await Task.sleep(for: .milliseconds(300))
      _ = try await sql(file, "UPDATE notes SET title='Mounted offline update'")
      for _ in 0..<100 where model.rows.first?.label != "Mounted offline update" {
        try await Task.sleep(for: .milliseconds(30))
      }
      #expect(model.rows.first?.label == "Mounted offline update")
      // A second later commit cannot be satisfied by a delayed startup reload.
      try await Task.sleep(for: .milliseconds(300))
      _ = try await sql(file, "UPDATE notes SET title='Second offline update'")
      for _ in 0..<100 where model.rows.first?.label != "Second offline update" {
        try await Task.sleep(for: .milliseconds(30))
      }
      #expect(model.rows.first?.label == "Second offline update")
      #expect(model.workspaceGeneration >= openedGeneration)
      #expect(model.error == nil)
      await model.close()
    }

  }
#endif
