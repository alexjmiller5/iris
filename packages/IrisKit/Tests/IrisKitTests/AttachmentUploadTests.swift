import CryptoKit
import Foundation
import Testing

@testable import IrisKit

struct AttachmentUploadTests {
  @Test func uploadsCreateOnlyWithAuthenticatedExactMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("source")
    try Data("upload fixture".utf8).write(to: file)
    let store = AttachmentStore(root: root.appendingPathComponent("outbox"))
    let entry = try await store.stage(source: file, name: "fixture.txt", contentType: "text/plain")
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AttachmentUploadFixture.self]
    let uploader = AttachmentUploader(
      endpoint: "https://upload.invalid/prefix", token: "synthetic",
      session: URLSession(configuration: config))
    let receipt = try await uploader.upload(entry, file: file)
    #expect(receipt.key == entry.key)
    #expect(receipt.bytes == 14)
    #expect(receipt.sha256 == entry.sha256)
  }

  @Test func uncertainCreateRetryVerifiesExistingBytes() async throws {
    let data = Data("upload fixture".utf8)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let entry = StagedAttachment(
      id: "fixture", key: "attachments/existing", name: "fixture.txt", contentType: "text/plain",
      bytes: data.count,
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), state: .queued)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AttachmentUploadFixture.self]
    let uploader = AttachmentUploader(
      endpoint: "https://upload.invalid/prefix", token: "synthetic",
      session: URLSession(configuration: config))
    let receipt = try await uploader.upload(entry, file: file)
    #expect(receipt.key == "attachments/existing")
    #expect(receipt.sha256 == entry.sha256)
  }
}

private final class AttachmentUploadFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "upload.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic",
      request.url?.path.hasPrefix("/prefix/v1/files/attachments/") == true
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let key = String(request.url!.path.dropFirst("/prefix/v1/files/".count))
    let existing = key == "attachments/existing"
    let data: Data
    let status: Int
    let headers: [String: String]
    if request.httpMethod == "PUT" {
      guard request.value(forHTTPHeaderField: "If-None-Match") == "*",
        request.value(forHTTPHeaderField: "Content-Type") == "text/plain",
        let hash = request.value(forHTTPHeaderField: "X-Content-SHA256")
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      status = existing ? 412 : 201
      data = try! JSONSerialization.data(withJSONObject: [
        "key": key, "mime": "text/plain", "bytes": 14, "sha256": hash,
      ])
      headers = ["Content-Type": "application/json"]
    } else {
      guard existing, request.httpMethod == "GET" else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      status = 200
      data = Data("upload fixture".utf8)
      headers = ["Content-Type": "text/plain", "Content-Length": "14"]
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
