import Foundation
import Security

// The standalone probe compiles the production store without the UI/database
// dependencies. This is only its existing error payload, not a storage double.
struct WorkspaceError: Error, LocalizedError {
  let message: String
  let violations: [String]
  var errorDescription: String? { message }
}

@main
struct KeychainProbe {
  static func main() throws {
    let store = HubCredentialStore(service: "life-ui.release-probe.\(UUID().uuidString)")
    defer { try? store.remove() }
    func require(_ condition: Bool) throws {
      if !condition { throw WorkspaceError(message: "Keychain roundtrip mismatch", violations: []) }
    }
    try require(store.load() == nil)
    let first = HubCredentials(endpoint: "https://fixture.invalid", token: "synthetic-first")
    try store.save(first)
    try require(store.load() == first)
    let rotated = HubCredentials(endpoint: first.endpoint, token: "synthetic-rotated")
    try store.save(rotated)
    try require(store.load() == rotated)
    // Inspect the actual item: removing the DP flag in product code must not
    // silently let this smoke pass against the older file-based keychain.
    var attributes: CFTypeRef?
    let status = SecItemCopyMatching([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: store.service,
      kSecAttrAccount: "hub",
      kSecUseDataProtectionKeychain: true,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ] as CFDictionary, &attributes)
    try require(status == errSecSuccess)
    let values = attributes as? [String: Any]
    try require(values?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    try store.remove()
    try require(store.load() == nil)
    print("Data Protection Keychain create/read/update/delete passed")
  }
}
