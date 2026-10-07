import Foundation
import Testing

@testable import LifeKit

struct CalendarMonthTests {
  @Test func monthUsesRealDSTAndConfiguredBoundary() throws {
    let spring = try calendarMonth("2026-03", timeZone: "America/New_York")
    #expect(spring.count == 31)
    #expect(spring[7].today == "2026-03-08")
    #expect(spring[7].start == "2026-03-08T05:00:00.000Z")
    #expect(spring[7].end == "2026-03-09T04:00:00.000Z")
    let fall = try calendarMonth("2026-11", timeZone: "America/New_York", dayStartMinutes: 180)
    #expect(fall[0].start == "2026-11-01T08:00:00.000Z")
  }
  @Test func extremeZonesAndSkippedDates() throws {
    for zone in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "UTC"] {
      let days = try calendarMonth("2026-02", timeZone: zone)
      #expect(days.count == 28)
      #expect(days.first?.today == "2026-02-01")
      #expect(days.last?.today == "2026-02-28")
    }
    let apia = try calendarMonth("2011-12", timeZone: "Pacific/Apia")
    #expect(apia.count == 30)
    #expect(!apia.contains { $0.today == "2011-12-30" })
  }
  @Test func invalidMonth() {
    for value in ["2026-13", "bad", "2026-00", "2026-2"] {
      #expect(throws: (any Error).self) { try calendarMonth(value, timeZone: "UTC") }
    }
  }
}
