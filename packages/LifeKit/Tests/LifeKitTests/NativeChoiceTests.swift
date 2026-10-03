import Foundation
import Testing

@testable import LifeKit

@MainActor
struct NativeChoiceTests {
  private func field(_ type: String = "multi_select") -> CatalogField {
    CatalogField(property: [
      "col": .string("tags"), "type": .string(type), "label": .string("Tags"),
      "options": .array([
        .object(["v": .string("Ready"), "d": .string("Ready to use")]),
        .object(["v": .string("\u{e9}"), "d": .string("First spelling")]),
        .object(["v": .string("e\u{301}"), "d": .string("Second spelling")]),
      ]),
    ])
  }

  @Test func choicesMergeCatalogDynamicAndUnknownValuesWithoutReplacingTheDraft() throws {
    let raw = "[ \"Unknown\", \"Ready\" ]"
    let projected = try NativeChoiceOptions(
      field: field(), dynamic: ["Dynamic", "Ready"], value: raw)
    #expect(
      projected.choices.map(\.value) == ["Ready", "\u{e9}", "e\u{301}", "Dynamic", "Unknown"])
    #expect(projected.selection.ids == ["Unknown", "Ready"])
    #expect(projected.selection.value == raw)
    #expect(projected.choices.first?.description == "Ready to use")
  }

  @Test func canonicallyEquivalentChoicesKeepIndependentDescriptionsAndUIIdentity() throws {
    let projected = try NativeChoiceOptions(field: field(), dynamic: [], value: "[]")
    let first = try #require(projected.choices.first { Data($0.value.utf8) == Data([0xc3, 0xa9]) })
    let second = try #require(
      projected.choices.first { Data($0.value.utf8) == Data([0x65, 0xcc, 0x81]) })
    #expect(first.id != second.id)
    #expect(first.description == "First spelling")
    #expect(second.description == "Second spelling")
  }

  @Test func singleSelectionRetainsAnUnknownValueWithoutTreatingItAsJSON() throws {
    let projected = try NativeChoiceOptions(field: field("select"), dynamic: [], value: "Unlisted")
    #expect(projected.selection.ids == ["Unlisted"])
    #expect(projected.choices.last?.value == "Unlisted")
  }

  @Test(arguments: ["{broken", "{}", "[\"Ready\", 4]"])
  func invalidStoredMultiSelectionIsNotSilentlyCleared(_ value: String) {
    #expect(throws: (any Error).self) {
      try NativeChoiceOptions(field: field(), dynamic: [], value: value)
    }
  }

  @Test func choiceLoadingUsesTheRealCoreOptionsResult() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let model = NativeChoiceModel {
      try await workspace.options(table: "notes", column: "status")
    }
    await model.refresh()
    #expect(model.options == ["Draft", "Ready"])
    #expect(model.error == nil)
    #expect(!model.loading)
    try await workspace.close()
  }

  @Test func failedRefreshPreservesChoicesAndRetryClearsTheError() async {
    var fail = false
    let model = NativeChoiceModel {
      if fail { throw WorkspaceError(message: "Choices unavailable", violations: []) }
      return ["Ready"]
    }
    await model.refresh()
    fail = true
    await model.refresh()
    #expect(model.options == ["Ready"])
    #expect(model.error == "Choices unavailable")
    #expect(!model.loading)
    fail = false
    await model.refresh()
    #expect(model.options == ["Ready"])
    #expect(model.error == nil)
  }

  @Test(arguments: ["view", "task", "workspace"], [false, true])
  func cancelledRepliesCannotPublishAndAVisibleFieldCanLoadAgain(_ kind: String, _ fail: Bool) async
  {
    var pending: CheckedContinuation<[String], any Error>?
    var contextCurrent = true
    var first = true
    let model = NativeChoiceModel(
      load: {
        if first {
          first = false
          return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return ["Visible again"]
      }, isCurrent: { contextCurrent })
    let loading = Task { await model.refresh() }
    while pending == nil { await Task.yield() }
    #expect(model.loading)
    if kind == "view" { model.cancel() }
    if kind == "task" { loading.cancel() }
    if kind == "workspace" { contextCurrent = false }
    if fail {
      pending?.resume(throwing: WorkspaceError(message: "Obsolete failure", violations: []))
    } else {
      pending?.resume(returning: ["Obsolete choice"])
    }
    await loading.value
    #expect(model.options.isEmpty)
    #expect(model.error == nil)
    #expect(!model.loading)
    contextCurrent = true
    await model.refresh()
    #expect(model.options == ["Visible again"])
  }

  @Test(arguments: [false, true])
  func aNewRefreshSupersedesAnOlderReply(_ fail: Bool) async {
    var pending: CheckedContinuation<[String], any Error>?
    var first = true
    let model = NativeChoiceModel {
      if first {
        first = false
        return try await withCheckedThrowingContinuation { pending = $0 }
      }
      return ["Current choice"]
    }
    let old = Task { await model.refresh() }
    while pending == nil { await Task.yield() }
    await model.refresh()
    if fail {
      pending?.resume(throwing: WorkspaceError(message: "Old failure", violations: []))
    } else {
      pending?.resume(returning: ["Old choice"])
    }
    await old.value
    #expect(model.options == ["Current choice"])
    #expect(model.error == nil)
    #expect(!model.loading)
  }
}
