#if os(macOS)
  import AppKit
  import Observation
  import SwiftUI

  /// Menu-bar mirror of the most recently active workspace window: sync state,
  /// Quick Find, recents and pinned tables. Titles only; no credentials or row data.
  @Observable @MainActor
  public final class WorkspaceMenuBar {
    public static let shared = WorkspaceMenuBar()
    /// The `WindowGroup` id that "Open Life UI" reopens when no window is left.
    public static let windowID = "main"

    enum Command: Equatable {
      case quickFind
      case open(NativeDestination)
    }

    struct Entry: Identifiable, Equatable {
      let title: String
      let destination: NativeDestination
      var id: NativeDestination { destination }
    }

    struct Menu: Equatable {
      let status: String
      let symbol: String
      let canFind: Bool
      let recents: [Entry]
      let pinned: [Entry]
    }

    private(set) weak var workspace: WorkspaceModel?
    private var pending: (id: Int, command: Command)?
    private(set) var requestID = 0

    func attach(_ model: WorkspaceModel) { workspace = model }
    func detach(_ model: WorkspaceModel) { if workspace === model { workspace = nil } }

    func send(_ command: Command) {
      requestID += 1
      pending = (requestID, command)
    }

    /// The attached window takes the command once; other windows ignore it.
    func take(for model: WorkspaceModel) -> Command? {
      guard workspace === model, let command = pending?.command else { return nil }
      pending = nil
      return command
    }

    var menu: Menu {
      Self.menu(
        pill: workspace.flatMap { $0.client == nil ? nil : $0.syncPill },
        recents: workspace?.recents?.entries ?? [], pins: workspace?.pins?.active ?? [])
    }

    static func menu(pill: SyncPill?, recents: [NativeRecentEntry], pins: [CoreSidebarPin])
      -> Menu
    {
      Menu(
        status: pill?.title ?? "No workspace open",
        symbol: pill?.symbol ?? "tray",
        canFind: pill != nil,
        recents: recents.filter { !$0.loading && $0.unavailable == nil }.prefix(5).map {
          Entry(title: $0.label, destination: $0.destination)
        },
        pinned: pins.filter { $0.unavailable == nil }.map {
          Entry(title: $0.tbl, destination: NativeDestination(table: $0.tbl))
        })
    }
  }

  public struct WorkspaceMenuBarLabel: View {
    public init() {}
    public var body: some View {
      let menu = WorkspaceMenuBar.shared.menu
      Image(systemName: menu.symbol).accessibilityLabel("Life UI: \(menu.status)")
    }
  }

  public struct WorkspaceMenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    private let bar = WorkspaceMenuBar.shared
    public init() {}

    public var body: some View {
      let menu = bar.menu
      Text(menu.status)
      Divider()
      Button("Open Life UI") { showWindow() }
      Button("Quick Find…") {
        showWindow()
        bar.send(.quickFind)
      }.keyboardShortcut("k").disabled(!menu.canFind)
      if !menu.recents.isEmpty {
        Section("Recents") { entries(menu.recents) }
      }
      if !menu.pinned.isEmpty {
        Section("Pinned tables") { entries(menu.pinned) }
      }
      Divider()
      Button("Quit Life UI") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func entries(_ entries: [WorkspaceMenuBar.Entry]) -> some View {
      ForEach(entries) { entry in
        Button(entry.title) {
          showWindow()
          bar.send(.open(entry.destination))
        }
      }
    }

    private func showWindow() {
      NSApp.activate()
      if let window = NSApp.windows.first(where: {
        $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
      }) {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
      } else {
        openWindow(id: WorkspaceMenuBar.windowID)
      }
    }
  }
#endif
