import AppIntents
import Foundation
import LifeExtensionSupport

public struct QuickAddSourceQuery: EntityQuery {
  private let library: WidgetLibrary?
  public init() { library = .installed() }
  public init(library: WidgetLibrary?) { self.library = library }
  public func suggestedEntities() async throws -> [WidgetSourceEntity] {
    try library?.sources().filter { $0.kind == .list && $0.allowsQuickAdd && $0.openURL != nil }
      .map { WidgetSourceEntity(id: $0.id, title: $0.title) } ?? []
  }
  public func entities(for identifiers: [String]) async throws -> [WidgetSourceEntity] {
    guard identifiers.count <= 2048 else { throw QuickAddIntentError.unavailable }
    let wanted = Set(identifiers.map { Data($0.utf8) })
    return try await suggestedEntities().filter { wanted.contains(Data($0.id.utf8)) }
  }
}

public struct QuickAddIntent: AppIntent {
  public static let title: LocalizedStringResource = "Quick Add"
  public static let description = IntentDescription(
    "Prepare a recoverable draft. Save it explicitly in the app.")
  public static let openAppWhenRun = true
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  @Parameter(title: "Table", query: QuickAddSourceQuery()) public var source: WidgetSourceEntity
  @Parameter(title: "Text") public var text: String?
  @Parameter(title: "Text field") public var column: String?
  private var requestID = UUID()
  public static var parameterSummary: some ParameterSummary {
    Summary("Quick Add to \(\.$source)") {
      \.$text
      \.$column
    }
  }
  public init() {}
  public init(source: WidgetSourceEntity) { self.source = source }

  public func perform() async throws -> some IntentResult {
    guard let library = WidgetLibrary.installed(),
      let descriptor = try library.sources().first(where: {
        Data($0.id.utf8) == Data(source.id.utf8)
      }),
      descriptor.allowsQuickAdd, descriptor.kind == .list
    else { throw QuickAddIntentError.unavailable }
    do {
      _ = try library.store(workspaceID: descriptor.workspaceID)
        .stageQuickAdd(id: requestID, sourceID: descriptor.id, text: text, column: column)
    } catch { throw QuickAddIntentError.pending }
    return .result()
  }
}

private enum QuickAddIntentError: Error, CustomLocalizedStringResourceConvertible {
  case unavailable, pending
  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .unavailable: "Choose an enabled writable source in Life UI first."
    case .pending:
      "Open Life UI to finish or retry Quick Add. Text requires an editable text field."
    }
  }
}
