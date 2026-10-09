#if os(iOS)
  import AppIntents
  import Foundation
  import Observation

  /// Bridges foreground system intents into the running app. Intents only post a
  /// request; the workspace view applies it through the ordinary pending-link flow.
  @Observable @MainActor public final class NativeIntentInbox {
    public static let shared = NativeIntentInbox()
    private(set) var openTodayRequests = 0
    private(set) var link: (url: URL, revision: Int)?
    var lookup: ((String) async throws -> [LookupHit])?

    func requestOpenToday() { openTodayRequests += 1 }
    func open(_ url: URL) { link = (url, (link?.revision ?? 0) + 1) }

    /// A Shortcut can launch the app before a workspace is open; wait briefly for one.
    func lookUp(_ text: String) async throws -> [LookupHit] {
      // ponytail: 10 s poll for the opened workspace; an explicit readiness signal if this flakes.
      for _ in 0..<100 where lookup == nil { try await Task.sleep(for: .milliseconds(100)) }
      guard let lookup else {
        throw WorkspaceError(message: "Open a workspace in Iris first.", violations: [])
      }
      return try await lookup(text)
    }
  }

  public struct OpenTodayIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Today"
    public static let description = IntentDescription(
      "Open the daily view chosen in Iris's Widgets and Search settings.")
    public static let openAppWhenRun = true
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult {
      NativeIntentInbox.shared.requestOpenToday()
      return .result()
    }
  }

  public struct LookUpRecordIntent: AppIntent {
    public static let title: LocalizedStringResource = "Look Up"
    public static let description = IntentDescription(
      "Find records by title in the lookup table chosen in Iris. A single match opens.")
    public static let openAppWhenRun = true
    @Parameter(title: "Name") public var name: String
    public static var parameterSummary: some ParameterSummary { Summary("Look up \(\.$name)") }
    public init() {}
    @MainActor public func perform() async throws
      -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog
    {
      let hits = try await NativeIntentInbox.shared.lookUp(name)
      if hits.count == 1 { NativeIntentInbox.shared.open(hits[0].url) }
      let titles = hits.map(\.title)
      return .result(
        value: titles,
        dialog: IntentDialog(
          stringLiteral: titles.isEmpty ? "No matching records." : titles.joined(separator: ", ")))
    }
  }

#endif
