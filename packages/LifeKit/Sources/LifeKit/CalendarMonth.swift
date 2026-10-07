import Foundation

func calendarMonth(_ month: String, timeZone: String, dayStartMinutes: Int = 0) throws
  -> [CoreCalendarContext]
{
  guard month.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil else {
    throw WorkspaceError(message: "Choose a valid month.", violations: [])
  }
  let first = month + "-01"
  let parser = ISO8601DateFormatter()
  parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  guard let anchor = parser.date(from: first + "T00:00:00.000Z") else {
    throw WorkspaceError(message: "Choose a valid month.", violations: [])
  }
  var day = try calendarContext(
    timeZone: timeZone, now: anchor.addingTimeInterval(-48 * 3600), dayStartMinutes: dayStartMinutes
  )
  var days: [CoreCalendarContext] = []
  for _ in 0..<36 {
    if day.today >= first {
      if !day.today.hasPrefix(month + "-") { break }
      days.append(day)
    }
    guard let end = parser.date(from: day.end) else {
      throw WorkspaceError(message: "Cannot resolve the next calendar day.", violations: [])
    }
    day = try calendarContext(timeZone: timeZone, now: end, dayStartMinutes: dayStartMinutes)
  }
  return days
}
