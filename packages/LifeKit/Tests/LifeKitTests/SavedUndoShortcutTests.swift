import Testing

@testable import LifeKit

#if os(macOS)
  import AppKit

  @MainActor struct SavedUndoShortcutTests {
    @Test func commandZPreservesTextEditingAndDoesNotConsumeRedo() {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
        windowNumber: 0, context: nil, characters: "z", charactersIgnoringModifiers: "z",
        isARepeat: false, keyCode: 6)!
      #expect(SavedUndoKeyView.accepts(event, responder: NSView()))
      #expect(!SavedUndoKeyView.accepts(event, responder: NSTextView()))
      let redo = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
        windowNumber: 0, context: nil, characters: "Z", charactersIgnoringModifiers: "z",
        isARepeat: false, keyCode: 6)!
      #expect(!SavedUndoKeyView.accepts(redo, responder: NSView()))
    }
  }
#endif
