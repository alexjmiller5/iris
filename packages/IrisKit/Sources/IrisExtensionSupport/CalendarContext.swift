import Foundation

/// An empty or missing timezone follows whichever zone this device is in now.
public func extensionCalendarContext(
  timeZone: String?, now: Date = Date(), dayStartMinutes: Int = 0
)
  throws
  -> CoreCalendarContext
{
  let named = timeZone.flatMap { $0.isEmpty ? nil : $0 }
  guard let zone = named.map(TimeZone.init(identifier:)) ?? TimeZone.current,
    now.timeIntervalSince1970.isFinite
  else {
    throw ExtensionReadError(message: "Choose a valid timezone for Today.")
  }
  guard (0..<1440).contains(dayStartMinutes) else {
    throw ExtensionReadError(
      message: "Day start must be a whole minute from 00:00 through 23:59.")
  }
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = zone
  guard var interval = calendar.dateInterval(of: .day, for: now) else {
    throw ExtensionReadError(message: "Cannot resolve this calendar day.")
  }
  func boundary(_ midnight: Date) throws -> Date {
    if dayStartMinutes == 0 { return midnight }
    guard
      let result = calendar.nextDate(
        after: midnight.addingTimeInterval(-1),
        matching: DateComponents(
          hour: dayStartMinutes / 60, minute: dayStartMinutes % 60, second: 0),
        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    else {
      throw ExtensionReadError(message: "Cannot resolve this calendar boundary.")
    }
    return result
  }
  if now < (try boundary(interval.start)) {
    guard let previous = calendar.dateInterval(of: .day, for: interval.start.addingTimeInterval(-1))
    else {
      throw ExtensionReadError(message: "Cannot resolve this calendar day.")
    }
    interval = previous
  }
  // Some transitions cross midnight before folding into the previous wall
  // date. The first boundary still begins the new effective day.
  while now >= (try boundary(interval.end)) {
    guard let next = calendar.dateInterval(of: .day, for: interval.end) else {
      throw ExtensionReadError(message: "Cannot resolve this calendar day.")
    }
    interval = next
  }
  let parts = calendar.dateComponents([.year, .month, .day], from: interval.start)
  let today = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  // The same instants as floating local times (YYYY-MM-DDTHH:MM) in the policy zone.
  func local(_ date: Date) -> String {
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(
      format: "%04d-%02d-%02dT%02d:%02d", parts.year!, parts.month!, parts.day!, parts.hour!,
      parts.minute!)
  }
  let start = try boundary(interval.start), end = try boundary(interval.end)
  // The clock reading at whole milliseconds, as the core's instants are written.
  let reading = Date(
    timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
  return CoreCalendarContext(
    today: today, start: formatter.string(from: start), end: formatter.string(from: end),
    now: formatter.string(from: reading), localNow: local(reading),
    localStart: local(start), localEnd: local(end))
}

/// The instant a floating local time (`YYYY-MM-DDTHH:MM`) names in a zone (empty or
/// missing: this device's), or nil for any other value. A time skipped by a clock
/// change advances to the first valid instant; a repeated time uses its first occurrence.
public func localTimeInstant(_ value: String, timeZone: String?) -> Date? {
  let digits = Array(value.utf8)
  guard digits.count == 16, digits[4] == 45, digits[7] == 45, digits[10] == 84, digits[13] == 58,
    [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15].allSatisfy({ (48...57).contains(digits[$0]) }),
    let year = Int(value.prefix(4)), let month = Int(value.dropFirst(5).prefix(2)),
    let day = Int(value.dropFirst(8).prefix(2)), let hour = Int(value.dropFirst(11).prefix(2)),
    let minute = Int(value.suffix(2)), hour < 24, minute < 60,
    let zone = timeZone.flatMap({ $0.isEmpty ? nil : TimeZone(identifier: $0) })
      ?? (timeZone.map { $0.isEmpty } ?? true ? TimeZone.current : nil)
  else { return nil }
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = zone
  guard
    let midnight = calendar.date(from: DateComponents(year: year, month: month, day: day)),
    calendar.dateComponents([.year, .month, .day], from: midnight)
      == DateComponents(year: year, month: month, day: day)
  else { return nil }
  return calendar.nextDate(
    after: midnight.addingTimeInterval(-1),
    matching: DateComponents(hour: hour, minute: minute, second: 0),
    matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
}
