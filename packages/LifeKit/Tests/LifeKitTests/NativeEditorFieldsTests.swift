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
}
