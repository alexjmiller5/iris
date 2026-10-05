import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

private final class EnrollmentFixtureBundle: NSObject {}

@MainActor
struct EnrollmentPolicyTests {
  @Test(arguments: 0..<58)
  func canonicalPolicyRunsInJavaScriptCoreWithoutDatabaseOrTransport(index: Int) async throws {
    #if SWIFT_PACKAGE
      let bundle = Bundle.module
    #else
      let bundle = Bundle(for: EnrollmentFixtureBundle.self)
    #endif
    let url = try #require(
      bundle.url(forResource: "enrollment-policy", withExtension: "json", subdirectory: "Fixtures")
        ?? bundle.url(forResource: "enrollment-policy", withExtension: "json"))
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    #expect(fixture.cases.count == 58)
    let entry = fixture.cases[index]
    let runtime = try LifeCoreRuntime()
    let arguments = String(decoding: try JSONEncoder().encode(entry.args), as: UTF8.self)
    let reply: String = await withCheckedContinuation { continuation in
      let finish: @convention(block) (Int, String) -> Void = { _, result in
        continuation.resume(returning: result)
      }
      runtime.context.setObject(finish, forKeyedSubscript: "__lifeFinish" as NSString)
      runtime.context.objectForKeyedSubscript("LifeNative")?.invokeMethod(
        "request", withArguments: [1, entry.operation, arguments])
    }
    #expect(runtime.context.exception == nil, "\(entry.name)")
    let actual = try JSONDecoder().decode([String: JSONValue].self, from: Data(reply.utf8))
    if let failure = entry.error {
      #expect(actual["error"] == .string(failure), "\(entry.name): \(reply)")
    } else {
      #expect(actual["error"] == nil, "\(entry.name): \(reply)")
      #expect(actual["value"] == entry.want, "\(entry.name): \(reply)")
    }
  }

  private struct Fixture: Decodable {
    let cases: [Entry]
  }
  private struct Entry: Decodable {
    let name: String
    let operation: String
    let args: JSONValue
    let error: String?
    let want: JSONValue?
  }
}
