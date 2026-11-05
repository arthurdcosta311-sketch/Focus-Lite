//
//  SecureVault.swift
//  Focus Lite
//

import CryptoKit
import Foundation
import Security

/// AES-GCM cipher for everything Focus Lite persists about browsing — the
/// saved session tabs and extension storage. The 256-bit key lives in the
/// Keychain, marked device-only and never synced, so the ciphertext in
/// UserDefaults is unreadable to anything outside this app. Inside the app
/// the plain URLs are always shown in full; only what is written to disk is
/// sealed.
enum SecureVault {
    private static let service = "Focus Lite vault"
    private static let account = "browsing.cipher.v1"

    /// The app's cipher key, generated on first use and kept in the Keychain.
    /// Accessible after first unlock on this device only: it never leaves in
    /// an iCloud backup or Keychain sync, so no other device or process can
    /// decrypt what this one sealed.
    private static let key: SymmetricKey = {
        if let existing = loadKeyFromKeychain(), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        let fresh = SymmetricKey(size: .bits256)
        let raw = fresh.withUnsafeBytes { Data($0) }
        storeKeyInKeychain(raw)
        return fresh
    }()

    // MARK: - Sealing

    /// Seals raw bytes. Returns nonce + ciphertext + tag in one blob, or nil
    /// if sealing failed (the caller then simply writes nothing).
    static func seal(_ data: Data) -> Data? {
        guard let sealed = try? AES.GCM.seal(data, using: key) else { return nil }
        return sealed.combined
    }

    /// Opens a blob sealed by `seal(_:)`. Returns nil for anything this
    /// device's key cannot authenticate.
    static func open(_ sealed: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return plain
    }

    /// Seals a JSON-serializable value (an array of URL strings, a dictionary
    /// of extension storage, …) into one encrypted blob.
    static func sealJSON(_ object: Any) -> Data? {
        guard let plain = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return seal(plain)
    }

    /// Opens a blob sealed by `sealJSON(_:)` back into a JSON value.
    static func openJSON(_ sealed: Data) -> Any? {
        guard let plain = open(sealed) else { return nil }
        return try? JSONSerialization.jsonObject(with: plain)
    }

    // MARK: - Keychain

    private static func loadKeyFromKeychain() -> Data? {
        var query: [String: Any] = baseKeychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func storeKeyInKeychain(_ keyData: Data) {
        var query: [String: Any] = baseKeychainQuery()
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        var update: AnyObject?
        let updateStatus = SecItemCopyMatching(baseKeychainQuery() as CFDictionary, &update)
        if updateStatus == errSecSuccess {
            let attributes: [String: Any] = [
                kSecValueData as String: keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            SecItemUpdate(baseKeychainQuery() as CFDictionary, attributes as CFDictionary)
        } else {
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func baseKeychainQuery() -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
