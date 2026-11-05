#if DEBUG && os(macOS)
  import Foundation
  import Testing
  @testable import IrisKit

  @MainActor struct NativeProfileWindowIsolationTests {
    @Test func windowsShareTheirSyntheticStoreButNotMutableNavigation() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "iris-ui-" + UUID().uuidString.lowercased(), isDirectory: true)
      let profile = try NativeUITestProfile(root: root)
      defer {
        profile.preferences.removePersistentDomain(forName: profile.suiteName)
        try? FileManager.default.removeItem(at: root)
      }
      let first = profile.makeWorkspaceModel()
      let second = profile.makeWorkspaceModel()
      #expect(first !== second)
      first.search = "First window"
      #expect(second.search.isEmpty)
      #expect(first.services !== second.services)
    }
  }
#endif
