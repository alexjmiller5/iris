#if DEBUG && os(macOS)
  import Foundation
  import Testing

  @testable import IrisKit

  @MainActor struct DuplicatePreparationTests {
    @Test func copyReadsFreshFullValuesAndMarksOnlyItsFirstSuccessfulCreation() async throws {
      try await fixture { model in
        let context = try #require(model.editingContext)
        let source = try await context.workspace.write(
          table: context.table,
          patch: [
            "title": .string("Before"), "body": .string("Old body"),
          ])
        let id = try #require(source["id"]?.text)
        await model.reload()
        _ = try await context.workspace.write(
          table: context.table,
          patch: [
            "id": .string(id), "title": .string("After"),
            "body": .string(" # Fresh\n\ncafe\u{301}\n"),
          ], expectedUpdatedAt: source["updated_at"]?.text)
        var created: [Data] = []
        let copy = try await model.prepareDuplicate(
          rowID: id, context: context, isCurrent: { true },
          onCreated: { created.append(Data($0.utf8)) })
        #expect(copy.isNew && copy.draft.original == nil)
        #expect(copy.draft.values["title"] == "After")
        #expect(
          Data((copy.draft.values["body"] ?? "").utf8) == Data(" # Fresh\n\ncafe\u{301}\n".utf8))
        #expect(created.isEmpty, "Preparing a journal must not mark an unsaved row")
        try await copy.flushAutosave()
        let saved = try #require(copy.draft.original)
        let newID = try #require(saved["id"]?.text)
        #expect(Data(newID.utf8) != Data(id.utf8))
        #expect(created == [Data(newID.utf8)])
        copy.setValue("Copy edited", for: "title")
        try await copy.flushAutosave()
        #expect(created == [Data(newID.utf8)], "Later saves must not add another creation marker")
        let unchanged = try #require(try await model.storedRow(id: id, context: context))
        #expect(unchanged["title"] == .string("After"))
      }
    }

    @Test func cancelledPreparationCannotCreateAJournalOrRow() async throws {
      try await fixture { model in
        let context = try #require(model.editingContext)
        let before = try await context.workspace.rows(table: context.table).count
        let filesBefore =
          (try? context.draftStore.map {
            try FileManager.default.contentsOfDirectory(
              at: $0.directory, includingPropertiesForKeys: nil)
          }) ?? []
        await #expect(throws: CancellationError.self) {
          _ = try await model.prepareDuplicate(
            rowID: "irrelevant", context: context, isCurrent: { false })
        }
        #expect(try await context.workspace.rows(table: context.table).count == before)
        let filesAfter =
          (try? context.draftStore.map {
            try FileManager.default.contentsOfDirectory(
              at: $0.directory, includingPropertiesForKeys: nil)
          }) ?? []
        #expect(filesAfter == filesBefore)
      }
    }

    @Test func replacedWorkspaceCannotReuseAnOldEditingContext() async throws {
      try await fixture { model in
        let previous = try #require(model.editingContext)
        await model.close()
        await model.open()
        await #expect(throws: (any Error).self) {
          _ = try await model.prepareDuplicate(
            rowID: "irrelevant", context: previous, isCurrent: { true })
        }
      }
    }

    private func fixture(_ operation: (WorkspaceModel) async throws -> Void) async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "iris-ui-" + UUID().uuidString.lowercased(), isDirectory: true)
      let profile = try NativeUITestProfile(root: root)
      defer {
        profile.preferences.removePersistentDomain(forName: profile.suiteName)
        try? FileManager.default.removeItem(at: root)
      }
      let model = profile.model
      await model.open()
      do {
        try #require(model.error == nil)
        try await operation(model)
        await model.close()
      } catch {
        await model.close()
        throw error
      }
    }
  }
#endif
