#if os(iOS)
  import SwiftUI
  import Testing
  import UIKit

  @testable import IrisKit

  @MainActor
  struct NativeChoiceLifecycleTests {
    @Test func delayedChoicesLoadOnceAndPublishAfterLoadingRowDisappears() async throws {
      var calls = 0
      var pending: [CheckedContinuation<[String], Never>] = []
      let model = NativeChoiceModel(load: {
        calls += 1
        return await withCheckedContinuation { pending.append($0) }
      })
      let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      let previous = scene.keyWindow
      let window = UIWindow(windowScene: scene)
      window.rootViewController = UIHostingController(rootView: ChoiceHarness(model: model))
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
        for continuation in pending { continuation.resume(returning: []) }
      }
      for _ in 0..<100 where calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
      try await Task.sleep(for: .milliseconds(250))
      #expect(calls == 1)
      #expect(model.loading)
      let first = try #require(pending.first)
      pending.removeFirst()
      first.resume(returning: ["Dynamic one", "Dynamic two"])
      try await Task.sleep(for: .milliseconds(300))
      #expect(calls == 1)
      #expect(model.options == ["Dynamic one", "Dynamic two"])
      #expect(!model.loading)
      #expect(model.error == nil)
    }
  }

  private struct ChoiceHarness: View {
    let model: NativeChoiceModel
    @State private var value = ""
    @FocusState private var focus: String?
    var body: some View {
      Form {
        NativeChoiceField(
          field: CatalogField(property: [
            "col": .string("dynamic"), "type": .string("select"),
            "label": .string("Dynamic choice"), "options_sql": .string("SELECT 'Dynamic one'"),
          ]), isNew: false, value: $value, workspace: nil, focus: $focus,
          isCurrent: { true }, choiceModel: model)
      }
    }
  }
#endif
