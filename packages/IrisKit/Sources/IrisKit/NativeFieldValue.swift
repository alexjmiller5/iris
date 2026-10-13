import Foundation

/// `local` is a floating local time (`YYYY-MM-DDTHH:MM`): a wall clock, kept in UTC
/// arithmetic so no zone ever shifts it. Catalog type names select date or datetime.
enum NativeDateKind: String { case date, datetime, local }

enum NativeDateValue {
  /// A `date_or_datetime` value's shape, or nil for anything else.
  static func mixedKind(_ raw: String) -> NativeDateKind? {
    [NativeDateKind.date, .local, .datetime].first { parse(raw, kind: $0) != nil }
  }

  static func currentValue(at date: Date, kind: NativeDateKind, timeZone: TimeZone = .current)
    -> String
  {
    let formatter = formatter(kind)
    if kind == .date { formatter.timeZone = timeZone }
    return formatter.string(from: date)
  }

  /// "Add time" on a date starts at 09:00 on that day; off keeps only the date.
  static func toggleTime(_ raw: String, on: Bool) -> String {
    guard let kind = mixedKind(raw), kind != .datetime, let date = parse(raw, kind: kind) else {
      return raw
    }
    if !on { return format(date, kind: .date) }
    return kind == .local ? raw : format(date.addingTimeInterval(9 * 3600), kind: .local)
  }

  static func parse(_ raw: String, kind: NativeDateKind) -> Date? {
    let formatter = formatter(kind)
    guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else {
      return nil
    }
    return date
  }

  static func format(_ date: Date, kind: NativeDateKind) -> String {
    formatter(kind).string(from: date)
  }

  private static func formatter(_ kind: NativeDateKind) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.isLenient = false
    formatter.dateFormat =
      switch kind {
      case .date: "yyyy-MM-dd"
      case .local: "yyyy-MM-dd'T'HH:mm"
      case .datetime: "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
      }
    return formatter
  }
}

enum NativeFieldLink {
  // Presentation hint only. The core checks the catalog and exact stored ID.
  static func isRecordReference(_ value: String) -> Bool {
    value.utf16.count <= 4096
      && value.range(
        of: #"^[A-Za-z_][A-Za-z0-9_]*/[^\s/\\?#\x00-\x1f\x7f]+$"#,
        options: .regularExpression) != nil
  }

  static func destination(type: String, value: String) -> URL? {
    guard !value.isEmpty,
      value.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil
    else { return nil }
    if type == "url" {
      guard let components = URLComponents(string: value),
        ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
        components.host?.isEmpty == false
      else { return nil }
      return components.url
    }
    var components = URLComponents()
    if type == "email" {
      guard value.contains("@"), value.rangeOfCharacter(from: .whitespaces) == nil else {
        return nil
      }
      components.scheme = "mailto"
      components.path = value
    } else if type == "phone" {
      let number = value.filter { !" ()-.".contains($0) }
      let digits = number.hasPrefix("+") ? number.dropFirst() : number[...]
      guard !digits.isEmpty, digits.allSatisfy({ "0123456789".contains($0) }) else { return nil }
      components.scheme = "tel"
      components.path = number
    } else {
      return nil
    }
    return components.url
  }
}
