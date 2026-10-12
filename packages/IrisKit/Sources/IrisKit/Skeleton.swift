import SwiftUI

/// Loading placeholders shaped like the content that replaces them: the content is redacted
/// to soft bars with a passing highlight, which stops under Reduce Motion. Assistive
/// technology hears one element with `label` instead of the placeholder text.
struct SkeletonModifier: ViewModifier {
  let label: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @State private var sweep = false

  func body(content: Content) -> some View {
    content
      .redacted(reason: .placeholder)
      .overlay {
        if !reduceMotion {
          GeometryReader { proxy in
            LinearGradient(
              colors: [.clear, .white.opacity(colorScheme == .dark ? 0.12 : 0.55), .clear],
              startPoint: .leading, endPoint: .trailing
            )
            .frame(width: proxy.size.width / 2)
            .offset(x: sweep ? proxy.size.width : -proxy.size.width / 2)
          }
          .mask { content.redacted(reason: .placeholder) }
          .allowsHitTesting(false)
          .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
              sweep = true
            }
          }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityIdentifier("skeleton")
  }
}

extension View {
  /// Shows this content as a loading placeholder (see `SkeletonModifier`).
  func skeleton(_ label: String = "Loading") -> some View {
    modifier(SkeletonModifier(label: label))
  }
}

/// Placeholder list rows: a title line over a shorter detail line, varied in width.
struct SkeletonRows: View {
  var count = 6
  var label = "Loading records"
  /// Sidebar rows are a single line beside an icon.
  var compact = false

  private static let titles = [
    "A record title placeholder", "Another record", "A longer record title placeholder",
    "Short title", "Record title placeholder text", "A record",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 14 : 18) {
      ForEach(0..<count, id: \.self) { index in
        if compact {
          Label(Self.titles[index % Self.titles.count], systemImage: "tablecells")
        } else {
          VStack(alignment: .leading, spacing: 6) {
            Text(Self.titles[index % Self.titles.count]).font(.headline)
            Text(Self.titles[(index + 3) % Self.titles.count]).font(.subheadline)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 6)
    .skeleton(label)
  }
}
