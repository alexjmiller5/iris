import SwiftUI

struct DestinationProgress<Content: View>: View {
  let isOpening: Bool
  let cancel: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    content.overlay(alignment: .bottom) {
      if isOpening {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Opening destination placeholder").font(.subheadline)
            Text("Opening placeholder").font(.caption)
          }.skeleton("Opening destination")
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
