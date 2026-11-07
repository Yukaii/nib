import Foundation

#if canImport(Security)
  import Security

  /// Stores pairing keys in the Apple Keychain so keys survive app relaunches
  /// without being included in preferences or backups.
  public final class KeychainPairingKeyStore: PairingKeyStore, @unchecked Sendable {
    public static let service = "dev.yukai.nib.pairing"

    private let lock = NSLock()

    public init() {}

    public func key(for peerID: String) -> Data? {
      lock.lock()
      defer { lock.unlock() }
      var query = baseQuery(peerID)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
      return result as? Data
    }

    public func save(_ key: Data, for peerID: String) {
      lock.lock()
      defer { lock.unlock() }
      let query = baseQuery(peerID)
      let attributes: [String: Any] = [
        kSecValueData as String: key,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]
      let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      if status == errSecItemNotFound {
        var insert = query
        insert.merge(attributes) { _, new in new }
        _ = SecItemAdd(insert as CFDictionary, nil)
      }
    }

    public func removeKey(for peerID: String) {
      lock.lock()
      defer { lock.unlock() }
      _ = SecItemDelete(baseQuery(peerID) as CFDictionary)
    }

    private func baseQuery(_ peerID: String) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Self.service,
        kSecAttrAccount as String: peerID,
      ]
    }
  }
#endif
