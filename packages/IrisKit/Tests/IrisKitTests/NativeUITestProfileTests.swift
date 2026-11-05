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
    }

    @Test func explicitInvalidInputCannotBecomeNormalStartup() throws {
      #expect(throws: (any Error).self) {
        _ = try NativeUITestProfile.configured(environment: ["IRIS_UI_TEST_PROFILE_ROOT": ""])
      }
      #expect(try NativeUITestProfile.configured(environment: [:]) == nil)
    }

    private func freshRoot() -> URL {
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "iris-ui-" + UUID().uuidString.lowercased(), isDirectory: true)
    }
  }
#endif
