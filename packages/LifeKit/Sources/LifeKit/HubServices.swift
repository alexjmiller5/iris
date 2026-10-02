import Foundation

// Wire types mirror life-core services; policy and pagination stay in shared JS.
struct UsageSummary: Codable, Sendable {
  struct Period: Codable, Sendable {
    let start: String
    let end: String
    let anchorDay: Int
    private enum CodingKeys: String, CodingKey {
      case start, end
      case anchorDay = "anchor_day"
    }
  }
  struct Metric: Codable, Sendable {
    let kind: String
    let unit: String
    let used: Double?
    let allowance: Double?
    let cap: Double?
    let alertAt: [Double]
    let measuredAt: String?
    private enum CodingKeys: String, CodingKey {
      case kind, unit, used, allowance, cap
      case alertAt = "alert_at"
      case measuredAt = "measured_at"
    }
  }
  struct Cap: Codable, Sendable {
    let metric: String
    let used: Double
    let cap: Double
    let resetsAt: String
    private enum CodingKeys: String, CodingKey {
      case metric, used, cap
      case resetsAt = "resets_at"
    }
  }
  struct Principal: Codable, Identifiable, Sendable {
    let id: String
    let label: String?
    let kind: String
    let rowsRead: Double
    let rowsWritten: Double
    let requests: Double
    private enum CodingKeys: String, CodingKey {
      case id, label, kind, requests
      case rowsRead = "rows_read"
      case rowsWritten = "rows_written"
    }
  }
  let period: Period
  let measuredAt: String?
  let capped: Cap?
  let metrics: [String: Metric]
  let byPrincipal: [Principal]
  private enum CodingKeys: String, CodingKey {
    case period, capped, metrics
    case measuredAt = "measured_at"
    case byPrincipal = "by_principal"
  }
}

struct HubNotification: Codable, Identifiable, Sendable {
  let seq: Int
  let id: String
  let createdAt: String
  let producer: String
  let type: String
  let severity: String
  let title: String
  let body: String
  let data: JSONValue?
  let readAt: String?
  private enum CodingKeys: String, CodingKey {
    case seq, id, producer, type, severity, title, body, data
    case createdAt = "created_at"
    case readAt = "read_at"
  }
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(seq, forKey: .seq)
    try container.encode(id, forKey: .id)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(producer, forKey: .producer)
    try container.encode(type, forKey: .type)
    try container.encode(severity, forKey: .severity)
    try container.encode(title, forKey: .title)
    try container.encode(body, forKey: .body)
    try container.encode(data, forKey: .data)
    try container.encode(readAt, forKey: .readAt)
  }
}

struct NotificationFeed: Codable, Sendable {
  let notifications: [HubNotification]
  let nextCursor: Int?
  let latestCursor: Int
  let unreadCount: Int
  private enum CodingKeys: String, CodingKey {
    case notifications
    case nextCursor = "next_cursor"
    case latestCursor = "latest_cursor"
    case unreadCount = "unread_count"
  }
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(notifications, forKey: .notifications)
    try container.encode(nextCursor, forKey: .nextCursor)
    try container.encode(latestCursor, forKey: .latestCursor)
    try container.encode(unreadCount, forKey: .unreadCount)
  }
}

struct NotificationPresentation: Codable, Sendable {
  let notifications: [HubNotification]
  let baseline: Int
}

struct NotificationReadResult: Decodable, Sendable {
  let unreadCount: Int
  private enum CodingKeys: String, CodingKey { case unreadCount = "unread_count" }
}
