import Compression
import Foundation

/// A backup file read as text for core's validator: gzip is detected and inflated
/// here, its CRC-32 and length trailer checked, and UTF-8 kept whole across chunks.
final class DumpFileReader {
  private let handle: FileHandle
  private var inflater: GzipInflater?
  private var pending = Data()
  private var ended = false
  let totalBytes: Int64
  private(set) var readBytes: Int64 = 0

  init(url: URL) throws {
    do {
      handle = try FileHandle(forReadingFrom: url)
      totalBytes = Int64((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      let head = try handle.read(upToCount: 2) ?? Data()
      try handle.seek(toOffset: 0)
      if head == Data([0x1f, 0x8b]) { inflater = GzipInflater() }
    } catch {
      throw WorkspaceError(message: "The backup file could not be opened.", violations: [])
    }
  }

  deinit { try? handle.close() }

  /// The next text chunk, or nil once the whole file has been read.
  func next() throws -> String? {
    while true {
      if ended {
        guard pending.isEmpty else { throw Self.notText }
        return nil
      }
      let raw = try handle.read(upToCount: 1 << 20) ?? Data()
      readBytes += Int64(raw.count)
      if raw.isEmpty { ended = true }
      if let inflater {
        pending.append(raw.isEmpty ? try inflater.finish() : try inflater.feed(raw))
      } else {
        pending.append(raw)
      }
      let cut = Self.completeUTF8Prefix(pending)
      guard cut > 0 else { continue }
      guard let text = String(data: pending.prefix(cut), encoding: .utf8) else { throw Self.notText }
      pending = Data(pending.dropFirst(cut))
      if !text.isEmpty { return text }
    }
  }

  private static let notText = WorkspaceError(
    message: "The backup file could not be read: it is not UTF-8 text.", violations: [])

  /// Length of the prefix that ends on a whole UTF-8 sequence.
  static func completeUTF8Prefix(_ data: Data) -> Int {
    let bytes = [UInt8](data.suffix(4))
    var index = bytes.count - 1
    while index >= 0, bytes[index] & 0xC0 == 0x80 { index -= 1 }
    guard index >= 0 else { return data.count }
    let lead = bytes[index]
    let length = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
    let available = bytes.count - index
    return available >= length ? data.count : data.count - available
  }
}

/// RFC 1952 gzip over the Compression framework's raw DEFLATE decoder.
final class GzipInflater {
  private var stream = compression_stream(
    dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
    src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
  private var started = false
  private var header = Data()
  private var headerDone = false
  private var deflateEnded = false
  /// The last 8 bytes seen: the member's CRC-32 and length once input ends.
  private var trailer = Data()
  private var crc: UInt32 = 0xFFFF_FFFF
  private var size: UInt32 = 0

  static let damaged = WorkspaceError(
    message: "The backup file could not be read: its gzip data is damaged or incomplete.",
    violations: [])

  deinit { if started { compression_stream_destroy(&stream) } }

  func feed(_ input: Data) throws -> Data {
    var input = input
    if !headerDone {
      header.append(input)
      guard let end = try Self.headerLength(header) else { return Data() }
      input = Data(header.dropFirst(end))
      header = Data()
      headerDone = true
    }
    // Withhold the trailer from the decoder: it is the final 8 bytes of the file.
    let data = trailer + input
    trailer = Data(data.suffix(8))
    return try inflate(Data(data.dropLast(8)), finalize: false)
  }

  func finish() throws -> Data {
    guard headerDone, trailer.count == 8 else { throw Self.damaged }
    let tail = deflateEnded ? Data() : try inflate(Data(), finalize: true)
    // One member only: what CompressionStream and the hub write.
    guard deflateEnded else { throw Self.damaged }
    let word = { (offset: Int) -> UInt32 in
      self.trailer.dropFirst(offset).prefix(4).enumerated().reduce(UInt32(0)) {
        $0 | UInt32($1.element) << (8 * UInt32($1.offset))
      }
    }
    guard word(0) == ~crc, word(4) == size else { throw Self.damaged }
    return tail
  }

  private func inflate(_ input: Data, finalize: Bool) throws -> Data {
    if !started {
      guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        == COMPRESSION_STATUS_OK
      else { throw Self.damaged }
      started = true
    }
    var output = Data()
    let capacity = 1 << 16
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    defer { buffer.deallocate() }
    try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
      stream.src_size = raw.count
      while true {
        stream.dst_ptr = buffer
        stream.dst_size = capacity
        let status = compression_stream_process(
          &stream, finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
        let produced = capacity - stream.dst_size
        if produced > 0 {
          let chunk = UnsafeBufferPointer(start: buffer, count: produced)
          crc = CRC32.update(crc, chunk)
          size &+= UInt32(truncatingIfNeeded: produced)
          output.append(chunk)
        }
        switch status {
        case COMPRESSION_STATUS_END:
          // Anything after the DEFLATE end but before the trailer is not one gzip member.
          guard !deflateEnded, stream.src_size == 0 else { throw Self.damaged }
          deflateEnded = true
          return
        case COMPRESSION_STATUS_OK:
          if stream.src_size == 0 && stream.dst_size > 0 {
            if finalize { throw Self.damaged }
            return
          }
        default:
          throw Self.damaged
        }
      }
    }
    return output
  }

  /// Bytes before the DEFLATE data, or nil while the header is still incomplete.
  static func headerLength(_ data: Data) throws -> Int? {
    let bytes = [UInt8](data.prefix(64 * 1024))
    guard bytes.count >= 10 else { return nil }
    guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw damaged }
    let flags = bytes[3]
    var at = 10
    if flags & 4 != 0 {
      guard bytes.count >= at + 2 else { return nil }
      at += 2 + Int(bytes[at]) + Int(bytes[at + 1]) << 8
    }
    for flag: UInt8 in [8, 16] where flags & flag != 0 {
      guard let zero = bytes[min(at, bytes.count)...].firstIndex(of: 0) else { return nil }
      at = zero + 1
    }
    if flags & 2 != 0 { at += 2 }
    return bytes.count >= at ? at : nil
  }
}

enum CRC32 {
  private static let table: [UInt32] = (0..<256).map { n in
    (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
  }
  static func update(_ crc: UInt32, _ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
    var c = crc
    for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
    return c
  }
}

/// Text dump destination: written beside the target and moved into place on close,
/// so an interrupted export never leaves a partial file under the final name.
final class DumpFileWriter {
  let url: URL
  private let partial: URL
  private var handle: FileHandle?
  private(set) var writtenBytes: Int64 = 0

  init(url: URL) throws {
    self.url = url
    partial = url.appendingPathExtension("partial")
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: partial)
      guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
      handle = try FileHandle(forWritingTo: partial)
    } catch {
      throw WorkspaceError(message: "The backup destination could not be created.", violations: [])
    }
  }

  func write(_ text: String) throws {
    let data = Data(text.utf8)
    try handle?.write(contentsOf: data)
    writtenBytes += Int64(data.count)
  }

  func close() throws {
    guard let handle else { return }
    try handle.synchronize()
    try handle.close()
    self.handle = nil
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
    } else {
      try FileManager.default.moveItem(at: partial, to: url)
    }
  }

  func abandon() {
    try? handle?.close()
    handle = nil
    try? FileManager.default.removeItem(at: partial)
  }
}
