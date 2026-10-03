import Foundation
import Testing

@testable import LifeKit

@MainActor
struct PendingNativeLinkTests {
  private func link(_ row: String) throws -> NativeDeepLink {
    try NativeDeepLink(destination: NativeDestination(table: "notes", rowID: row),
      workspace: .local(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!))
  }

  @Test func receivingAndFailedOpeningKeepTheIntentUntilExplicitCompletion() throws {
    var state = PendingNativeLink()
    let link = try link("row")
    state.receive(link.url)
    let request = try #require(state.request)
    #expect(request.link == link)
    #expect(state.requestToOpen(allowed: false) == nil)
    #expect(state.request?.id == request.id)
    #expect(state.requestToOpen(allowed: true)?.id == request.id)
    state.fail(request.id, message: "Finish editing first")
    #expect(state.request?.id == request.id && state.error != nil)
    state.complete(request.id)
    #expect(state.request == nil && state.error == nil)
  }

  @Test func invalidInputKeepsThePriorIntentWithoutEchoingRawURL() throws {
    var state = PendingNativeLink()
    state.receive(try link("row").url)
    let request = try #require(state.request)
    state.receive(URL(string: "life://open/v1?token=must-not-echo")!)
    #expect(state.request?.id == request.id)
    #expect(state.error != nil && state.error?.contains("must-not-echo") == false)
    state.dismiss()
    #expect(state.request == nil && state.error == nil)
  }

  @Test func lateCompletionAndErrorCannotReplaceANewerByteDistinctIntent() async throws {
    var state = PendingNativeLink()
    state.receive(try link("\u{00e9}").url)
    let first = try #require(state.request)
    var release: CheckedContinuation<Void, Never>?
    let task = Task {
      await withCheckedContinuation { release = $0 }
      state.complete(first.id)
      state.fail(first.id, message: "Old lookup failed")
    }
    while release == nil { await Task.yield() }
    state.receive(try link("e\u{0301}").url)
    let second = try #require(state.request)
    #expect(second.id != first.id && second.link.destination != first.link.destination)
    release?.resume()
    await task.value
    #expect(state.request?.id == second.id && state.error == nil)
    state.dismiss()
    state.fail(second.id, message: "Dismissed lookup")
    #expect(state.request == nil && state.error == nil)
  }
}
