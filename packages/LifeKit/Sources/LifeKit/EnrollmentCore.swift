import Foundation
import JavaScriptCore

/// Pure generated policies run without installing SQL, HTTP, clocks or storage.
@MainActor
final class EnrollmentCore {
  private let runtime: LifeCoreRuntime
  private var nextID = 0
  private var pending: [Int: CheckedContinuation<String, Error>] = [:]

  init() throws {
    runtime = try LifeCoreRuntime()
    guard
      runtime.context.objectForKeyedSubscript("LifeNative")?.forProperty("contractHash")?.toString()
        == CoreContract.hash
    else {
      throw WorkspaceError(
        message: "Core contract does not match the bundled runtime.", violations: [])
    }
    let finish: @convention(block) (Int, String) -> Void = { [weak self] id, json in
      self?.pending.removeValue(forKey: id)?.resume(returning: json)
    }
    runtime.context.setObject(finish, forKeyedSubscript: "__lifeFinish" as NSString)
  }

  func request<R: CoreRequest>(_ request: R) async throws -> R.Response {
    let arguments = String(decoding: try JSONEncoder().encode(request.arguments), as: UTF8.self)
    let json: String = try await withCheckedThrowingContinuation { continuation in
      nextID += 1
      let id = nextID
      pending[id] = continuation
      runtime.context.exception = nil
      runtime.context.objectForKeyedSubscript("LifeNative")?.invokeMethod(
        "request", withArguments: [id, R.method, arguments])
      if runtime.context.exception != nil {
        pending.removeValue(forKey: id)?.resume(
          throwing: WorkspaceError(message: "Device policy could not run.", violations: []))
      }
    }
    let data = Data(json.utf8)
    if let failure = try JSONDecoder().decode(PolicyFailure.self, from: data).error {
      throw WorkspaceError(message: failure, violations: [])
    }
    return try JSONDecoder().decode(PolicyValue<R.Response>.self, from: data).value
  }

  func policy(fingerprint: String) async throws -> CoreEnrollmentPolicy {
    try await request(
      CoreRequests.EnrollmentApproval(
        CoreEnrollmentApprovalArgs(fingerprint: fingerprint, name: "Life UI"))
    ).policy
  }
}

private struct PolicyFailure: Decodable { let error: String? }
private struct PolicyValue<Value: Decodable>: Decodable { let value: Value }
