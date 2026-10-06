import CryptoKit
import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

struct NotificationDeliveryIdentityTests {
  // Generated independently with ECMAScript JSON.stringify and Bun.CryptoHasher("sha256").
  private static let vectors: [Vector] = [
    .init("https://one.invalid/api/", "event-8", "4BdNs7CMh0vV4eEB52YGG26j7b_S8dqO4Z1GyS-d4DU"),
    .init(
      "deployment-quote\"\\\n\t", "event\u{0}\u{8}\u{c}\r\u{1f}",
      "XxI9zJU9Iqk1cpNo1lQXV5XT-6D29fMH55F-MX0-p5k"),
    .init("deployment-😀", "🔔/雪", "s7oGa6WrCaXRMMRbf8iKhIDv2imYRW8YwpUC3hty6kg"),
    .init("deployment", "\u{e9}", "w4lQtBKfabodAkIqfG9eCHMpiZ8cWYNXLk1W0lnJi6c"),
    .init("deployment", "e\u{301}", "s2UoNajTn_BmG93Rw_k0K52c208ejqJfYpDayzF0pOo"),
    .init("a", "bc", "RxZ_S5jlAKIGmpDwu0lnFKGegNK2Sag-zfjZ0X5VGuA"),
    .init("ab", "c", "iEca4rpRIzmhgjjPSqa10kpW62iu7HSGCFOv3JJj7LU"),
    .init(
      "deployment", "line\u{2028}paragraph\u{2029}",
      "wTW9s-NvgrqQTbdH4Y0f7Ye0p1gheTwJfpSx6F-boIc"),
  ]

  @Test(arguments: vectors)
  func matchesECMAScriptGoldenVector(vector: Vector) throws {
    let key = try NotificationDeliveryIdentity.collapseKey(
      deployment: vector.deployment, eventID: vector.eventID)
    #expect(key == vector.key)
    #expect(key.utf8.count == 43)
    #expect(
      key.utf8.allSatisfy { byte in
        (65...90).contains(byte) || (97...122).contains(byte)
          || (48...57).contains(byte) || byte == 45 || byte == 95
      })

    // Run the protocol's encoder independently, without round-tripping through Foundation JSON.
    let context = try #require(JSContext())
    let stringify = try #require(context.evaluateScript("JSON.stringify"))
    let tuple = ["life-notification-v1", vector.deployment, vector.eventID]
    let canonical = try #require(stringify.call(withArguments: [tuple])?.toString())
    let reference = Data(SHA256.hash(data: Data(canonical.utf8))).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    #expect(reference == vector.key)
  }

  @Test func sameEventAcrossDeploymentsHasDifferentTransportIdentity() throws {
    let first = try NotificationDeliveryIdentity.collapseKey(deployment: "one", eventID: "event")
    let second = try NotificationDeliveryIdentity.collapseKey(deployment: "two", eventID: "event")
    #expect(first != second)
    #expect(
      try NotificationDeliveryIdentity.collapseKey(deployment: "one", eventID: "event") == first)
  }

  struct Vector: Sendable {
    let deployment: String
    let eventID: String
    let key: String
    init(_ deployment: String, _ eventID: String, _ key: String) {
      self.deployment = deployment
      self.eventID = eventID
      self.key = key
    }
  }
}
