import CryptoKit
import Foundation
import Security

/// Errors surfaced by clipboard blob sealing and key resolution.
enum ClipboardCryptoError: Error, Equatable {
    /// `AES.GCM.seal` returned a box with no combined representation.
    case sealProducedNoBox
    /// A key could not be created or persisted to the Keychain.
    case keyUnavailable
}

/// AES-GCM sealing for clipboard blobs.
///
/// Every blob is stored as a self-describing combined box (nonce + ciphertext
/// + tag), so a blob file needs nothing but the key to open.
struct ClipboardCrypto {

    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else {
            throw ClipboardCryptoError.sealProducedNoBox
        }
        return combined
    }

    func open(_ box: Data) throws -> Data {
        let sealed = try AES.GCM.SealedBox(combined: box)
        return try AES.GCM.open(sealed, using: key)
    }
}

/// Resolves — and on first use creates — the symmetric key that clipboard
/// blobs are sealed with.
///
/// The key deliberately uses `kSecAttrAccessibleAfterFirstUnlock` rather than
/// the `ThisDeviceOnly` variant that `KeychainStore` defaults to for BYO API
/// keys. The tradeoff differs by what the secret protects: an API key can be
/// retyped after a machine migration, so refusing to migrate it costs the user
/// nothing. A clipboard history cannot be retyped — a key that refuses to
/// migrate turns a restored backup into unrecoverable ciphertext, which is the
/// precise failure mode a backup exists to prevent.
enum ClipboardKeyStore {

    static let service = "com.matt.voice-dictation.clipboard"
    static let account = "blob-encryption-key"

    /// Returns nil only when the Keychain definitively reports no item.
    static func loadKey(keychain: KeychainStore) throws -> SymmetricKey? {
        guard let encoded = try keychain.readKey(for: account) else { return nil }
        guard let raw = Data(base64Encoded: encoded), raw.count == 32 else {
            throw ClipboardCryptoError.keyUnavailable
        }
        return SymmetricKey(data: raw)
    }

    /// Creates a fresh 256-bit key and persists it. Throws when the Keychain
    /// refuses the write — callers must not fall back to storing plaintext.
    static func createKey(keychain: KeychainStore) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let encoded = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        if try keychain.addKeyIfAbsent(
            encoded,
            for: account,
            accessibility: kSecAttrAccessibleAfterFirstUnlock
        ) {
            return key
        }
        guard let existing = try loadKey(keychain: keychain) else {
            throw ClipboardCryptoError.keyUnavailable
        }
        return existing
    }
}
