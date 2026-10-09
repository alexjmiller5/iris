import IrisKit
import SwiftUI

@main
struct IrisApp: App {
  @NSApplicationDelegateAdaptor(IrisPushAppDelegate.self) private var pushDelegate
  var body: some Scene {
    WindowGroup(id: WorkspaceMenuBar.windowID) {
      WorkspaceView(
        demo: ProcessInfo.processInfo.arguments.contains("--demo")
          || (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            && !ProcessInfo.processInfo.arguments.contains("--normal-startup"))
      ).frame(minWidth: 760, minHeight: 560)
    }
    .defaultSize(width: 1000, height: 720)
    .commands { WorkspaceCommands() }
    IrisMenuBar()
  }
}
