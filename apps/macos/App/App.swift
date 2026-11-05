import IrisKit
import SwiftUI

@main
struct IrisApp: App {
  @NSApplicationDelegateAdaptor(IrisPushAppDelegate.self) private var pushDelegate
  #if DEBUG
    private let testProfile: NativeUITestProfile? = {
      do {
        return try NativeUITestProfile.configured(environment: ProcessInfo.processInfo.environment)
      } catch {
        preconditionFailure("Invalid synthetic profile: \(error)")
      }
    }()
  #endif

  private var scenePreferences: UserDefaults {
    #if DEBUG
      if let testProfile { return testProfile.preferences }
    #endif
    return .standard
  }

  private var demo: Bool {
    ProcessInfo.processInfo.arguments.contains("--demo")
      || (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        && !ProcessInfo.processInfo.arguments.contains("--normal-startup"))
  }

  var body: some Scene {
    WindowGroup(id: WorkspaceMenuBar.windowID) {
      Group {
        #if DEBUG
          if let testProfile {
            testProfile.workspace(demo: demo)
          } else {
            WorkspaceView(demo: demo)
          }
        #else
          WorkspaceView(demo: demo)
        #endif
      }.frame(minWidth: 760, minHeight: 560)
    }
    .defaultSize(width: 1000, height: 720)
    .commands { WorkspaceCommands() }
    .defaultAppStorage(scenePreferences)
    IrisMenuBar().defaultAppStorage(scenePreferences)
  }
}
