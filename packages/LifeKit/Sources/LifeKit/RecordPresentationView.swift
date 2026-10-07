import SwiftUI

struct RecordPresentationView: View {
  let model: WorkspaceModel
  let rows: [WorkspaceRow]
  let canAct: Bool
  let onOpen: (WorkspaceRow) -> Void
  @State private var month = ""
  @State private var calendar: CoreCalendarRowsResult?
  @State private var board: CoreBoardRowsResult?
  @State private var failure: String?
  @State private var dragSession = UUID().uuidString
  private var definition: CoreViewPresentation { model.viewPresentation }
  private var fields: [CatalogField] { model.properties.map(CatalogField.init) }
  private var byID: [Data: WorkspaceRow] {
    Dictionary(uniqueKeysWithValues: rows.map { (Data($0.id.utf8), $0) })
  }
  private var key: [Data] {
    ([
      month, model.viewTimeZone, String(model.viewDayStartMinutes),
      String(model.workspaceGeneration), model.table ?? "",
      String(data: (try? JSONEncoder().encode(model.properties)) ?? Data(), encoding: .utf8) ?? "",
      String(data: (try? JSONEncoder().encode(definition)) ?? Data(), encoding: .utf8) ?? "",
    ]
      + rows.flatMap { [$0.id, $0.record["updated_at"]?.text ?? ""] }).map { Data($0.utf8) }
  }
  private var group: CatalogField? { fields.first { $0.id == definition.groupColumn } }
  private var canMove: Bool {
    canAct && model.canWrite && !model.trash && group?.property["immutable"]?.isTrue != true
      && group?.property["derived_by"]?.text.nonempty == nil
      && group?.property["deprecated"]?.isTrue != true
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let failure {
          Text(failure).foregroundStyle(.red).accessibilityIdentifier("presentation-error")
        }
        if definition.kind == "gallery" {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
            ForEach(rows, id: \.byteExactID) { row in
              VStack(alignment: .leading, spacing: 12) {
                if let field = fields.first(where: { $0.id == definition.coverColumn }) {
                  if let reference = ImageReference.cover(
                    type: field.type, value: row.record[field.id]?.text ?? "")
                  {
                    NativeImagePreview(
                      reference: reference, label: row.label, transport: model.imageTransport,
                      size: 160)
                  } else {
                    Label("No cover", systemImage: "photo").frame(height: 160)
                      .foregroundStyle(.secondary)
                  }
                }
                Button(row.label) { onOpen(row) }.buttonStyle(.plain).font(.headline)
              }.padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            }
          }.accessibilityIdentifier("gallery-view")
        } else if definition.kind == "calendar" {
          HStack {
            Button {
              shiftMonth(-1)
            } label: {
              Image(systemName: "chevron.left")
            }.accessibilityLabel("Previous month")
            Text(month).font(.headline)
            Button {
              shiftMonth(1)
            } label: {
              Image(systemName: "chevron.right")
            }.accessibilityLabel("Next month")
          }
          if let calendar {
            // One row per day stays readable at large text sizes and on a phone.
            // Records spanning days appear in every matching day from shared core.
            ForEach(calendar.days, id: \.date) { day in
              VStack(alignment: .leading, spacing: 8) {
                Text(day.date).font(.headline)
                if day.rowIds.isEmpty { Text("No records").foregroundStyle(.secondary) }
                ForEach(day.rowIds.map { Data($0.utf8) }, id: \.self) { id in
                  if let row = byID[id] { Button(row.label) { onOpen(row) } }
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
              Divider()
            }
            if !calendar.undated.isEmpty {
              Text("Unscheduled or invalid dates").font(.headline)
              ForEach(calendar.undated.map { Data($0.utf8) }, id: \.self) { id in
                if let row = byID[id] { Button(row.label) { onOpen(row) } }
              }
            }
          }
        } else if let board {
          ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
              ForEach(Array(board.columns.enumerated()), id: \.offset) { item in
                boardColumn(item.element, choices: board.columns)
              }
            }
          }.accessibilityIdentifier("board-view")
        }
        Text("Showing loaded records.").font(.caption).foregroundStyle(.secondary)
        if model.canLoadMore {
          Button("Load more") { Task { await model.reload(more: true) } }.disabled(model.loading)
        }
      }.padding()
    }
    .task(id: key) {
      if month.isEmpty {
        month =
          (try? calendarContext(
            timeZone: model.viewTimeZone, dayStartMinutes: model.viewDayStartMinutes
          ).today.prefix(7)).map(String.init)
          ?? ""
        return
      }
      failure = nil
      calendar = nil
      board = nil
      do {
        guard let workspace = model.client else { return }
        if definition.kind == "calendar", let column = definition.dateColumn {
          let days = try calendarMonth(
            month, timeZone: model.viewTimeZone, dayStartMinutes: model.viewDayStartMinutes)
          let result = try await workspace.calendarRows(
            CoreCalendarRowsArgs(
              rows: rows.map(\.record), dateColumn: column, endDateColumn: definition.endDateColumn,
              days: days))
          guard !Task.isCancelled else { return }
          calendar = result
        } else if definition.kind == "board", let column = definition.groupColumn {
          let choices = try await workspace.options(table: model.table ?? "", column: column)
          let result = try await workspace.boardRows(
            CoreBoardRowsArgs(
              rows: rows.map(\.record), column: column, options: (group?.options ?? []) + choices))
          guard !Task.isCancelled else { return }
          board = result
        }
      } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
  }
  private func boardColumn(_ column: CoreBoardColumnRows, choices: [CoreBoardColumnRows])
    -> some View
  {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(column.value ?? "No value") (\(column.rowIds.count))").font(.headline)
      ForEach(column.rowIds.map { Data($0.utf8) }, id: \.self) { id in
        if let row = byID[id] { boardCard(row, choices: choices) }
      }
      Spacer(minLength: 30)
    }.padding(12).frame(width: 250, alignment: .topLeading)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      .dropDestination(for: String.self) { values, _ in
        guard canMove, values.count == 1, let token = values.first,
          token.hasPrefix(dragSession + ":"),
          let row = byID[Data(token.dropFirst(dragSession.count + 1).utf8)]
        else { return false }
        move(row, to: column.value)
        return true
      }
  }
  private func boardCard(_ row: WorkspaceRow, choices: [CoreBoardColumnRows]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(row.label) { onOpen(row) }.buttonStyle(.plain)
      Menu("Move") {
        ForEach(Array(choices.enumerated()), id: \.offset) { item in
          Button(item.element.value ?? "No value") { move(row, to: item.element.value) }
        }
      }.disabled(!canMove)
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(.background, in: RoundedRectangle(cornerRadius: 8))
      .draggable(dragSession + ":" + row.id)
  }
  private func move(_ row: WorkspaceRow, to value: String?) {
    guard canMove, let column = definition.groupColumn else { return }
    let context = model.editingContext
    Task {
      do {
        _ = try await model.save(
          ["id": .string(row.id), column: value.map(JSONValue.string) ?? .null],
          original: row.record, context: context)
      } catch { failure = error.localizedDescription }
    }
  }
  private func shiftMonth(_ delta: Int) {
    let parts = month.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 2 else { return }
    let count = parts[0] * 12 + parts[1] - 1 + delta
    month = String(format: "%04d-%02d", count / 12, count % 12 + 1)
  }
}
