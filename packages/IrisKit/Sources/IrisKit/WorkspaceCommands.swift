import SwiftUI

/// Cmd+\ for one window. Equal while the window and layout are unchanged, so the
/// fresh closure each render publishes does not invalidate the main menu; a changed
/// focused value rebuilds it, and on macOS that rebuild re-renders the window again.
struct SidebarToggle: Equatable {
  let window: ObjectIdentifier
  let compact: Bool
  let perform: () -> Void
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.window == rhs.window && lhs.compact == rhs.compact
  }
}

private struct ToggleSidebarKey: FocusedValueKey { typealias Value = SidebarToggle }
private struct QuickFindWorkspaceKey: FocusedValueKey { typealias Value = WorkspaceModel }

extension FocusedValues {
  var quickFindWorkspace: WorkspaceModel? {
    get { self[QuickFindWorkspaceKey.self] }
    set { self[QuickFindWorkspaceKey.self] = newValue }
  }

  var toggleSidebar: SidebarToggle? {
    get { self[ToggleSidebarKey.self] }
    set { self[ToggleSidebarKey.self] = newValue }
  }
}

/// Menu commands for the iOS and macOS scenes. Cmd+\ also works from a hardware keyboard.
public struct WorkspaceCommands: Commands {
  @FocusedValue(\.toggleSidebar) private var toggleSidebar
  @FocusedValue(\.quickFindWorkspace) private var quickFindWorkspace
  public init() {}

  public var body: some Commands {
    CommandGroup(after: .textEditing) {
      Button("Find records") { quickFindWorkspace?.quickFindRequest += 1 }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(quickFindWorkspace == nil)
    }
    CommandGroup(replacing: .sidebar) {
      Button("Toggle Sidebar") { toggleSidebar?.perform() }
        .keyboardShortcut("\\", modifiers: .command)
        .disabled(toggleSidebar == nil)
    }
  }
}
