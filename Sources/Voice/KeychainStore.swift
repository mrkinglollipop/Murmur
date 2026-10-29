import Foundation
import Security

struct KeychainOperations {
    var read: ([String: Any]) -> (OSStatus, Data?)
    var add: ([String: Any]) -> OSStatus
    var update: ([String: Any], [String: Any]) -> OSStatus
    var delete: ([String: Any]) -> OSStatus

    static let live = KeychainOperations(
        read: { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

enum KeychainReadError: Error {
    case status(OSStatus)
    case invalidData
}

/// Thin wrapper over the macOS Keychain (`Security` framework) for storing
/// user-supplied cloud ASR API keys. No third-party dependency — generic
/// password items, scoped to a single service name with the provider
/// identifier as the account.
///
/// Keys never touch UserDefaults or disk in plaintext; this is the sole
/// storage path for BYO cloud API keys.
final class KeychainStore {

    /// Service name all Voice Dictation API-key items are stored under.
    static let productionService = "com.matt.voice-dictation.apikeys"
    static let defaultService = isTestHost ? productionService + ".TESTS" : productionService

    let service: String
    private let operations: KeychainOperations

    /// The service is injectable ONLY so tests can isolate themselves in a
    /// throwaway service name. Production always uses the default: the user's
    /// real keys live under it, and a test writing/deleting through the real
    /// service OVERWRITES AND DELETES the user's actual API keys (this
    /// destroyed the live xAI key on 2026-07-09 — never again).
    init(
        service: String = KeychainStore.defaultService,
        operations: KeychainOperations = .live
    ) {
        self.service = service
        self.operations = operations
    }

    /// The base query shared by every operation (add/update/read/delete).
    ///
    /// **DO NOT add `kSecUseDataProtectionKeychain` to this dictionary.**
    ///
    /// That flag is a Keychain STORE SELECTOR: it routes items into the Data
    /// Protection keychain, which is a distinct store from the legacy
    /// file-based login keychain. This Developer-ID-signed app has no
    /// `keychain-access-groups` or `application-identifier` entitlement —
    /// macOS requires at least one of those to use the Data Protection store.
    /// With the flag present, `SecItemAdd` fails with `errSecMissingEntitlement`
    /// (-34018), observed live against the Developer-ID build on 2026-07-09,
    /// meaning every key save silently discards the user's input. The DP store
    /// can never hold anything for this app without also adding the entitlement
    /// and a provisioning profile.
    ///
    /// History of the churn so a future reader understands why this file looks
    /// churny and does NOT "fix" it back:
    ///   - e9d7709 (2026-07-07): added `kSecUseDataProtectionKeychain: true` to
    ///     `setKey` but dropped it from the read/delete queries, so writes went to
    ///     the DP store and reads hit the legacy store — every key read back as
    ///     missing despite a successful add status.
    ///   - A later commit re-added the flag to reads/deletes as well, making the
    ///     queries consistent again — but since `SecItemAdd` fails with
    ///     -34018 under the Developer-ID signing config, the DP path still silently
    ///     discards all writes. Nothing has ever round-tripped through the DP store.
    ///   - 2026-07-09: flag removed entirely. The legacy login keychain is the
    ///     only store that has ever worked for this app.
    ///
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on `setKey`'s
    /// add/update already prevents iCloud Keychain sync, so the original
    /// hardening intent is preserved without the store selector.
    static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Clipboard keys are create-only because overwriting one can make all
    /// encrypted history unreadable. Generic API-key writes must refuse them
    /// before any Keychain mutation.
    static func isClipboardKeyAccount(service: String, account: String) -> Bool {
        service == ClipboardKeyStore.service && account == ClipboardKeyStore.account
    }

    /// Stores (or overwrites) the key for `account`. Uses SecItemAdd first;
    /// on `errSecDuplicateItem` falls back to SecItemUpdate so re-saving an
    /// existing provider's key doesn't require a manual delete first.
    /// Returns `true` when the key was stored successfully.
    ///
    /// `accessibility` defaults to the `ThisDeviceOnly` class every BYO API key
    /// has always used — it is what keeps those keys out of iCloud Keychain.
    /// It is overridable because that tradeoff does not generalize: a secret
    /// protecting data the user cannot recreate (see `ClipboardKeyStore`) must
    /// survive a machine migration, or restoring a backup yields ciphertext
    /// with no key.
    @discardableResult
    func setKey(
        _ value: String,
        for account: String,
        accessibility accessibilityClass: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) -> Bool {
        guard !Self.isClipboardKeyAccount(service: service, account: account) else {
            assertionFailure("Clipboard key must use ClipboardKeyStore.createKey")
            return false
        }
        guard let data = value.data(using: .utf8) else { return false }

        let query = Self.baseQuery(service: service, account: account)

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        let accessibility: [String: Any] = [
            kSecAttrAccessible as String: accessibilityClass
        ]

        let addQuery = query
            .merging(attributesToUpdate) { _, new in new }
            .merging(accessibility) { _, new in new }
        let addStatus = operations.add(addQuery)

        if addStatus == errSecDuplicateItem {
            let updateAttrs = attributesToUpdate.merging(accessibility) { _, new in new }
            let updateStatus = operations.update(query, updateAttrs)
            if updateStatus != errSecSuccess {
                vlog("Keychain update failed for account \(account): OSStatus \(updateStatus)")
                return false
            }
            return true
        } else if addStatus != errSecSuccess {
            vlog("Keychain add failed for account \(account): OSStatus \(addStatus)")
            return false
        }
        return true
    }

    /// Returns the stored key for `account`, or `nil` if none is readable.
    func key(for account: String) -> String? {
        try? readKey(for: account)
    }

    /// Only a definite not-found is absence; all other failures preserve the item.
    func readKey(for account: String) throws -> String? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, data) = operations.read(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            vlog("Keychain read failed for account \(account): OSStatus \(status)")
            throw KeychainReadError.status(status)
        }
        guard let data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainReadError.invalidData
        }
        return value
    }

    /// Adds without ever replacing an existing secret. False means duplicate.
    func addKeyIfAbsent(
        _ value: String,
        for account: String,
        accessibility: CFString
    ) throws -> Bool {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = accessibility
        let status = operations.add(query)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw KeychainReadError.status(status) }
        return true
    }

    /// Deletes the stored key for `account`, if any. No-op if absent.
    func deleteKey(for account: String) {
        let query = Self.baseQuery(service: service, account: account)
        _ = operations.delete(query)
    }
}
