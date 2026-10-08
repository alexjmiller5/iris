import CryptoKit
import Foundation

/// Only the enrolled host constructs this uploader. Archive/editor content has no access to it.
struct AttachmentUploader: Sendable {
  let endpoint: String
  let token: String
  let session: URLSession

  func upload(_ entry: StagedAttachment, file: URL) async throws -> AttachmentReceipt {
    guard entry.key.range(of: #"^attachments/[A-Za-z0-9-]+$"#, options: .regularExpression) != nil,
      entry.bytes >= 0, entry.bytes <= 128 * 1024 * 1024,
      let url = URL(string: endpoint + "/v1/files/" + entry.key)
    else { throw AttachmentStore.Failure.invalidMetadata }
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    var digest = SHA256()
    var size = 0
    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
      try Task.checkCancellation()
      guard chunk.count <= entry.bytes - size else { throw AttachmentStore.Failure.integrity }
      size += chunk.count
      digest.update(data: chunk)
    }
    guard size == entry.bytes,
      digest.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256
    else {
      throw AttachmentStore.Failure.integrity
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("*", forHTTPHeaderField: "If-None-Match")
    request.setValue(entry.contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(entry.sha256, forHTTPHeaderField: "X-Content-SHA256")
    let (body, response) = try await session.upload(for: request, fromFile: file)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    if response.statusCode == 412 {
      // A lost response may have committed the create. Authenticate and hash the exact existing object.
      var get = URLRequest(url: url)
      get.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
      let (bytes, reply) = try await session.bytes(for: get)
      defer { bytes.task.cancel() }
      guard let reply = reply as? HTTPURLResponse, reply.statusCode == 200,
        reply.mimeType == entry.contentType,
        reply.expectedContentLength < 0 || reply.expectedContentLength == entry.bytes
      else {
        throw AttachmentStore.Failure.integrity
      }
      var hash = SHA256()
      var count = 0
      var chunk = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard count < entry.bytes else { throw AttachmentStore.Failure.integrity }
        count += 1
        chunk.append(byte)
        if chunk.count == 64 * 1024 {
          hash.update(data: chunk)
          chunk.removeAll(keepingCapacity: true)
        }
      }
      hash.update(data: chunk)
      guard count == entry.bytes,
        hash.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256
      else {
        throw AttachmentStore.Failure.integrity
      }
      return AttachmentReceipt(
        key: entry.key, mime: entry.contentType, bytes: count, sha256: entry.sha256)
    }
    guard response.statusCode == 201, body.count <= 64 * 1024,
      response.mimeType == "application/json"
    else { throw URLError(.badServerResponse) }
    let receipt = try JSONDecoder().decode(AttachmentReceipt.self, from: body)
    guard receipt.key.utf8.elementsEqual(entry.key.utf8), receipt.bytes == entry.bytes,
      receipt.mime == entry.contentType, receipt.sha256 == entry.sha256
    else {
      throw AttachmentStore.Failure.integrity
    }
    return receipt
  }
}
