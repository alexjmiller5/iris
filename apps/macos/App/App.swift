import LifeKit
import SwiftUI

@main
struct LifeUIApp: App {
  var body: some Scene {
    WindowGroup {
      WorkspaceView(
        demo: ProcessInfo.processInfo.arguments.contains("--demo")
          || (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            && !ProcessInfo.processInfo.arguments.contains("--normal-startup"))
      ).frame(minWidth: 760, minHeight: 560)
    }
    .defaultSize(width: 1000, height: 720)
  }
}
