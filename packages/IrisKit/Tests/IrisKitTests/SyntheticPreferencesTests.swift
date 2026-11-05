import Foundation
import SwiftUI
import Testing

@testable import IrisKit

@MainActor struct SyntheticPreferencesTests {
  @Test func sidebarStorageUsesOnlyItsNamedSuite() throws {
    let suite = "iris.synthetic." + UUID().uuidString
    let store = try #require(ObservedSyntheticDefaults(suiteName: suite))
    defer { store.removePersistentDomain(forName: suite) }
    let hidden = AppStorage(wrappedValue: false, "iris.sidebarHidden", store: store)
    let initial = hidden.wrappedValue
    // Abort before any gesture/write if a fixture accidentally uses shared defaults.
    try #require(store.irisReads > 0, "Fixture did not read its named preferences suite")
    #expect(!initial)
    let visibility = SidebarToggle.visibility(
      hidden: Binding(get: { hidden.wrappedValue }, set: { hidden.wrappedValue = $0 }),
      reduceMotion: false)
    visibility.wrappedValue = .detailOnly
    #expect(store.bool(forKey: "iris.sidebarHidden"))
    let reopened = try #require(UserDefaults(suiteName: suite))
    #expect(reopened.bool(forKey: "iris.sidebarHidden"))
    visibility.wrappedValue = .all
    #expect(!reopened.bool(forKey: "iris.sidebarHidden"))
  }
}

// Used only by this main-actor fixture, including all AppStorage accesses.
private final class ObservedSyntheticDefaults: UserDefaults, @unchecked Sendable {
  var irisReads = 0
  override func object(forKey key: String) -> Any? {
    if key.hasPrefix("iris.") { irisReads += 1 }
    return super.object(forKey: key)
  }
  override func bool(forKey key: String) -> Bool {
    if key.hasPrefix("iris.") { irisReads += 1 }
    return super.bool(forKey: key)
  }
}
