import Foundation
import JavaScriptCore

public typealias Violation = CoreViolation

@MainActor
public final class IrisCoreRuntime {
  let context: JSContext
  private let validator: JSValue

  public enum RuntimeError: Error {
    case unavailable, invalidInput, invalidResult
    case javaScript(String)
  }

  public convenience init() throws {
    guard let url = Bundle.module.url(forResource: "soma-core", withExtension: "js") else {
      throw RuntimeError.unavailable
    }
    try self.init(script: String(contentsOf: url, encoding: .utf8))
  }

  // Only trusted, bundled code belongs here. Row values never become source text.
  init(script: String) throws {
    guard let context = JSContext() else { throw RuntimeError.unavailable }
    self.context = context
    context.evaluateScript(script)
    if let exception = context.exception {
      throw RuntimeError.javaScript(exception.toString())
    }
    guard context.evaluateScript("typeof IrisCore?.validateRow === 'function'")?.toBool() == true,
      let validator = context.objectForKeyedSubscript("IrisCore")?.forProperty("validateRow")
    else { throw RuntimeError.unavailable }
    self.validator = validator
  }

  public func validate(
    propertiesJSON: String, beforeJSON: String? = nil, afterJSON: String
  ) throws -> [Violation] {
    let properties = try JSONSerialization.jsonObject(with: Data(propertiesJSON.utf8))
    guard let fields = properties as? [[String: Any]],
      fields.allSatisfy({ $0["col"] is String })
    else { throw RuntimeError.invalidInput }
    let after = try row(afterJSON)
    let before: Any = try beforeJSON.map(row) ?? NSNull()
    context.exception = nil
    let result = validator.call(withArguments: [fields, before, after])
    if let exception = context.exception {
      throw RuntimeError.javaScript(exception.toString())
    }
    guard let result, result.isArray, let values = result.toArray() else {
      throw RuntimeError.invalidResult
    }
    return try JSONDecoder().decode(
      [Violation].self, from: JSONSerialization.data(withJSONObject: values))
  }

  private func row(_ json: String) throws -> [String: Any] {
    guard let row = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    else { throw RuntimeError.invalidInput }
    return row
  }
}
