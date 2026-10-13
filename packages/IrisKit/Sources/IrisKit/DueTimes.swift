import Foundation

/// Specific due times of `date_or_datetime` values: a floating local time or a UTC
/// instant. Date-only values are due all day and never have one.
enum DueTimes {
  /// The instant a stored value comes due in the zone (empty: this device's), or nil.
  static func instant(_ value: String, timeZone: String?) -> Date? {
    if let local = localTimeInstant(value, timeZone: timeZone) { return local }
    return NativeDateValue.parse(value, kind: .datetime)
  }

  /// The columns a definition compares with relative Now.
  static func nowColumns(_ definition: CoreSavedViewDefinition) -> [String] {
    var seen: [String] = []
    for filter in (definition.filters ?? []) + (definition.groups ?? []).flatMap(\.filters)
    where filter.relative == .now && !seen.contains(filter.column) {
      seen.append(filter.column)
    }
    return seen
  }

  /// When the next timed value a relative-Now filter compares with comes due later in
  /// the current policy day; the day boundary already refreshes the view after that.
  static func nextDue(
    workspace: NativeWorkspace, table: String, columns: [String], timeZone: String,
    dayStartMinutes: Int, now: Date = Date()
  ) async throws -> Date? {
    let calendar = try calendarContext(
      timeZone: timeZone, now: now, dayStartMinutes: dayStartMinutes)
    var next: Date?
    for column in columns {
      // ponytail: the 200 earliest by text; local times and instants interleave loosely,
      // so a day with more timed values could refresh a little late.
      let rows = try await workspace.rows(
        view: CoreView(
          table: table, columns: ["id", column],
          filters: [
            CoreFilter(column: column, op: .gt, relative: .now),
            CoreFilter(column: column, op: .eq, relative: .today),
          ], sort: [CoreSort(column: column, direction: .asc)], limit: 200, calendar: calendar))
      for row in rows {
        guard let value = row.record[column]?.text,
          let at = instant(value, timeZone: timeZone), at > now
        else { continue }
        next = min(next ?? at, at)
      }
    }
    return next
  }
}

/// A row of a saved view that comes due at a specific time.
struct UpcomingDue: Equatable, Sendable {
  let rowID: String
  let label: String
  let value: String
  let at: Date
}

extension DueTimes {
  /// The column whose specific times a view is about: its first relative date filter,
  /// else its calendar date. Nil when the view has neither.
  static func dueColumn(_ definition: CoreSavedViewDefinition) -> String? {
    ((definition.filters ?? []) + (definition.groups ?? []).flatMap(\.filters))
      .first { $0.relative != nil }?.column ?? definition.presentation?.dateColumn
  }

  /// Rows the view selects apart from its relative filters on `column`, whose value in
  /// that column is a specific time after `now` and within `days` policy days, nearest
  /// first. Date-only values never come due at a time.
  static func upcoming(
    workspace: NativeWorkspace, table: String, definition: CoreSavedViewDefinition,
    column: String, now: Date = Date(), days: Int = 2, limit: Int = 200
  ) async throws -> [UpcomingDue] {
    let timeZone = definition.timeZone ?? ""
    let calendar = try calendarContext(
      timeZone: timeZone, now: now, dayStartMinutes: definition.dayStartMinutes ?? 0)
    let keep = { (filter: CoreFilter) in filter.column != column || filter.relative == nil }
    let groups = (definition.groups ?? []).compactMap { group -> CoreFilterGroup? in
      let filters = group.filters.filter(keep)
      return filters.isEmpty ? nil : CoreFilterGroup(match: group.match, filters: filters)
    }
    // Text order bounds the window: everything stored before the day after the horizon.
    let horizon = NativeDateValue.format(
      (NativeDateValue.parse(calendar.today, kind: .date) ?? now)
        .addingTimeInterval(Double(days + 1) * 86400), kind: .date)
    let rows = try await workspace.rows(
      view: CoreView(
        table: table,
        filters: (definition.filters ?? []).filter(keep) + [
          CoreFilter(column: column, op: .gt, relative: .now),
          CoreFilter(column: column, op: .lt, value: .string(horizon)),
        ], sort: [CoreSort(column: column, direction: .asc)], limit: limit,
        groups: groups.isEmpty ? nil : groups, calendar: calendar))
    return rows.compactMap { row in
      guard let value = row.record[column]?.text, let at = instant(value, timeZone: timeZone),
        at > now
      else { return nil }
      return UpcomingDue(rowID: row.id, label: row.label, value: value, at: at)
    }.sorted { $0.at < $1.at }
  }
}
