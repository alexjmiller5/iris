import IrisKit
import SwiftUI

/// Status item mirroring the active window's sync pill, with an opt-out in Settings.
struct IrisMenuBar: Scene {
  @AppStorage("iris.menuBarItem") private var shown = true

  var body: some Scene {
    // SwiftUI writes isInserted back on every scene update; an unchanged write to
    // AppStorage invalidates the scenes again and spins the main thread at launch.
    MenuBarExtra(isInserted: Binding(get: { shown }, set: { if shown != $0 { shown = $0 } })) {
      WorkspaceMenuBarContent()
    } label: {
      WorkspaceMenuBarLabel()
    }
    Settings {
      Form {
        Toggle("Show Iris in the menu bar", isOn: $shown)
          .accessibilityIdentifier("menu-bar-item-toggle")
      }
      .formStyle(.grouped)
      .frame(width: 380)
    }
  }
}
