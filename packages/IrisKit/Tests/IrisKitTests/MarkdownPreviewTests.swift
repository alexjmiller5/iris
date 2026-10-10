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

  @Test func previewsFlattenNotionTagsMentionsAndEmbeds() {
    let callout =
      "<callout icon=\"x\" color=\"gray_bg\">\n\t**Rules applied**\n\tEarlier entries win.\n</callout>\n<empty-block/>\nAfter"
    let preview = NativePropertyValue.text(type: "markdown", value: callout)
    #expect(!preview.contains("<") && !preview.contains("callout"))
    #expect(preview.contains("Rules applied") && preview.contains("Earlier entries win."))
    #expect(preview.hasSuffix("After"))
    #expect(
      NativePropertyValue.text(
        type: "markdown",
        value: "See <mention-page url=\"https://example.com/p\">Plan</mention-page> and "
          + "[Person One](iris://table/people/row/abc) in [Weekly](iris://table/tasks/view/v1)."
      ) == "See Plan and Person One in Weekly.")
    #expect(
      NativePropertyValue.text(
        type: "markdown", value: "<details>\n<summary>Packing</summary>\n\t- Shirt\n</details>")
        == "Packing\n• Shirt")
    #expect(
      NativePropertyValue.text(type: "markdown", value: "Fish &amp; chips<br>next")
        == "Fish & chips next")
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
