import Foundation
import Testing

@testable import LifeKit

struct CalendarContextTests {
  @Test func configuredDayUsesCivilBoundariesAcrossRolloverAndDST() throws {
    let samples = [
      (
        "2026-06-02T06:59:59.999Z", "2026-06-01", "2026-06-01T07:00:00.000Z",
        "2026-06-02T07:00:00.000Z"
      ),
      (
        "2026-06-02T07:00:00Z", "2026-06-02", "2026-06-02T07:00:00.000Z", "2026-06-03T07:00:00.000Z"
      ),
      (
        "2026-03-08T06:59:59.999Z", "2026-03-07", "2026-03-07T08:00:00.000Z",
        "2026-03-08T07:00:00.000Z"
      ),
      (
        "2026-03-08T07:00:00Z", "2026-03-08", "2026-03-08T07:00:00.000Z", "2026-03-09T07:00:00.000Z"
      ),
      (
        "2026-11-01T07:59:59.999Z", "2026-10-31", "2026-10-31T07:00:00.000Z",
        "2026-11-01T08:00:00.000Z"
      ),
      (
        "2026-11-01T08:00:00Z", "2026-11-01", "2026-11-01T08:00:00.000Z", "2026-11-02T08:00:00.000Z"
      ),
    ]
    for (instant, day, start, end) in samples {
      let actual = try calendarContext(
        timeZone: "America/New_York", now: parse(instant), dayStartMinutes: 180)
      #expect(actual.today == day)
      #expect(actual.start == start)
      #expect(actual.end == end)
    }
  }

  @Test func timezoneChangesGapAndRepeatedBoundaryUseTheSamePolicy() throws {
    let samples = [
      (
        "America/Goose_Bay", "2009-11-01T03:05:00Z", 0, "2009-11-01", "2009-11-01T03:00:00.000Z",
        "2009-11-02T04:00:00.000Z"
      ),
      (
        "Pacific/Apia", "2011-12-30T12:00:00Z", 180, "2011-12-29", "2011-12-29T13:00:00.000Z",
        "2011-12-30T13:00:00.000Z"
      ),
      (
        "UTC", "2026-06-02T06:59:59.999Z", 180, "2026-06-02", "2026-06-02T03:00:00.000Z",
        "2026-06-03T03:00:00.000Z"
      ),
      (
        "Asia/Kathmandu", "2026-06-02T06:59:59.999Z", 180, "2026-06-02", "2026-06-01T21:15:00.000Z",
        "2026-06-02T21:15:00.000Z"
      ),
      (
        "America/New_York", "2026-03-08T07:00:00Z", 150, "2026-03-08", "2026-03-08T07:00:00.000Z",
        "2026-03-09T06:30:00.000Z"
      ),
      (
        "America/New_York", "2026-11-01T06:15:00Z", 90, "2026-11-01", "2026-11-01T05:30:00.000Z",
        "2026-11-02T06:30:00.000Z"
      ),
    ]
    for (zone, instant, minutes, day, start, end) in samples {
      let actual = try calendarContext(
        timeZone: zone, now: parse(instant), dayStartMinutes: minutes)
      #expect(actual.today == day)
      #expect(actual.start == start)
      #expect(actual.end == end)
    }
    for minutes in [-1, 1440] {
      #expect(throws: WorkspaceError.self) {
        try calendarContext(timeZone: "UTC", dayStartMinutes: minutes)
      }
    }
  }

  private func parse(_ value: String) throws -> Date {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try #require(fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value))
  }

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
