import Foundation
import Testing

@testable import IrisKit

struct WorkspaceCommandsTests {
  /// A fresh closure from every render must not count as a new focused value, or
  /// macOS rebuilds the main menu on each render and the app stops responding.
  @Test func sidebarToggleIsStableForTheSameWindowAndLayout() {
    let window = NSObject(), other = NSObject()
    let toggle = SidebarToggle(window: ObjectIdentifier(window), compact: false) {}
    #expect(toggle == SidebarToggle(window: ObjectIdentifier(window), compact: false) {})
    #expect(toggle != SidebarToggle(window: ObjectIdentifier(other), compact: false) {})
    #expect(toggle != SidebarToggle(window: ObjectIdentifier(window), compact: true) {})
  }
}
