import CryptoKit
import Foundation

struct StagedAttachment: Codable, Identifiable, Sendable {
  enum State: String, Codable, Sendable { case queued, uploading, failed, uploaded }
  let id: String
  let key: String
  let name: String
  let contentType: String
  let bytes: Int
  let sha256: String
  var state: State
  var reference: String { "/v1/files/" + key }
}

struct AttachmentReceipt: Codable, Sendable {
  let key: String
  let mime: String
  let bytes: Int
  let sha256: String
}

/// Private operational outbox. The host supplies workspace-scoped storage and authenticated upload.
actor AttachmentStore {
  enum Failure: Error { case invalidMetadata, tooLarge, integrity }
  let root: URL
  let maximumBytes: Int
  private var uploading = false

  init(root: URL, maximumBytes: Int = 128 * 1024 * 1024) {
    self.root = root
    self.maximumBytes = maximumBytes
  }

  func stage(source: URL, name: String, contentType: String) throws -> StagedAttachment {
    guard maximumBytes > 0, !name.isEmpty, !contentType.isEmpty else {
      throw Failure.invalidMetadata
    }
    let id = UUID().uuidString.lowercased()
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let directory = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root, create: true)
    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      let bytesURL = directory.appendingPathComponent("bytes")
      guard
        FileManager.default.createFile(
          atPath: bytesURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else {
        throw CocoaError(.fileWriteUnknown)
      }
      let input = try FileHandle(forReadingFrom: source)
      defer { try? input.close() }
      let output = try FileHandle(forWritingTo: bytesURL)
      defer { try? output.close() }
      var count = 0
      var digest = SHA256()
      while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
        try Task.checkCancellation()
        guard chunk.count <= maximumBytes - count else { throw Failure.tooLarge }
        count += chunk.count
        digest.update(data: chunk)
        try output.write(contentsOf: chunk)
      }
      try output.synchronize()
      let entry = StagedAttachment(
        id: id, key: "attachments/" + id, name: name, contentType: contentType,
        bytes: count, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
        state: .queued)
      try persist(entry, directory: directory)
      try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent(id))
      return entry
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  func entries() throws -> [StagedAttachment] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { directory in
        let data = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        var entry = try JSONDecoder().decode(StagedAttachment.self, from: data)
        guard UUID(uuidString: entry.id) != nil, entry.id == directory.lastPathComponent,
          entry.key == "attachments/" + entry.id, entry.bytes >= 0, entry.bytes <= maximumBytes,
          entry.sha256.count == 64,
          entry.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
        else {
          throw Failure.invalidMetadata
        }
        if entry.state == .uploading, !uploading {
          entry.state = .queued
          try persist(entry)
        }
        return entry
      }
  }

  func localBytes(for id: String) throws -> Data {
    guard let entry = try entries().first(where: { $0.id == id }) else {
      throw Failure.invalidMetadata
    }
    let url = root.appendingPathComponent(id).appendingPathComponent("bytes")
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard size == entry.bytes else { throw Failure.integrity }
    let data = try Data(contentsOf: url)
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256
    else {
      throw Failure.integrity
    }
    return data
  }

  func uploadPending(
    upload: @Sendable (StagedAttachment, URL) async throws -> AttachmentReceipt
  ) async throws {
    guard !uploading else { return }
    let pending = try entries()
    uploading = true
    defer { uploading = false }
    for var entry in pending where entry.state == .queued || entry.state == .failed {
      if Task.isCancelled { return }
      do {
        _ = try localBytes(for: entry.id)
        entry.state = .uploading
        try persist(entry)
        let receipt = try await upload(
          entry, root.appendingPathComponent(entry.id).appendingPathComponent("bytes"))
        guard receipt.key.utf8.elementsEqual(entry.key.utf8), receipt.bytes == entry.bytes,
          receipt.mime.utf8.elementsEqual(entry.contentType.utf8), receipt.sha256 == entry.sha256
        else {
          throw Failure.integrity
        }
        entry.state = .uploaded
        try persist(entry)
      } catch {
        entry.state = .failed
        try persist(entry)
      }
    }
  }

  private func persist(_ entry: StagedAttachment, directory: URL? = nil) throws {
    let url = (directory ?? root.appendingPathComponent(entry.id)).appendingPathComponent(
      "metadata.json")
    try JSONEncoder().encode(entry).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
