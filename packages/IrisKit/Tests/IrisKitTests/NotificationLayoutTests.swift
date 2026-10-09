#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import IrisKit

  @Suite(.serialized) @MainActor
  struct NotificationLayoutTests {
    @Test func emptyInboxIsCenteredAcrossSheetWidths() async throws {
      _ = NSApplication.shared
      let services = HubServicesModel()
      services.feed = NotificationFeed(
        notifications: [], nextCursor: CoreNull(), latestCursor: 0, unreadCount: 0)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .aqua)
      let host = NSHostingView(rootView: HubNotificationsView(services: services))
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      for width in [560.0, 800.0] {
        window.setContentSize(NSSize(width: width, height: 640))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let table = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
        let row = table.rect(ofRow: table.numberOfRows - 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / host.bounds.width
        if let directory = ProcessInfo.processInfo.environment["IRIS_LAYOUT_CAPTURE"] {
          try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(
              "empty-inbox-\(Int(width)).png"))
        }
        var ink: [Int] = []
        for y in Int((row.minY + 8) * scale)..<Int((row.maxY - 8) * scale) {
          for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
              continue
            }
            if color.alphaComponent > 0.8
              && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.7
            {
              ink.append(x)
            }
          }
        }
        let left = try #require(ink.min())
        let right = try #require(ink.max())
        let mid = Double(left + right) / 2
        #expect(
          abs(mid - Double(bitmap.pixelsWide) / 2) <= 4,
          "Rendered empty inbox must stay horizontally centered when the sheet resizes")
      }
    }
    private func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(descendants)
    }
  }
#endif
