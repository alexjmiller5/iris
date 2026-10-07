import Foundation
import LifeExtensionSupport

public func calendarContext(timeZone: String, now: Date = Date(), dayStartMinutes: Int = 0) throws
  -> CoreCalendarContext
{
  do {
    return try extensionCalendarContext(
      timeZone: timeZone, now: now, dayStartMinutes: dayStartMinutes)
  } catch { throw WorkspaceError(message: error.localizedDescription, violations: []) }
}
