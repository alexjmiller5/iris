import Foundation
import JavaScriptCore

/// A supplied value snapshot. This module never acquires records or changes a workspace.
struct RecordExportSnapshot: Encodable, Sendable {
  enum Scope: String, Encodable, Sendable { case loaded, view, table }
  struct Completeness: Encodable, Sendable {
    enum Rows: String, Encodable, Sendable { case complete, partial, unknown }
    enum Columns: String, Encodable, Sendable { case full, projected }
    var rows: Rows
    var columns: Columns
    var reasons: [String]
  }
  struct Acquisition: Encodable, Sendable {
    enum Source: String, Encodable, Sendable {
      case localReplica = "local-replica"
      case onlinePage = "online-page"
    }
    enum Freshness: String, Encodable, Sendable { case unknown }
    var source: Source
    var capturedAt: String
    var freshness: Freshness
    var lastSync: String?
    var skippedTables: [String]
    var pendingUiEdits: Int?
    var rejectedEdits: Int?

    private enum CodingKeys: String, CodingKey {
      case source, capturedAt, freshness, lastSync, skippedTables, pendingUiEdits, rejectedEdits
    }
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(source, forKey: .source)
      try container.encode(capturedAt, forKey: .capturedAt)
      try container.encode(freshness, forKey: .freshness)
      // Unknown status is an explicit null, not an omitted field or invented zero.
      try container.encode(lastSync, forKey: .lastSync)
      try container.encode(skippedTables, forKey: .skippedTables)
      try container.encode(pendingUiEdits, forKey: .pendingUiEdits)
      try container.encode(rejectedEdits, forKey: .rejectedEdits)
    }
  }
  var table: String
  var properties: [WorkspaceRecord]
  var rows: [WorkspaceRecord]
  var scope: Scope
  var completeness: Completeness
  var acquisition: Acquisition
}

enum RecordExportFormat: String, Encodable, CaseIterable, Sendable {
  case json, csv
}

struct RecordExportFile: Decodable, Sendable {
  let filename: String
  let mimeType: String
  let data: Data

  private enum CodingKeys: String, CodingKey { case filename, mimeType, text }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    filename = try container.decode(String.self, forKey: .filename)
    mimeType = try container.decode(String.self, forKey: .mimeType)
    data = Data(try container.decode(String.self, forKey: .text).utf8)
  }
}

struct RecordExportArtifact: Decodable, Sendable {
  let rowCount: Int
  let files: [RecordExportFile]
}

enum RecordExportError: Error, LocalizedError {
  case unavailable, invalidResult
  case javaScript(String)
  var errorDescription: String? {
    switch self {
    case .unavailable: "The record export serializer is unavailable."
    case .invalidResult: "The record export serializer returned an invalid file."
    case .javaScript(let message): message
    }
  }
}

/// Each operation owns a fresh offline context on a detached task. JS values never cross actors.
struct RecordExportSerializer: Sendable {
  private let script: String?
  init() { script = nil }
  init(script: String) { self.script = script }

  private struct Options: Encodable {
    let format: RecordExportFormat
    let selectedIds: [String]?
  }

  func serialize(
    _ snapshot: RecordExportSnapshot, format: RecordExportFormat, selectedIDs: [String]? = nil
  ) async throws -> RecordExportArtifact {
    try Task.checkCancellation()
    let script = script
    let work = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      precondition(!Thread.isMainThread)
      let source: String
      if let script {
        source = script
      } else {
        guard let url = Bundle.module.url(forResource: "record-export", withExtension: "js") else {
          throw RecordExportError.unavailable
        }
        source = try String(contentsOf: url, encoding: .utf8)
      }
      let encoder = JSONEncoder()
      let input = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
      let options = String(
        decoding: try encoder.encode(Options(format: format, selectedIds: selectedIDs)),
        as: UTF8.self)
      guard let context = JSContext() else { throw RecordExportError.unavailable }
      defer { context.exception = nil }
      context.evaluateScript(source)
      if let exception = context.exception {
        throw RecordExportError.javaScript(exception.toString())
      }
      guard
        let serialize = context.objectForKeyedSubscript("IrisRecordExport")?
          .forProperty("serialize"), serialize.isObject
      else { throw RecordExportError.unavailable }
      // Call arguments are JSON strings, never executable source containing record values.
      let result = serialize.call(withArguments: [input, options])
      if let exception = context.exception {
        throw RecordExportError.javaScript(exception.toString())
      }
      guard let result, result.isString, let json = result.toString() else {
        throw RecordExportError.invalidResult
      }
      let artifact = try JSONDecoder().decode(RecordExportArtifact.self, from: Data(json.utf8))
      guard artifact.rowCount >= 0, artifact.files.count == (format == .csv ? 2 : 1) else {
        throw RecordExportError.invalidResult
      }
      try Task.checkCancellation()
      return artifact
    }
    return try await withTaskCancellationHandler {
      let artifact = try await work.value
      try Task.checkCancellation()
      return artifact
    } onCancel: {
      work.cancel()
    }
  }
}

// Swift String equality normalizes Unicode; catalog metadata must retain exact bytes.
func recordExportCatalogsMatch(_ lhs: WorkspaceCatalog?, _ rhs: WorkspaceCatalog?) -> Bool {
  switch (lhs, rhs) {
  case (nil, nil): return true
  case (let lhs?, let rhs?):
    return recordExportValuesMatch(
      .array(lhs.tables.map(CoreJSONValue.object)), .array(rhs.tables.map(CoreJSONValue.object)))
      && recordExportValuesMatch(
        .array(lhs.properties.map(CoreJSONValue.object)),
        .array(rhs.properties.map(CoreJSONValue.object)))
      && recordExportValuesMatch(
        .array(lhs.rules.map(CoreJSONValue.object)), .array(rhs.rules.map(CoreJSONValue.object)))
  default: return false
  }
}

private func recordExportValuesMatch(_ lhs: CoreJSONValue, _ rhs: CoreJSONValue) -> Bool {
  switch (lhs, rhs) {
  case (.null, .null): return true
  case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
  case (.number(let lhs), .number(let rhs)): return lhs.bitPattern == rhs.bitPattern
  case (.string(let lhs), .string(let rhs)): return lhs.utf8.elementsEqual(rhs.utf8)
  case (.array(let lhs), .array(let rhs)):
    return lhs.elementsEqual(rhs, by: recordExportValuesMatch)
  case (.object(let lhs), .object(let rhs)):
    return lhs.count == rhs.count
      && lhs.allSatisfy { key, value in
        guard let index = rhs.index(forKey: key), key.utf8.elementsEqual(rhs[index].key.utf8) else {
          return false
        }
        return recordExportValuesMatch(value, rhs[index].value)
      }
  default: return false
  }
}
