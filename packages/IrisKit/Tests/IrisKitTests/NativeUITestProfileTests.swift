#if DEBUG && os(macOS)
  import Foundation
  import Testing

  @testable import IrisKit

  @MainActor struct NativeUITestProfileTests {
    @Test func rejectsForeignRootsBeforeResolvingAnyPreferences() throws {
      var calls = 0
      let root = FileManager.default.temporaryDirectory
      #expect(throws: (any Error).self) {
        _ = try NativeUITestProfile(
          root: root,
          preferencesFactory: { _ in
            calls += 1
            Issue.record("Invalid profile reached preference storage")
            return nil
          })
      }
      #expect(calls == 0)
    }

    @Test func refusesUnownedExistingDataBeforeResolvingPreferences() throws {
      let root = freshRoot()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let control = root.appendingPathComponent("keep.txt")
      try Data("Keep".utf8).write(to: control)
      var calls = 0
      #expect(throws: (any Error).self) {
        _ = try NativeUITestProfile(
          root: root,
          preferencesFactory: { _ in
            calls += 1
            Issue.record("Unowned profile reached preference storage")
            return nil
          })
      }
      #expect(calls == 0)
      #expect(try Data(contentsOf: control) == Data("Keep".utf8))
    }

    @Test func ownsOneNamedSuiteAndSyntheticWorkspaceAcrossReopen() async throws {
      let root = freshRoot()
      let profile = try NativeUITestProfile(root: root)
      defer {
        profile.preferences.removePersistentDomain(forName: profile.suiteName)
        try? FileManager.default.removeItem(at: root)
      }
      #expect(profile.suiteName.hasPrefix("iris.synthetic."))
      #expect(profile.preferences.object(forKey: "iris.sidebarHidden") == nil)
      profile.preferences.set(true, forKey: "iris.sidebarHidden")
      let otherRoot = freshRoot()
      let other = try NativeUITestProfile(root: otherRoot)
      defer {
        other.preferences.removePersistentDomain(forName: other.suiteName)
        try? FileManager.default.removeItem(at: otherRoot)
      }
      #expect(other.suiteName != profile.suiteName)
      #expect(other.preferences.object(forKey: "iris.sidebarHidden") == nil)
      let reopened = try NativeUITestProfile(root: root)
      #expect(reopened.suiteName == profile.suiteName)
      #expect(reopened.preferences.bool(forKey: "iris.sidebarHidden"))
      await profile.model.open()
      #expect(profile.model.error == nil && profile.model.canWrite && !profile.model.isReplica)
      #expect(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("local.sqlite").path))
      await profile.model.close()
      let afterSave = try NativeUITestProfile(root: root)
      #expect(afterSave.preferences.bool(forKey: "iris.sidebarHidden"))
      await afterSave.model.open()
      #expect(afterSave.model.error == nil && afterSave.model.canWrite)
      await afterSave.model.close()
    }

    @Test func explicitInvalidInputCannotBecomeNormalStartup() throws {
      #expect(throws: (any Error).self) {
        _ = try NativeUITestProfile.configured(environment: ["IRIS_UI_TEST_PROFILE_ROOT": ""])
      }
      #expect(try NativeUITestProfile.configured(environment: [:]) == nil)
    }

    @Test func rejectsTheReviewedDatabaseSymlinkBeforePreferences() throws {
      try linkedProfileIsRejected("local.sqlite")
    }

    @Test(arguments: [
      "local.sqlite-wal", "local.sqlite-shm", "local.sqlite-journal", "alerts/", "drafts/",
      "attachments/", "widgets/", "alerts/nested.json", "nested/deeper/link", ".hidden/link",
      "dangling.sqlite",
      "internal-link",
    ])
    func rejectsLinkedProfileChildrenBeforePreferences(_ path: String) throws {
      try linkedProfileIsRejected(path)
    }

    @Test func rejectsHardLinkedFilesBeforePreferences() throws {
      try linkedProfileIsRejected("hard-link", hardLink: true)
    }

    @Test func rechecksTheWorkspaceBeforeOpeningALinkInsertedAfterConstruction() async throws {
      let root = freshRoot()
      let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
        "iris-external-sentinel-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      let externalFile = outside.appendingPathComponent("sentinel.sqlite")
      let external = try await NativeWorkspace(path: externalFile.path)
      try await external.createSample()
      try await external.close()
      let before = try Data(contentsOf: externalFile)
      let profile = try NativeUITestProfile(root: root)
      defer {
        profile.preferences.removePersistentDomain(forName: profile.suiteName)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
      }
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("local.sqlite"), withDestinationURL: externalFile)
      await profile.model.open()
      #expect(profile.model.error != nil)
      await profile.model.close()
      #expect(try Data(contentsOf: externalFile) == before)
    }

    @Test func rejectsARootReplacedWithALinkToAnEmptyExternalDirectory() async throws {
      let root = freshRoot()
      let displaced = FileManager.default.temporaryDirectory.appendingPathComponent(
        "iris-displaced-" + UUID().uuidString, isDirectory: true)
      let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
        "iris-external-sentinel-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      let profile = try NativeUITestProfile(root: root)
      defer {
        profile.preferences.removePersistentDomain(forName: profile.suiteName)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: displaced)
        try? FileManager.default.removeItem(at: outside)
      }
      try FileManager.default.moveItem(at: root, to: displaced)
      try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
      await profile.model.open()
      #expect(profile.model.error != nil)
      await profile.model.close()
      #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    private func linkedProfileIsRejected(_ path: String, hardLink: Bool = false) throws {
      let root = freshRoot()
      let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
        "iris-external-sentinel-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
      }
      let owner = String(root.lastPathComponent.dropFirst(8))
      try Data(owner.utf8).write(to: root.appendingPathComponent(".native-ui-profile"))
      let sentinel = outside.appendingPathComponent("sentinel.sqlite")
      let bytes = Data("External synthetic sentinel must remain untouched".utf8)
      try bytes.write(to: sentinel)
      let link = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
      let target: URL
      if path.hasSuffix("/") {
        target = outside
      } else if path == "dangling.sqlite" {
        target = outside.appendingPathComponent("missing.sqlite")
      } else if path == "internal-link" {
        target = root.appendingPathComponent("owned.txt")
        try Data("Owned".utf8).write(to: target)
      } else {
        target = sentinel
      }
      if hardLink {
        try FileManager.default.linkItem(at: target, to: link)
      } else {
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      }
      var calls = 0
      var resolvedPreferences: UserDefaults?
      defer { resolvedPreferences?.removePersistentDomain(forName: "iris.synthetic." + owner) }
      #expect(throws: (any Error).self) {
        _ = try NativeUITestProfile(
          root: root,
          preferencesFactory: { name in
            calls += 1
            let store = UserDefaults(suiteName: name)
            resolvedPreferences = store
            return store
          })
      }
      #expect(calls == 0, "Profile must reject links before preferences or model construction")
      #expect(try Data(contentsOf: sentinel) == bytes)
    }

    private func freshRoot() -> URL {
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "iris-ui-" + UUID().uuidString.lowercased(), isDirectory: true)
    }
  }
#endif
