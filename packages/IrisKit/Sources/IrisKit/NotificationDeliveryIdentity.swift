import CryptoKit
import Foundation

enum NotificationDeliveryIdentity {
  // Transport identity only. Local alert checkpoints continue storing the original event ID.
  static func collapseKey(deployment: String, eventID: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let tuple = try encoder.encode(["life-notification-v1", deployment, eventID])
    return Data(SHA256.hash(data: tuple)).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
