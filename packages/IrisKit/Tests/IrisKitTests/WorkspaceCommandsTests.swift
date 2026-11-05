import Foundation
import SwiftUI
import Testing

@testable import IrisKit

struct WorkspaceCommandsTests {
  @MainActor
  @Test(arguments: [false, true])
  func sidebarVisibilityUsesTheSameAnimationForBothDirections(reduceMotion: Bool) {
    var hidden = false
    var animations: [Animation?] = []
    let stored = Binding<Bool>(
      get: { hidden },
      set: { value, transaction in
        hidden = value
        animations.append(transaction.animation)
      })
    let visibility = SidebarToggle.visibility(hidden: stored, reduceMotion: reduceMotion)

    #expect(visibility.wrappedValue == .all)
    visibility.wrappedValue = .detailOnly
    #expect(hidden)
    #expect(visibility.wrappedValue == .detailOnly)
    visibility.wrappedValue = .all
    #expect(!hidden)
    #expect(visibility.wrappedValue == .all)
    #expect(animations.count == 2)
    let expected: Animation? = reduceMotion ? nil : .easeOut(duration: 0.2)
    #expect(animations.allSatisfy { $0 == expected })

    hidden = true
    #expect(visibility.wrappedValue == .detailOnly)
  }

  /// A fresh closure from every render must not count as a new focused value, or
  /// macOS rebuilds the main menu on each render and the app stops responding.
  @Test func sidebarToggleIsStableForTheSameWindowAndLayout() {
    let window = NSObject()
    let other = NSObject()
    let toggle = SidebarToggle(window: ObjectIdentifier(window), compact: false) {}
    #expect(toggle == SidebarToggle(window: ObjectIdentifier(window), compact: false) {})
    #expect(toggle != SidebarToggle(window: ObjectIdentifier(other), compact: false) {})
    #expect(toggle != SidebarToggle(window: ObjectIdentifier(window), compact: true) {})
  }
}
