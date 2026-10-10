import Foundation
import Testing

@testable import IrisKit

/// A scripted wake socket: the test feeds messages and drops it; pings get a
/// pong unless `answersPings` is off.
final class FakeWakeConnection: HubWakeConnection, @unchecked Sendable {
  private let lock = NSLock()
  private let inbound: AsyncThrowingStream<String, Error>
  private let feed: AsyncThrowingStream<String, Error>.Continuation
  private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator
  private var _sent: [String] = []
  private var _answersPings = true
  private var _cancelled = false

  init() {
    (inbound, feed) = AsyncThrowingStream.makeStream()
    iterator = inbound.makeAsyncIterator()
  }
  var sent: [String] { lock.withLock { _sent } }
  var cancelled: Bool { lock.withLock { _cancelled } }
  var answersPings: Bool {
    get { lock.withLock { _answersPings } }
    set { lock.withLock { _answersPings = newValue } }
  }
  func deliver(_ text: String) { feed.yield(text) }
  func drop() { feed.finish(throwing: URLError(.networkConnectionLost)) }

  func send(_ text: String) async throws {
    let pong = lock.withLock { () -> Bool in
      _sent.append(text)
      return text == "ping" && _answersPings
    }
    if pong { feed.yield("pong") }
  }
  func receive() async throws -> String {
    guard let text = try await iterator.next() else { throw URLError(.networkConnectionLost) }
    return text
  }
  func cancel() {
    lock.withLock { _cancelled = true }
    feed.finish(throwing: CancellationError())
  }
}

/// Hands out a fresh connection per attempt, or fails while `refusing`.
final class FakeWakeHub: @unchecked Sendable {
  private let lock = NSLock()
  private var _connections: [FakeWakeConnection] = []
  private var _refusing = false
  var connections: [FakeWakeConnection] { lock.withLock { _connections } }
  var refusing: Bool {
    get { lock.withLock { _refusing } }
    set { lock.withLock { _refusing = newValue } }
  }
  func connect() throws -> any HubWakeConnection {
    try lock.withLock {
      if _refusing { throw URLError(.cannotConnectToHost) }
      let connection = FakeWakeConnection()
      _connections.append(connection)
      return connection
    }
  }
  func signal(_ timing: HubChangeSignal.Timing = .fast) -> HubChangeSignal {
    HubChangeSignal(timing: timing) { try self.connect() }
  }
}

extension HubChangeSignal.Timing {
  static let fast = HubChangeSignal.Timing(
    ping: .milliseconds(300), pong: .milliseconds(100), firstRetry: .milliseconds(50),
    maxRetry: .milliseconds(400), minute: .seconds(1), minuteRetry: .milliseconds(600))
}

/// Drains a signal's events in the background; `next` waits up to two seconds for one.
final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [HubChangeEvent] = []
  private var task: Task<Void, Never>?
  init(_ stream: AsyncStream<HubChangeEvent>) {
    task = Task { for await event in stream { self.lock.withLock { self.events.append(event) } } }
  }
  deinit { task?.cancel() }
  func stop() { task?.cancel() }
  private func take() -> HubChangeEvent? {
    lock.withLock { events.isEmpty ? nil : events.removeFirst() }
  }
  func next(within limit: Duration = .seconds(2)) async -> HubChangeEvent? {
    let start = ContinuousClock.now
    while start.duration(to: .now) < limit {
      if let event = take() { return event }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return take()
  }
}

@Suite(.serialized)
struct HubChangeSignalTests {
  @Test func opensWithOneWakeAndWakesOnEveryChangeMessage() async throws {
    let hub = FakeWakeHub()
    let stream = hub.signal().events()
    let log = EventLog(stream)
    // The first pong proves the socket open: live, then one round for anything missed.
    #expect(await log.next() == .state(.live))
    #expect(await log.next() == .wake)
    let connection = try #require(hub.connections.first)
    #expect(connection.sent.first == "ping")
    connection.deliver(#"{"seq":7,"tables":["notes"]}"#)
    #expect(await log.next() == .wake)
    connection.deliver("pong")
    connection.deliver("not a change")
    connection.deliver(#"{"tables":["notes"]}"#)
    #expect(await log.next(within: .milliseconds(250)) == nil)
  }

  @Test func aDroppedSocketReconnectsWithBackoff() async throws {
    let hub = FakeWakeHub()
    let log = EventLog(hub.signal().events())
    #expect(await log.next() == .state(.live))
    #expect(await log.next() == .wake)
    hub.connections[0].drop()
    #expect(await log.next() == .state(.reconnecting))
    // The next attempt opens and runs a round again.
    #expect(await log.next() == .state(.live))
    #expect(await log.next() == .wake)
    #expect(hub.connections.count == 2)
    #expect(hub.connections[0].cancelled)
  }

  @Test func aMissedPongDropsASilentSocket() async throws {
    let hub = FakeWakeHub()
    let log = EventLog(hub.signal().events())
    #expect(await log.next() == .state(.live))
    #expect(await log.next() == .wake)
    hub.connections[0].answersPings = false
    #expect(await log.next(within: .seconds(1)) == .state(.reconnecting))
    #expect(hub.connections[0].cancelled)
    #expect(hub.connections[0].sent.filter { $0 == "ping" }.count >= 2)
  }

  @Test func aSocketDownPastTheThresholdChecksOnceAMinute() async throws {
    let hub = FakeWakeHub()
    hub.refusing = true
    let log = EventLog(hub.signal().events())
    var states: [HubChangeEvent] = []
    let started = ContinuousClock.now
    while started.duration(to: .now) < .seconds(3), states.last != .state(.minute) {
      if let event = await log.next() { states.append(event) }
    }
    #expect(states.first == .state(.reconnecting))
    #expect(states.last == .state(.minute))
    // Once a minute (600 ms here) it still retries, and a success goes live at once.
    hub.refusing = false
    #expect(await log.next(within: .seconds(1)) == .state(.live))
  }

  @Test func aSocketThatDiesAfterALongLifeReconnectsQuickly() async throws {
    let hub = FakeWakeHub()
    let log = EventLog(hub.signal().events())
    #expect(await log.next() == .state(.live))
    #expect(await log.next() == .wake)
    try await Task.sleep(for: .milliseconds(1300))  // longer than the minute threshold
    hub.connections[0].drop()
    #expect(await log.next() == .state(.reconnecting))
    #expect(await log.next(within: .milliseconds(500)) == .state(.live))
  }

  @Test func cancellingTheStreamClosesTheSocket() async throws {
    let hub = FakeWakeHub()
    let stream = hub.signal().events()
    let consumer = Task { for await _ in stream {} }
    try await Task.sleep(for: .milliseconds(200))
    consumer.cancel()
    try await Task.sleep(for: .milliseconds(200))
    #expect(hub.connections.first?.cancelled == true)
    let count = hub.connections.count
    try await Task.sleep(for: .milliseconds(500))
    #expect(hub.connections.count == count)
  }

  @Test func theTransportAsksForTheSocketWithItsBearerToken() throws {
    let https = try HubTransport(endpoint: "https://hub.example/", token: "lt_abc")
    let request = try https.changeRequest()
    #expect(request.url?.absoluteString == "wss://hub.example/v1/changes")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer lt_abc")
    let loopback = try HubTransport(endpoint: "http://127.0.0.1:5200", token: "fixture")
    #expect(try loopback.changeRequest().url?.absoluteString == "ws://127.0.0.1:5200/v1/changes")
  }
}
