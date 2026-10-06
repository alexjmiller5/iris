import Foundation
import Testing

@testable import LifeKit

struct CalendarContextTests {
  @Test func calendarDaysRespectDSTAndMidnight() throws {
    let samples = [
      (
        "2026-03-08T16:00:00Z", "2026-03-08", "2026-03-08T05:00:00.000Z", "2026-03-09T04:00:00.000Z"
      ),
      (
        "2026-11-01T16:00:00Z", "2026-11-01", "2026-11-01T04:00:00.000Z", "2026-11-02T05:00:00.000Z"
      ),
      (
        "2026-03-09T04:00:00Z", "2026-03-09", "2026-03-09T04:00:00.000Z", "2026-03-10T04:00:00.000Z"
      ),
    ]
    for (instant, day, start, end) in samples {
      let now = try #require(ISO8601DateFormatter().date(from: instant))
      let actual = try calendarContext(timeZone: "America/New_York", now: now)
      #expect(actual.today == day)
      #expect(actual.start == start)
      #expect(actual.end == end)
    }
    #expect(throws: (any Error).self) { try calendarContext(timeZone: "Unknown/Zone", now: Date()) }
  }
}
