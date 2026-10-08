import LifeKit
import SwiftUI

/// Status item mirroring the active window's sync pill, with an opt-out in Settings.
struct LifeMenuBar: Scene {
  @AppStorage("lifeui.menuBarItem") private var shown = true

  var body: some Scene {
    MenuBarExtra(isInserted: $shown) {
      WorkspaceMenuBarContent()
    } label: {
      WorkspaceMenuBarLabel()
    }
    Settings {
      Form {
        Toggle("Show Life UI in the menu bar", isOn: $shown)
          .accessibilityIdentifier("menu-bar-item-toggle")
      }
      .formStyle(.grouped)
      .frame(width: 380)
    }
  }
}
