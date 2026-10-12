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
      let runtime = try await IrisCoreRuntime.onCore()
      let first = try await NativeWorkspace(path: path.path, runtime: runtime)
      try await first.createSample()
      await runtime.evaluateOnCore(
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
      await runtime.evaluateOnCore("releaseWindow()")
      _ = try await transaction.value
      await opening.value
      #expect(model.error == nil)
      #expect(model.client != nil)
      #expect(!model.rows.isEmpty)
      #expect(model.rows.allSatisfy { $0.label == "Committed from first window" })
      await model.close()
      try await first.close()
    }

    @Test func launchShowsPlaceholdersUntilTheRememberedWorkspaceOpens() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let path = root.appendingPathComponent("workspace.sqlite")
      let local = root.appendingPathComponent("local.sqlite")
      let chosen = WorkspaceModel(
        localURL: { local }, credentialStore: MemoryHubCredentials(nil))
      let runtime = try await IrisCoreRuntime.onCore()
      let first = try await NativeWorkspace(path: path.path, runtime: runtime)
      try await first.createSample()
      await chosen.open(url: path)
      #expect(chosen.client != nil)
      await chosen.close()
      // Another window holds a transaction, so the relaunch's restore waits mid-open.
      await runtime.evaluateOnCore(
        #"""
        const original = IrisNative.request;
        IrisNative.request = function(id, method, args) {
          if (method !== 'catalog') return original(id, method, args);
          IrisSql.begin();
          globalThis.held = true;
          globalThis.releaseWindow = () => { IrisSql.commit(); original(id, method, args); };
        };
        """#)
      let transaction = Task { try await first.catalog() }
      for _ in 0..<100 where runtime.context.evaluateScript("globalThis.held")?.toBool() != true {
        try await Task.sleep(for: .milliseconds(10))
      }
      let relaunched = WorkspaceModel(
        localURL: { local }, credentialStore: MemoryHubCredentials(nil))
      #expect(relaunched.restoring, "A new window starts restoring")
      #expect(!WorkspaceView.showsWelcome(restoring: relaunched.restoring, opening: false))
      let restore = Task { await relaunched.restoreAtLaunch(demo: false) }
      try await Task.sleep(for: .milliseconds(150))
      #expect(relaunched.client == nil && relaunched.restoring)
      #expect(
        !WorkspaceView.showsWelcome(restoring: relaunched.restoring, opening: relaunched.loading),
        "The welcome screen must not flash while the remembered workspace opens")
      await runtime.evaluateOnCore("releaseWindow()")
      _ = try await transaction.value
      await restore.value
      #expect(!relaunched.restoring)
      #expect(relaunched.client != nil && relaunched.error == nil)
      await relaunched.close()
      try await first.close()
    }

    @Test func launchWithNothingRememberedShowsTheWelcomeScreen() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let model = WorkspaceModel(
        localURL: { root.appendingPathComponent("local.sqlite") },
        credentialStore: MemoryHubCredentials(nil))
      await model.restoreAtLaunch(demo: false)
      #expect(!model.restoring && model.client == nil && model.error == nil)
      #expect(WorkspaceView.showsWelcome(restoring: model.restoring, opening: model.loading))
    }
  }
#endif
