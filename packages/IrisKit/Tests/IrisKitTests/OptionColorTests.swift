import Foundation
import Testing

@testable import IrisKit

struct OptionColorTests {
  private let status = CatalogField(property: [
    "col": .string("status"), "type": .string("select"),
    "options": .array([
      .object(["v": .string("To Do"), "color": .string("red")]),
      .object(["v": .string("Done")]),
      .object(["v": .string("Odd"), "color": .string("teal")]),
    ]),
  ])

  @Test func fieldsReadPaletteColorsOnly() {
    #expect(status.optionColor("To Do") == "red")
    #expect(status.optionColor("Done") == nil)
    #expect(status.optionColor("Odd") == nil)
    #expect(status.optionColor("Missing") == nil)
  }

  @Test func choiceValuesListSelectAndMultiSelectSource() {
    #expect(NativePropertyValue.choiceValues(type: "select", value: "To Do") == ["To Do"])
    #expect(NativePropertyValue.choiceValues(type: "select", value: "") == nil)
    #expect(
      NativePropertyValue.choiceValues(type: "multi_select", value: #"["A","B"]"#) == ["A", "B"])
    #expect(NativePropertyValue.choiceValues(type: "multi_select", value: #"["A",2]"#) == nil)
    #expect(NativePropertyValue.choiceValues(type: "multi_select", value: "[]") == nil)
    #expect(NativePropertyValue.choiceValues(type: "text", value: "To Do") == nil)
  }

  @Test func newOptionsTakeThePaletteInOrderSkippingDefault() {
    #expect(OptionPalette.names.count == 10)
    #expect(OptionPalette.newColor(index: 0) == "gray")
    #expect(OptionPalette.newColor(index: 8) == "red")
    #expect(OptionPalette.newColor(index: 9) == "gray")
  }

  @Test @MainActor func catalogEditorKeepsAndSavesOptionColors() async throws {
    let workspace = WorkspaceModel()
    await workspace.open(demo: true)
    let context = try #require(workspace.editingContext)
    let editor = CatalogEditorModel(workspace: workspace, context: context)
    let status = try #require(editor.entries.first { $0["col"] == .string("status") })
    editor.select(status)
    #expect(editor.options.map(\.color) == ["yellow", "green"])
    editor.options[0].color = "blue"
    editor.options[1].color = nil
    editor.addOption()
    #expect(editor.options.last?.color == "orange")
    editor.options[2].value = "Archived"
    #expect(editor.dirty)
    // Option keys the editor does not show are submitted as stored, never dropped.
    editor.options[0].other["future"] = .string("kept")
    await editor.save()
    #expect(editor.failure != nil)
    editor.options[0].other = [:]
    await editor.save()
    #expect(editor.failure == nil)
    let saved = workspace.properties.first { $0["col"] == .string("status") }
    let options = CatalogField(property: try #require(saved))
    #expect(options.optionColor("Draft") == "blue")
    #expect(options.optionColor("Ready") == nil)
    #expect(options.optionColor("Archived") == "orange")
    await workspace.close()
  }
}
