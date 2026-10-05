import SwiftUI

struct DestinationProgress<Content: View>: View {
  let isOpening: Bool
  let cancel: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    content.overlay(alignment: .bottom) {
      if isOpening {
        HStack(spacing: 12) {
          ProgressView().accessibilityLabel("Opening destination")
          Text("Opening…")
          Spacer()
          Button("Cancel", action: cancel)
            .accessibilityIdentifier("cancel-destination")
            .accessibilityLabel("Cancel opening destination")
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 64)
      }
    }
  }
}
