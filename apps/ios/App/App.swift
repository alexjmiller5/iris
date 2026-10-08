import AppIntents
import LifeKit
import LifeWidgets
import SwiftUI

@main
struct LifeUIApp: App {
  @UIApplicationDelegateAdaptor(LifePushAppDelegate.self) private var pushDelegate
  init() { LifeUIShortcuts.updateAppShortcutParameters() }
  var body: some Scene {
    WindowGroup {
      WorkspaceView(
        demo: ProcessInfo.processInfo.arguments.contains("--demo")
          || (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            && !ProcessInfo.processInfo.arguments.contains("--normal-startup"))
      )
    }
    .commands { WorkspaceCommands() }
  }
}

/// App Shortcuts must be declared by the app bundle itself to be discovered.
struct LifeUIShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: QuickAddIntent(), phrases: ["Quick Add in \(.applicationName)"],
      shortTitle: "Quick Add", systemImageName: "plus")
    AppShortcut(
      intent: OpenTodayIntent(), phrases: ["Open Today in \(.applicationName)"],
      shortTitle: "Open Today", systemImageName: "calendar")
    AppShortcut(
      intent: LookUpRecordIntent(), phrases: ["Look up in \(.applicationName)"],
      shortTitle: "Look Up", systemImageName: "person.crop.circle")
  }
}
