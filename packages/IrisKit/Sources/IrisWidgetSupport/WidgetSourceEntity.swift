import AppIntents
import Foundation
import IrisExtensionSupport

public struct WidgetSourceEntity: AppEntity {
  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Widget source"
  public static let defaultQuery = WidgetSourceQuery()
  public let id: String
  @Property(title: "Title") public var title: String
  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)")
  }

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

/// Configuration reads authorized publication metadata only. It never opens the
/// writer, searches records, accesses credentials or creates an implicit source.
public struct WidgetSourceQuery: EntityStringQuery {
  private let library: WidgetLibrary?
  private let calendarOnly: Bool
  public init() { self.init(library: WidgetLibrary.installed()) }
  public init(library: WidgetLibrary?) {
    self.library = library
    calendarOnly = false
  }
  fileprivate init(library: WidgetLibrary?, calendarOnly: Bool) {
    self.library = library
    self.calendarOnly = calendarOnly
  }

  public func suggestedEntities() async throws -> [WidgetSourceEntity] {
    try library?.sources().filter {
      $0.kind == .list && (!calendarOnly || $0.usesCalendar)
    }.map { WidgetSourceEntity(id: $0.id, title: $0.title) } ?? []
  }

  public func entities(for identifiers: [String]) async throws -> [WidgetSourceEntity] {
    guard identifiers.count <= 2048 else {
      throw ExtensionReadError(message: "Choose an available widget source.")
    }
    let wanted = Set(identifiers.map { Data($0.utf8) })
    return try await suggestedEntities().filter { wanted.contains(Data($0.id.utf8)) }
  }

  public func entities(matching string: String) async throws -> [WidgetSourceEntity] {
    guard string.utf8.count <= 1024 else { return [] }
    return try await suggestedEntities().filter { $0.title.localizedStandardContains(string) }
  }
}

public struct CalendarWidgetSourceQuery: EntityQuery {
  private let query: WidgetSourceQuery
  public init() { self.init(library: WidgetLibrary.installed()) }
  public init(library: WidgetLibrary?) {
    query = WidgetSourceQuery(library: library, calendarOnly: true)
  }
  public func suggestedEntities() async throws -> [WidgetSourceEntity] {
    try await query.suggestedEntities()
  }
  public func entities(for identifiers: [String]) async throws -> [WidgetSourceEntity] {
    try await query.entities(for: identifiers)
  }
}
