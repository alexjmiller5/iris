import Foundation
import Testing

@testable import LifeKit

@MainActor
struct RecordExportPresentationTests {

  @Test func selectedExportRetainsExactIdentityAndSelectionMetadata() async throws {
    let model = RecordExportPresentation(snapshot: exportTestSnapshot(), selectedIDs: ["\u{e9}"])
    let file = try #require(await prepare(model))
    let json = try #require(JSONSerialization.jsonObject(with: file.data) as? [String: Any])
    let rows = try #require(json["rows"] as? [[String: Any]])
    #expect(rows.count == 1)
    #expect((rows.first?["id"] as? String).map { Data($0.utf8) } == Data("\u{e9}".utf8))
    let scope = try #require(json["scope"] as? [String: Any])
    #expect(scope["kind"] as? String == "selection")
  }

  private func presentation(_ snapshot: RecordExportSnapshot = exportTestSnapshot()) throws
    -> RecordExportPresentation
  {
    let serializer = try exportTestSerializer()
    return RecordExportPresentation(snapshot: snapshot) {
      try await serializer.serialize($0, format: $1)
    }
  }

  private func prepare(_ model: RecordExportPresentation) async -> RecordExportFile? {
    var file: RecordExportFile?
    let work = model.startPreparation { file = $0 }
    await work?.value
    return file
  }

  @Test(arguments: [false, true])
  func obsoletePreparationCannotClearNewerOperation(fails: Bool) async throws {
    let serializer = try exportTestSerializer()
    let older = ExportResultGate()
    let newer = ExportResultGate()
    let model = RecordExportPresentation(snapshot: exportTestSnapshot()) { snapshot, format in
      let artifact = try await serializer.serialize(snapshot, format: format)
      if format == .csv {
        await older.hold()
        if fails { throw CocoaError(.fileWriteNoPermission) }
      } else {
        await newer.hold()
      }
      return artifact
    }
    var published = false
    model.format = .csv
    let first = model.startPreparation { _ in published = true }
    await older.waitUntilEntered()
    model.cancelPreparation()
    model.format = .json
    let second = model.startPreparation { _ in published = true }
    await newer.waitUntilEntered()

    await older.release()
    await first?.value
    #expect(model.preparing)
    #expect(!published)
    #expect(model.metadata == nil)
    #expect(model.error == nil)

    // A's defer must retain B's task handle so dismissing still cancels B.
    model.cancelPreparation()
    await newer.release()
    await second?.value
    let newerWasCancelled = await newer.wasCancelled
    #expect(newerWasCancelled)
    #expect(!model.preparing)
    #expect(!published)
    #expect(model.metadata == nil)
    #expect(model.error == nil)
  }

  @Test(arguments: [false, true])
  func dismissedPreparationIgnoresLateFilesAndFailures(fails: Bool) async throws {
    let serializer = try exportTestSerializer()
    let gate = ExportResultGate()
    let model = RecordExportPresentation(snapshot: exportTestSnapshot()) { snapshot, format in
      let artifact = try await serializer.serialize(snapshot, format: format)
      await gate.hold()
      if fails { throw CocoaError(.fileWriteNoPermission) }
      return artifact
    }
    model.format = .csv
    var published = false
    let work = model.startPreparation { _ in published = true }
    await gate.waitUntilEntered()
    model.cancelPreparation()
    await gate.release()
    await work?.value
    #expect(!published)
    #expect(model.metadata == nil)
    #expect(model.error == nil)
    #expect(!model.preparing)
  }

  // The button queues work and dismissal cancels it before the actor yields.
  // cancelPreparation must prevent a file from reaching the dismissed presenter.
  @Test func queuedSaveCannotPublishAfterDismissal() async throws {
    let model = try presentation()
    var file: RecordExportFile?
    let queuedAction = model.startPreparation { file = $0 }
    model.cancelPreparation()
    await queuedAction?.value
    #expect(file == nil)
    #expect(model.metadata == nil)
    #expect(model.error == nil)
  }

  @Test func csvMetadataRetainsTheOriginalSnapshotAfterCallerChanges() async throws {
    var source = exportTestSnapshot()
    let model = try presentation(source)
    source.table = "another_table"
    source.rows = []
    model.format = .csv
    let file = try #require(await prepare(model))
    #expect(file.filename == "entries-loaded-unknown-full.csv")
    let metadata = try #require(model.metadata)
    let object = try #require(JSONSerialization.jsonObject(with: metadata.data) as? [String: Any])
    #expect(object["table"] as? String == "entries")
    #expect((object["scope"] as? [String: Any])?["rowCount"] as? Int == 2)
    #expect(!model.preparing)
  }

  @Test func saveFailureAndCancellationKeepTheCaptureUsableForRetry() async throws {
    let model = try presentation()
    let first = try #require(await prepare(model))
    model.saveCompleted(.failure(CocoaError(.fileWriteNoPermission)))
    #expect(model.error != nil)
    let retry = try #require(await prepare(model))
    #expect(retry.data == first.data)
    #expect(model.error == nil)
    model.saveCompleted(.failure(CocoaError(.userCancelled)))
    #expect(model.error == nil)
    #expect(model.snapshot.rows.count == 2)
  }

  @Test func changingToJSONClearsOldCSVMetadataAfterPreparing() async throws {
    let model = try presentation()
    model.format = .csv
    _ = try #require(await prepare(model))
    #expect(model.metadata != nil)
    model.format = .json
    let file = try #require(await prepare(model))
    #expect(file.mimeType == "application/json;charset=utf-8")
    #expect(model.metadata == nil)
  }

  @Test func invalidCapturedRowsFailVisiblyWithoutPublishingFiles() async throws {
    var snapshot = exportTestSnapshot()
    snapshot.rows = [["id": .string("one")], ["id": .string("one")]]
    let model = try presentation(snapshot)
    #expect(await prepare(model) == nil)
    #expect(model.error?.contains("identity") == true)
    #expect(model.metadata == nil)
    #expect(!model.preparing)
    #expect(model.snapshot.rows.count == 2)
  }
}

/// Holds an actual serialized artifact so dismissal deterministically precedes completion.
private actor ExportResultGate {
  private(set) var wasCancelled = false
  private var entered = false
  private var arrival: CheckedContinuation<Void, Never>?
  private var completion: CheckedContinuation<Void, Never>?

  func hold() async {
    entered = true
    arrival?.resume()
    arrival = nil
    await withCheckedContinuation { completion = $0 }
    wasCancelled = Task.isCancelled
  }

  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { arrival = $0 } }
  }

  func release() {
    completion?.resume()
    completion = nil
  }
}
