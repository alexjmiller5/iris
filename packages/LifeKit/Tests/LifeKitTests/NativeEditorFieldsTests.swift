import Testing

@testable import LifeKit

struct NativeEditorFieldsTests {
  private let fields = [
    CatalogField(property: ["col": .string("title"), "required": .bool(true)]),
    CatalogField(property: ["col": .string("summary"), "required": .bool(true)]),
    CatalogField(property: ["col": .string("detail")]),
  ]

  @Test func defaultLayoutShowsEveryField() {
    let layout = NativeEditorFields(
      fields: fields, visibleColumns: nil, titleColumn: "title", isNew: false, invalidColumns: [])
    #expect(layout.primary.map(\.id) == ["title", "summary", "detail"])
    #expect(layout.additional.isEmpty)
  }

  @Test func titleIsPinnedAndHiddenFieldsRemainAvailable() {
    let layout = NativeEditorFields(
      fields: fields, visibleColumns: [], titleColumn: "title", isNew: false, invalidColumns: [])
    #expect(layout.primary.map(\.id) == ["title"])
    #expect(layout.additional.map(\.id) == ["summary", "detail"])
  }

  @Test func newRequiredAndInvalidFieldsCannotBeHidden() {
    let layout = NativeEditorFields(
      fields: fields, visibleColumns: ["title"], titleColumn: "title", isNew: true,
      invalidColumns: ["detail"])
    #expect(layout.primary.map(\.id) == ["title", "summary", "detail"])
    #expect(layout.additional.isEmpty)
  }

  @Test func emptyPropertiesCollapseWithoutHidingFalseZeroOrInvalidSource() {
    let fields = [
      CatalogField(property: ["col": .string("title")]),
      CatalogField(property: ["col": .string("missing")]),
      CatalogField(property: ["col": .string("blank")]),
      CatalogField(property: ["col": .string("zero"), "type": .string("number")]),
      CatalogField(property: ["col": .string("false"), "type": .string("bool")]),
      CatalogField(property: ["col": .string("choices"), "type": .string("multi_select")]),
      CatalogField(property: ["col": .string("broken"), "type": .string("multi_ref")]),
      CatalogField(property: ["col": .string("json"), "type": .string("json")]),
    ]
    let empty = NativeEditorFields.emptyColumns(
      fields: fields,
      values: [
        "blank": " \n", "zero": "0", "false": "false", "choices": "[ ]",
        "broken": "[", "json": "[]",
      ])
    let layout = NativeEditorFields(
      fields: fields, visibleColumns: nil, titleColumn: "title", isNew: false,
      invalidColumns: ["missing"], emptyColumns: empty)
    #expect(layout.primary.map(\.id) == ["title", "missing", "zero", "false", "broken", "json"])
    #expect(layout.empty.map(\.id) == ["blank", "choices"])
    #expect(layout.additional.isEmpty)

    let selected = NativeEditorFields(
      fields: fields, visibleColumns: ["title", "blank"], titleColumn: "title", isNew: false,
      invalidColumns: [], emptyColumns: empty)
    #expect(selected.primary.map(\.id) == ["title"])
    #expect(selected.empty.map(\.id) == ["blank"])
    #expect(
      selected.additional.map(\.id) == ["missing", "zero", "false", "choices", "broken", "json"])
  }
}
