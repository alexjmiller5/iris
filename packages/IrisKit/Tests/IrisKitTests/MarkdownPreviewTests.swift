import Foundation
import Testing

@testable import IrisKit

struct MarkdownPreviewTests {
  @Test func tableTextInterpretsHeadingsListsAndEmphasisWithoutJoiningBlocks() {
    let source = "# Heading\n\n- First **bold**\n- Second\n\nPlain text"
    #expect(
      NativePropertyValue.text(type: "markdown", value: source)
        == "Heading\n• First bold\n• Second\nPlain text")
    #expect(NativePropertyValue.text(type: "markdown", value: "\\# Literal") == "# Literal")
    #expect(
      NativePropertyValue.text(type: "markdown", value: "[Read](https://example.com)") == "Read")
  }

  @Test func tablePreviewsBoundWorkWithoutChangingTheStoredSource() {
    let source = String(repeating: "# A paragraph\n\n", count: 100_000)
    let preview = NativePropertyValue.text(type: "markdown", value: source)
    #expect(preview.utf8.count < 5_000)
    #expect(source.hasSuffix("# A paragraph\n\n"))
  }

  @Test func markdownColumnsGetWritingSpaceWithoutOverridingSavedWidths() throws {
    let property: WorkspaceRecord = ["col": .string("body"), "type": .string("markdown")]
    #expect(NativeGridColumn.columns(properties: [property]).first?.width == 360)
    #expect(
      NativeGridColumn.columns(properties: [property], widths: ["body": 225]).first?.width == 225)
  }
}
