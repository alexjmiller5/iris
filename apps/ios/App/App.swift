import LifeKit
import SwiftUI

@main
struct LifeUIApp: App {
  @UIApplicationDelegateAdaptor(LifePushAppDelegate.self) private var pushDelegate
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
