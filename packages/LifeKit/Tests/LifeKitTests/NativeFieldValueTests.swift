import Foundation
import Testing

@testable import LifeKit

struct NativeFieldValueTests {
  @Test func dateOnlyUsesGregorianUTCMidnight() throws {
    let parsed = try #require(NativeDateValue.parse("2024-02-29", kind: .date))
    #expect(parsed.timeIntervalSince1970 == 1_709_164_800)
    #expect(NativeDateValue.format(parsed, kind: .date) == "2024-02-29")
  }

  @Test func datetimeRetainsSecondsAndMillisecondsInUTC() throws {
    let raw = "2024-02-29T23:04:05.123Z"
    let parsed = try #require(NativeDateValue.parse(raw, kind: .datetime))
    #expect(abs(parsed.timeIntervalSince1970 - 1_709_247_845.123) < 0.0001)
    #expect(NativeDateValue.format(parsed, kind: .datetime) == raw)
  }

  @Test(arguments: [
    "", "2023-02-29", "2024-02-30", "2024-13-01", "2024-00-01",
    "2024-02-29 ", "2024-2-9", "0000-01-01",
  ])
  func invalidDateSourceIsUnavailableToThePicker(_ raw: String) {
    #expect(NativeDateValue.parse(raw, kind: .date) == nil)
  }

  @Test(arguments: [
    "2024-02-29T23:04:05Z", "2024-02-29T23:04:05.123+01:00",
    "2024-02-29T23:04:05.123z", "2024-02-29T23:04:60.123Z", "2023-02-29T23:04:05.123Z",
  ])
  func unsupportedDatetimeSourceIsNotNormalized(_ raw: String) {
    #expect(NativeDateValue.parse(raw, kind: .datetime) == nil)
  }

  @Test func formattingAnExplicitPickerChangeProducesTheCoreStorageFormat() {
    let selected = Date(timeIntervalSince1970: 1_709_247_845.123)
    #expect(NativeDateValue.format(selected, kind: .datetime) == "2024-02-29T23:04:05.123Z")
    #expect(NativeDateValue.format(selected, kind: .date) == "2024-02-29")
  }

  @Test func linkActionsRetainWebDestinationsAndUseTypedSystemSchemes() throws {
    #expect(
      NativeFieldLink.destination(type: "url", value: "https://example.test/a?b=1#part")?
        .absoluteString == "https://example.test/a?b=1#part")
    #expect(
      NativeFieldLink.destination(type: "email", value: "note+tag@example.test")?
        .absoluteString == "mailto:note+tag@example.test")
    #expect(
      NativeFieldLink.destination(type: "phone", value: "+00 (000) 000-0000")?
        .absoluteString == "tel:+000000000000")
  }

  @Test(arguments: [
    "javascript:alert(1)", "file:///tmp/example", "data:text/plain,hello",
    "mailto:note@example.test", "ftp://example.test/file", "https:///",
    "https://example.test\n/secret",
  ])
  func webActionsRefuseExecutableLocalAndMalformedURLs(_ raw: String) {
    #expect(NativeFieldLink.destination(type: "url", value: raw) == nil)
  }

  @Test func emailTextCannotAddMailHeadersOrFragments() throws {
    let raw = "note@example.test?bcc=extra@example.test#fragment"
    let url = try #require(NativeFieldLink.destination(type: "email", value: raw))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "mailto")
    #expect(components.path == raw)
    #expect(components.query == nil)
    #expect(components.fragment == nil)
    #expect(
      NativeFieldLink.destination(
        type: "email", value: "note@example.test\r\nbcc:extra@example.test") == nil)
  }

  @Test(arguments: ["+00;ext=123", "*123#", "javascript:1", "00+00", "+++", ""])
  func phoneActionsRefuseServiceCodesAndCommands(_ raw: String) {
    #expect(NativeFieldLink.destination(type: "phone", value: raw) == nil)
  }

  @Test func ordinaryTextNeverAcquiresAnAutomaticLinkAction() {
    #expect(NativeFieldLink.destination(type: "text", value: "https://example.test") == nil)
  }
}
