import Foundation
import Testing

@testable import LifeKit

/// Flag quick filters and search status labels come from catalog metadata only.
@MainActor
struct LifecycleLabelTests {
  private func field(_ col: String, _ type: String, _ extra: WorkspaceRecord = [:]) -> CatalogField {
    CatalogField(
      property: ["col": .string(col), "type": .string(type)].merging(extra) { $1 })
  }

  @Test func booleanPairsWithTheOneTextSiblingItsDescriptionNames() {
    let flag = field(
      "flagged", "bool", ["description": .string("Needs a look; the reason is in flag_note.")])
    let base = [field("title", "text"), field("status", "select"), field("flag_note", "text")]
    #expect(CatalogField.flagFilters(base + [flag]).map { [$0.flag.id, $0.reason.id] }
      == [["flagged", "flag_note"]])
    for description in ["Needs a look.", "See flag_note or title.", "Explained by status."] {
      let other = field("flagged", "bool", ["description": .string(description)])
      #expect(CatalogField.flagFilters(base + [other]).isEmpty)
    }
  }

  @Test func flagToggleAddsAndRemovesOnlyItsTrueFilter() {
    let model = WorkspaceModel()
    model.filters = [WorkspaceFilter(column: "status", value: "Open")]
    model.toggleFlag("flagged")
    #expect(model.flagIsOn("flagged"))
    #expect(model.filters.map(\.column) == ["status", "flagged"])
    #expect(model.filters[1].operation == .eq && model.filters[1].value == "true")
    model.filters.append(WorkspaceFilter(column: "flagged", value: "false"))
    model.toggleFlag("flagged")
    #expect(!model.flagIsOn("flagged"))
    #expect(model.filters.map(\.value) == ["Open", "false"])
  }

  @Test func searchHitsCarryTheirLifecycleStatusAndDescription() async {
    let status = field(
      "status", "select",
      ["options": .array([.object(["v": .string("Retired"), "d": .string("No longer in use.")])])])
    let model = QuickFindModel(
      search: { _ in
        [
          CoreSearchHit(table: "items", id: "a", label: "A", excerpt: ""),
          CoreSearchHit(table: "plain", id: "b", label: "B", excerpt: ""),
        ]
      },
      read: { view in
        #expect(view.table == "items")
        return [WorkspaceRow(record: ["id": .string("a"), "status": .string("Retired")], label: "A")]
      }, statusFields: ["items": status])
    model.query = "fixture"
    await model.reload()
    #expect(model.status(of: model.results[0])?.value == "Retired")
    #expect(model.status(of: model.results[0])?.help == "No longer in use.")
    #expect(model.status(of: model.results[1]) == nil)
  }
}
