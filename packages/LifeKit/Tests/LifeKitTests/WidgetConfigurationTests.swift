import LifeExtensionSupport
import LifeWidgets
import Testing

struct WidgetConfigurationTests {
  @Test func galleryConfigurationsKeepCountAndCalendarSemanticsDistinct() {
    #expect(TableWidgetConfiguration.resultKind == .list)
    #expect(!TableWidgetConfiguration.calendarOnly)
    #expect(CountWidgetConfiguration.resultKind == .count)
    #expect(!CountWidgetConfiguration.calendarOnly)
    #expect(TodayWidgetConfiguration.resultKind == .list)
    #expect(TodayWidgetConfiguration.calendarOnly)
    #expect(TableWidgetConfiguration().source == nil)
    #expect(TodayWidgetConfiguration().source == nil)
    #expect(CountWidgetConfiguration().source == nil)
  }
}
