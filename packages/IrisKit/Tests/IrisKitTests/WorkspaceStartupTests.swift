#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import IrisKit

  @Suite(.serialized) @MainActor
  struct WorkspaceStartupTests {
    @Test func anotherWindowOpensAfterTheCurrentWindowCommits() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let path = root.appendingPathComponent("workspace.sqlite")
      let runtime = try IrisCoreRuntime()
      let first = try NativeWorkspace(path: path.path, runtime: runtime)
      try await first.createSample()
      runtime.context.evaluateScript(
        #"""
        const original = IrisNative.request;
        let held = false;
        IrisNative.request = function(id, method, args) {
          if (method !== 'catalog') return original(id, method, args);
          IrisSql.begin();
          IrisSql.run("UPDATE notes SET title='Committed from first window'");
          held = true;
          globalThis.releaseWindow = () => {
            IrisSql.commit();
            held = false;
            original(id, method, args);
          };
        };
        """#)
      let transaction = Task { try await first.catalog() }
      for _ in 0..<100 where runtime.context.evaluateScript("held")?.toBool() != true {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(runtime.context.evaluateScript("held")?.toBool() == true)
      let model = WorkspaceModel(
        localURL: { root.appendingPathComponent("local.sqlite") },
        credentialStore: MemoryHubCredentials(nil))
      _ = NSApplication.shared
      let view = NSHostingView(rootView: WorkspaceView(model: model))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = view
      window.orderFront(nil)
      defer { window.close() }
      var finished = false
      let opening = Task {
        await model.open(url: path)
        finished = true
      }
      try await Task.sleep(for: .milliseconds(100))
      #expect(!finished, "Opening another window must wait cooperatively for the transaction")
      #expect(model.error == nil, "Opening must not expose SQLite BUSY")
      runtime.context.evaluateScript("releaseWindow()")
      _ = try await transaction.value
      await opening.value
      #expect(model.error == nil)
      #expect(model.client != nil)
      #expect(!model.rows.isEmpty)
      #expect(model.rows.allSatisfy { $0.label == "Committed from first window" })
      await model.close()
      try await first.close()
    }
  }
#endif
