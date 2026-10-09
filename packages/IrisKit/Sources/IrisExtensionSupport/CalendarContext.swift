import Foundation

public func extensionCalendarContext(timeZone: String, now: Date = Date(), dayStartMinutes: Int = 0)
  throws
  -> CoreCalendarContext
{
  guard let zone = TimeZone(identifier: timeZone), now.timeIntervalSince1970.isFinite else {
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
  return CoreCalendarContext(
    today: today, start: formatter.string(from: try boundary(interval.start)),
    end: formatter.string(from: try boundary(interval.end)))
}
