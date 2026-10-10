import Foundation

/// How the hub's change signal stands: a live socket, a recent drop being
/// retried, or a socket down so long that the app checks once a minute.
enum SyncLiveness: Sendable, Equatable {
  case live, reconnecting, minute
}

enum HubChangeEvent: Sendable, Equatable {
  case state(SyncLiveness)
  /// Run a round: the socket (re)opened, or the hub committed a change.
  case wake
}

/// One open change socket. Production wraps `URLSessionWebSocketTask`.
protocol HubWakeConnection: Sendable {
  func send(_ text: String) async throws
  func receive() async throws -> String
  func cancel()
}

/// soma's WebSocket wake signal (`GET /v1/changes`). It is not a core request:
/// it only tells the automatic sync owner when to run a round, so it never
/// touches the database. Messages are `{seq, tables}`; any of them is a wake,
/// and every (re)open is one too, which covers anything missed while down.
struct HubChangeSignal: Sendable {
  struct Timing: Sendable {
    var ping: Duration = .seconds(30)
    var pong: Duration = .seconds(10)
    var firstRetry: Duration = .seconds(1)
    var maxRetry: Duration = .seconds(30)
    var minute: Duration = .seconds(120)
    var minuteRetry: Duration = .seconds(60)
  }
  var timing = Timing()
  let connect: @Sendable () throws -> any HubWakeConnection

  init(timing: Timing = Timing(), connect: @escaping @Sendable () throws -> any HubWakeConnection) {
    self.timing = timing
    self.connect = connect
  }

  init(transport: HubTransport) {
    self.init { try transport.changeConnection() }
  }

  func events() -> AsyncStream<HubChangeEvent> {
    AsyncStream { continuation in
      let task = Task {
        var attempt = 0
        var downSince = ContinuousClock.now
        while !Task.isCancelled {
          var wasLive = false
          if let connection = try? connect() {
            wasLive = await run(connection) { continuation.yield($0) }
          }
          if Task.isCancelled { break }
          if wasLive {
            attempt = 0
            downSince = .now
          }
          let minute = downSince.duration(to: .now) >= timing.minute
          continuation.yield(.state(minute ? .minute : .reconnecting))
          let backoff = timing.firstRetry * (1 << min(attempt, 16))
          attempt += 1
          do { try await Task.sleep(for: minute ? timing.minuteRetry : min(backoff, timing.maxRetry)) } catch {
            break
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Holds one connection until it drops or misses a pong; true once it went live.
  private func run(_ connection: any HubWakeConnection, _ yield: @escaping @Sendable (HubChangeEvent) -> Void)
    async -> Bool
  {
    let pongs = PongLedger()
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        while let text = try? await connection.receive() {
          if text == "pong" {
            // The first pong proves the socket open.
            if pongs.record() {
              yield(.state(.live))
              yield(.wake)
            }
          } else if let data = text.data(using: .utf8),
            let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            message["seq"] is NSNumber
          {
            yield(.wake)
          }
        }
      }
      group.addTask {
        // A ping every interval; a dead connection may never report itself.
        while !Task.isCancelled {
          let sent = ContinuousClock.now
          guard (try? await connection.send("ping")) != nil else { break }
          guard (try? await Task.sleep(for: timing.pong)) != nil, pongs.since(sent) else { break }
          guard (try? await Task.sleep(for: timing.ping - timing.pong)) != nil else { break }
        }
      }
      await group.next()
      connection.cancel()
      group.cancelAll()
    }
    return pongs.opened
  }
}

private final class PongLedger: @unchecked Sendable {
  private let lock = NSLock()
  private var last: ContinuousClock.Instant?
  var opened: Bool { lock.withLock { last != nil } }
  /// Records a pong; true for the first one.
  func record() -> Bool {
    lock.withLock {
      defer { last = .now }
      return last == nil
    }
  }
  func since(_ instant: ContinuousClock.Instant) -> Bool {
    lock.withLock { last.map { $0 >= instant } ?? false }
  }
}

final class URLSessionWakeConnection: HubWakeConnection, @unchecked Sendable {
  private let task: URLSessionWebSocketTask
  init(_ task: URLSessionWebSocketTask) {
    self.task = task
    task.resume()
  }
  func send(_ text: String) async throws { try await task.send(.string(text)) }
  func receive() async throws -> String {
    switch try await task.receive() {
    case .string(let text): return text
    case .data(let data): return String(decoding: data, as: UTF8.self)
    @unknown default: return ""
    }
  }
  func cancel() { task.cancel(with: .goingAway, reason: nil) }
}
