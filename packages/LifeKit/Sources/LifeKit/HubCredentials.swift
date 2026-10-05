import Foundation
import LocalAuthentication
import Security

struct HubCredentials: Codable, Equatable, Sendable {
  let endpoint: String
  let token: String
}

protocol HubCredentialStorage {
  func load() throws -> HubCredentials?
  func save(_ credentials: HubCredentials) throws
  func remove() throws
}

/// Consumer credentials stay in this device's Keychain, never UserDefaults or files.
struct HubCredentialStore: HubCredentialStorage {
  let service: String
  init(service: String = "life-ui.hub") { self.service = service }

  private var query: [String: Any] {
    let authentication = LAContext()
    authentication.interactionNotAllowed = true
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "hub",
      kSecUseDataProtectionKeychain as String: true,
      kSecUseAuthenticationContext as String: authentication,
    ]
  }
  func load() throws -> HubCredentials? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let data = result as? Data else {
      throw WorkspaceError(message: "Saved hub connection is invalid.", violations: [])
    }
    return try JSONDecoder().decode(HubCredentials.self, from: data)
  }
  func save(_ credentials: HubCredentials) throws {
    let data = try JSONEncoder().encode(credentials)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var request = query
      request[kSecValueData as String] = data
      request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      try check(SecItemAdd(request as CFDictionary, nil))
    } else {
      try check(status)
    }
  }
  func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }
  func check(_ status: OSStatus) throws {
    if status == errSecMissingEntitlement {
      throw WorkspaceError(
        message: "This app is missing a required Keychain signing entitlement (-34018). Install a corrected release.",
        violations: [])
    }
    guard status == errSecSuccess else {
      throw WorkspaceError(
        message: "Keychain is unavailable (\(status)). Unlock this device and try again.",
        violations: [])
    }
  }
}
