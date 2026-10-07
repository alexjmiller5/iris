import LifeKit
import LifeWidgets
import SwiftUI

@main
struct LifeUIApp: App {
  init() { LifeQuickAddShortcuts.updateAppShortcutParameters() }
  var body: some Scene {
    WindowGroup {
      WorkspaceView(
        demo: ProcessInfo.processInfo.arguments.contains("--demo")
          || (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            && !ProcessInfo.processInfo.arguments.contains("--normal-startup"))
      )
    }
  }
}
