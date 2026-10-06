import Foundation

func calendarContext(timeZone: String, now: Date = Date()) throws -> CoreCalendarContext {
  guard let zone = TimeZone(identifier: timeZone), now.timeIntervalSince1970.isFinite else {
    throw WorkspaceError(message: "Choose a valid timezone for Today.", violations: [])
  }
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = zone
  guard let interval = calendar.dateInterval(of: .day, for: now) else {
    throw WorkspaceError(message: "Cannot resolve this calendar day.", violations: [])
  }
  let parts = calendar.dateComponents([.year, .month, .day], from: now)
  let today = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  return CoreCalendarContext(
    today: today, start: formatter.string(from: interval.start),
    end: formatter.string(from: interval.end))
}
