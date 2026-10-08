import SwiftUI

private struct ToggleSidebarKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
  var toggleSidebar: (() -> Void)? {
    get { self[ToggleSidebarKey.self] }
    set { self[ToggleSidebarKey.self] = newValue }
  }
}

/// Menu commands for the iOS and macOS scenes. Cmd+\ also works from a hardware keyboard.
public struct WorkspaceCommands: Commands {
  @FocusedValue(\.toggleSidebar) private var toggleSidebar
  public init() {}

  public var body: some Commands {
    CommandGroup(replacing: .sidebar) {
      Button("Toggle Sidebar") { toggleSidebar?() }
        .keyboardShortcut("\\", modifiers: .command)
        .disabled(toggleSidebar == nil)
    }
  }
}
