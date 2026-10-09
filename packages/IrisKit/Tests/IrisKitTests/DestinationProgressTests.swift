#if os(iOS)
  import Observation
  import SwiftUI
  import Testing
  import UIKit

  @testable import IrisKit

  @MainActor
  struct DestinationProgressTests {
    @Test func openingDoesNotMoveOrResizeTheWorkspace() async throws {
      let probe = ProgressProbe()
      let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      let previous = scene.keyWindow
      let window = UIWindow(windowScene: scene)
      window.rootViewController = UIHostingController(rootView: ProgressHarness(probe: probe))
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
      }
      for _ in 0..<100 where probe.frame == .zero {
        try await Task.sleep(for: .milliseconds(10))
      }
      let initial = probe.frame
      #expect(initial.height > 0)
      probe.opening = true
      try await Task.sleep(for: .milliseconds(250))
      #expect(probe.frame == initial)
      probe.opening = false
      try await Task.sleep(for: .milliseconds(100))
      #expect(probe.frame == initial)
    }
  }

  @Observable @MainActor private final class ProgressProbe {
    var opening = false
    var frame = CGRect.zero
  }

  private struct ProgressHarness: View {
    let probe: ProgressProbe
    var body: some View {
      DestinationProgress(isOpening: probe.opening, cancel: { probe.opening = false }) {
        NavigationStack {
          List { Text("Synthetic record") }
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onGeometryChange(for: CGRect.self) {
          $0.frame(in: .global)
        } action: {
          probe.frame = $0
        }
      }
    }
  }
#endif
