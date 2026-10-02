import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

struct CopyDraftButton: View {
  let title: String
  let value: String
  @State private var copied = false

  static func copy(_ value: String) {
    #if os(iOS)
      UIPasteboard.general.string = value
    #else
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
    #endif
  }

  var body: some View {
    Button {
      Self.copy(value)
      copied = true
    } label: {
      Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
    }
    .accessibilityLabel(title)
    .buttonStyle(.borderless)
    .onChange(of: value) { _, _ in copied = false }
  }
}
