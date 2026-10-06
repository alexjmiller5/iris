import SwiftUI

/// A bounded native preview. Only the active cell creates a web editor.
struct NativeMarkdownPreview: View {
  let value: String
  @State private var preview = AttributedString()

  var body: some View {
    Text(preview)
      .task(id: value) {
        let source = value
        let result = await Task.detached(priority: .userInitiated) { Self.render(source) }.value
        guard !Task.isCancelled else { return }
        preview = result
      }
  }

  nonisolated static func render(_ source: String) -> AttributedString {
    let bounded = String(decoding: source.utf8.prefix(4096), as: UTF8.self)
    guard let parsed = try? AttributedString(markdown: bounded) else {
      return AttributedString(bounded)
    }
    var result = AttributedString()
    var previousBlock: Int?
    for run in parsed.runs {
      let components = run.presentationIntent?.components ?? []
      let block = components.first?.identity
      if block != previousBlock {
        if !result.characters.isEmpty { result.append(AttributedString("\n")) }
        if components.contains(where: { $0.kind == .unorderedList }) {
          result.append(AttributedString("• "))
        } else if components.contains(where: { $0.kind == .orderedList }),
          let ordinal = components.compactMap({ component -> Int? in
            if case .listItem(let ordinal) = component.kind { return ordinal }
            return nil
          }).first
        {
          result.append(AttributedString("\(ordinal). "))
        }
      }
      previousBlock = block
      var part = AttributedString(parsed[run.range])
      // A preview never takes over a table click or opens an external URL.
      part.link = nil
      if components.contains(where: {
        if case .header = $0.kind { return true }
        return false
      }) {
        part.font = .headline
      }
      result.append(part)
    }
    return result
  }
}
