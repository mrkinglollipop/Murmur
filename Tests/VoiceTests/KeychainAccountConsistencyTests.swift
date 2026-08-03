import XCTest
import Security
@testable import Voice

/// Regression guard for the Settings-write / engine-read Keychain path.
///
/// Both `SettingsStore.saveAPIKey` and `ASREngineSelector`'s
/// `apiKeyProvider` closure resolve the ElevenLabs (and every other
/// provider's) Keychain account through `CloudProvider.keychainAccount` —
/// never a string literal — and `KeychainStore` builds every operation's
/// query through the single `baseQuery(service:account:)` helper, so write
/// and read can no longer diverge on either the account string or the store
/// configuration.
///
/// The actual root cause fixed 2026-07-09: `kSecUseDataProtectionKeychain`
/// was added to `setKey` (and eventually to reads/deletes too), but this
/// Developer-ID app has no `keychain-access-groups`/`application-identifier`
/// entitlement, so `SecItemAdd` returned `errSecMissingEntitlement (-34018)`
/// and every key save was silently discarded. The flag has been removed
/// entirely; the legacy login keychain is the only store this app can use.
/// There is no dual-store or migration design — there never was one.
final class KeychainAccountConsistencyTests: XCTestCase {
    /// ISOLATED test service — NEVER KeychainStore's default. Round-trip tests
    /// write and delete real Keychain items; using the production service here
    /// overwrote and then deleted the user's live xAI API key on 2026-07-09.
    private let store = KeychainStore(service: "com.matt.voice-dictation.apikeys.TESTS")

    override func tearDown() {
        store.deleteKey(for: CloudProvider.elevenLabs.keychainAccount)
        store.deleteKey(for: CloudProvider.xai.keychainAccount)
        super.tearDown()
    }

    // MARK: - Structural: query builder can't diverge (deterministic, no Keychain I/O)

    /// Regression guard: ensures `baseQuery` does NOT include the
    /// `kSecUseDataProtectionKeychain` flag. Adding that flag without also
    /// adding the `keychain-access-groups`/`application-identifier` entitlement
    /// causes every `SecItemAdd` to fail with -34018 (errSecMissingEntitlement),
    /// silently discarding all key saves. Do NOT re-add this flag without first
    /// adding the required entitlement and a provisioning profile.
    func testBaseQueryNeverIncludesDataProtectionKeychainSelector() {
        let query = KeychainStore.baseQuery(service: "svc", account: CloudProvider.elevenLabs.keychainAccount)
        XCTAssertNil(query[kSecUseDataProtectionKeychain as String],
                     "kSecUseDataProtectionKeychain must not appear in baseQuery — this app lacks the required entitlement and the flag causes silent save failures (-34018)")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, CloudProvider.elevenLabs.keychainAccount)
    }

    func testBaseQueryIsIdenticalForEveryAccountItsUsedWith() {
        let elevenLabsQuery = KeychainStore.baseQuery(service: "svc", account: CloudProvider.elevenLabs.keychainAccount)
        let xaiQuery = KeychainStore.baseQuery(service: "svc", account: CloudProvider.xai.keychainAccount)
        // Neither query should contain the DP store selector; both should be nil equally.
        XCTAssertNil(elevenLabsQuery[kSecUseDataProtectionKeychain as String],
                     "elevenLabs query must not include DP store selector")
        XCTAssertNil(xaiQuery[kSecUseDataProtectionKeychain as String],
                     "xai query must not include DP store selector")
        // Shared structural keys must agree across providers.
        XCTAssertEqual(elevenLabsQuery[kSecClass as String] as? String,
                       xaiQuery[kSecClass as String] as? String,
                       "kSecClass must not vary per-provider")
        XCTAssertEqual(elevenLabsQuery[kSecAttrService as String] as? String,
                       xaiQuery[kSecAttrService as String] as? String,
                       "kSecAttrService must not vary per-provider")
    }

    func testProviderAccountsAreDistinct() {
        XCTAssertNotEqual(CloudProvider.elevenLabs.keychainAccount, CloudProvider.xai.keychainAccount)
    }

    // MARK: - Live round trip (legacy keychain — no entitlement required)

    /// Proves the actual write path (`setKey`, as `SettingsStore.saveAPIKey`
    /// calls it) and read path (`key(for:)`, as `ASREngineSelector`'s
    /// `apiKeyProvider` calls it) agree, through the real `KeychainStore`.
    /// Runs unconditionally — the legacy login keychain does not require any
    /// entitlement, so this works under `CODE_SIGNING_ALLOWED=NO` too.
    func testElevenLabsKeyRoundTripsThroughSharedAccountConstant() {
        let account = CloudProvider.elevenLabs.keychainAccount
        XCTAssertEqual(account, CloudProvider.elevenLabs.rawValue, "keychainAccount must not drift from the provider's raw value")

        let dummy = "dummy-elevenlabs-key-\(UUID().uuidString)"
        store.setKey(dummy, for: account)

        XCTAssertEqual(store.key(for: account), dummy, "value saved under CloudProvider.elevenLabs.keychainAccount must read back identically")
    }

    /// Same round trip for xAI, proving the fix lives in the shared
    /// `KeychainStore` (not a per-provider path) — see class doc.
    func testXAIKeyRoundTripsThroughSharedAccountConstant() {
        let account = CloudProvider.xai.keychainAccount
        let dummy = "dummy-xai-key-\(UUID().uuidString)"
        store.setKey(dummy, for: account)

        XCTAssertEqual(store.key(for: account), dummy)
    }
}
