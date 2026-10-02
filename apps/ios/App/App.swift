import LifeKit
import SwiftUI

@main
struct LifeUIApp: App {
  var body: some Scene {
    WindowGroup {
      WorkspaceView(
        demo: ProcessInfo.processInfo.arguments.contains("--demo")
          || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    }
  }
}
