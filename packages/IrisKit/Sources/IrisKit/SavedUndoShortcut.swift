import SwiftUI

extension View {
  func savedUndoShortcut(enabled: Bool, perform: @escaping @MainActor () -> Void) -> some View {
    #if os(macOS)
      background(SavedUndoShortcut(enabled: enabled, perform: perform).frame(width: 0, height: 0))
    #else
      onKeyPress(characters: CharacterSet(charactersIn: "z"), phases: .down) { key in
        guard enabled, key.modifiers == .command else { return .ignored }
        perform()
        return .handled
      }
    #endif
  }
}

#if os(macOS)
  import AppKit
  import WebKit

  private struct SavedUndoShortcut: NSViewRepresentable {
    let enabled: Bool
    let perform: @MainActor () -> Void
    func makeNSView(context: Context) -> SavedUndoKeyView { SavedUndoKeyView() }
    func updateNSView(_ view: SavedUndoKeyView, context: Context) {
      view.onUndo = enabled ? perform : nil
    }
    static func dismantleNSView(_ view: SavedUndoKeyView, coordinator: ()) { view.stop() }
  }

  @MainActor final class SavedUndoKeyView: NSView {
    var onUndo: (@MainActor () -> Void)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, let window = self.window, window.isKeyWindow,
          event.window === window, let perform = self.onUndo,
          Self.accepts(event, responder: window.firstResponder)
        else { return event }
        perform()
        return nil
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
    static func accepts(_ event: NSEvent, responder: NSResponder?) -> Bool {
      guard !event.isARepeat, event.charactersIgnoringModifiers?.lowercased() == "z",
        event.modifierFlags.intersection([.command, .control, .shift, .option]) == .command
      else { return false }
      // AppKit fields and WebKit writing surfaces retain their native text undo.
      if responder is NSTextInputClient || responder is NSTextView { return false }
      var view = responder as? NSView
      while let current = view {
        if current is WKWebView { return false }
        view = current.superview
      }
      return true
    }
  }
#endif
