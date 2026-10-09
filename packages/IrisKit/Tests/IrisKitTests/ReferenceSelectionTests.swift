import Foundation
import Testing

@testable import IrisKit

struct ReferenceSelectionTests {
  @Test func undoingAChoicePreservesTheOriginalRepresentation() throws {
    let original = #"[ "unknown", "existing" ]"#
    var selection = try ReferenceSelection(value: original, multiple: true)
    #expect(selection.value == original)
    selection.choose("new")
    selection.choose("new")
    #expect(selection.value == original)
  }

  @Test func choosingAnotherReferencePreservesUnknownSelectionsAndOrder() throws {
    var selection = try ReferenceSelection(value: #"["missing","existing"]"#, multiple: true)
    selection.choose("new")
    #expect(selection.ids == ["missing", "existing", "new"])
    #expect(
      try JSONDecoder().decode([String].self, from: Data(selection.value.utf8)) == selection.ids)
    selection.choose("existing")
    #expect(selection.ids == ["missing", "new"])
    selection.remove("missing")
    #expect(selection.ids == ["new"])
  }

  @Test func singleReferenceReplacesOnlyOnAnExplicitChoice() throws {
    var selection = try ReferenceSelection(value: "unavailable-id", multiple: false)
    #expect(selection.value == "unavailable-id")
    selection.choose("chosen-id")
    #expect(selection.ids == ["chosen-id"])
    #expect(selection.value == "chosen-id")
    selection.remove("chosen-id")
    #expect(selection.value == "")
  }

  @Test func malformedMultiReferenceCannotBecomeAnEmptySelection() throws {
    for value in [#"["keep",7]"#, #"{"id":"keep"}"#, "not json"] {
      #expect(throws: Error.self) { try ReferenceSelection(value: value, multiple: true) }
    }
    #expect(try ReferenceSelection(value: "", multiple: true).ids.isEmpty)
    #expect(try ReferenceSelection(value: "[]", multiple: true).value == "[]")
  }
}
