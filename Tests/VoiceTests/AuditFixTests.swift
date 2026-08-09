import XCTest
@testable import Voice

/// Covers the pure seams introduced or corrected by the 024 audit fix pass.
final class AuditFixTests: XCTestCase {

    // MARK: - Transform backend selection (F-27)

    func testOrderedBackends_putsThePreferredBackendFirst() {
        for preferred in CleanupBackend.allCases {
            let ordered = TransformRunner.orderedBackends(preferring: preferred)
            XCTAssertEqual(ordered.first, preferred)
            XCTAssertEqual(Set(ordered), Set(CleanupBackend.allCases))
            XCTAssertEqual(ordered.count, CleanupBackend.allCases.count, "no duplicates")
        }
    }

    func testTransformCredentials_cloudNeedsAnOpenAIKey() {
        XCTAssertFalse(
            TransformCredentials(backend: .cloud, openAIKey: nil, xaiKey: "xai-key").backendAvailable
        )
        XCTAssertFalse(
            TransformCredentials(backend: .cloud, openAIKey: "", xaiKey: "xai-key").backendAvailable
        )
        XCTAssertTrue(
            TransformCredentials(backend: .cloud, openAIKey: "sk-key", xaiKey: nil).backendAvailable
        )
    }

    /// xAI was previously not a Transform backend at all, so a user with only an
    /// xAI key configured could not run one.
    func testTransformCredentials_xaiGrokIsAvailableWithOnlyAnXAIKey() {
        XCTAssertTrue(
            TransformCredentials(backend: .xaiGrok, openAIKey: nil, xaiKey: "xai-key").backendAvailable
        )
        XCTAssertFalse(
            TransformCredentials(backend: .xaiGrok, openAIKey: "sk-key", xaiKey: nil).backendAvailable
        )
    }

    func testTransformCredentials_unavailablePlaceholderHasNoKeys() {
        XCTAssertNil(TransformCredentials.unavailable.openAIKey)
        XCTAssertNil(TransformCredentials.unavailable.xaiKey)
        XCTAssertEqual(TransformCredentials.unavailable.backend, .onDevice)
    }

    // MARK: - Menu-bar version line (F-04)

    func testVersionMenuTitle_usesBundleValuesNotALiteral() {
        XCTAssertEqual(
            AppDelegate.versionMenuTitle(bundle: StubBundle(short: "9.9.9", build: "123")),
            "Murmur 9.9.9 (123)"
        )
    }

    func testVersionMenuTitle_fallsBackWhenBuildIsMissing() {
        XCTAssertEqual(
            AppDelegate.versionMenuTitle(bundle: StubBundle(short: "1.2.3", build: nil)),
            "Murmur 1.2.3"
        )
    }

    func testVersionMenuTitle_fallsBackWhenVersionIsMissing() {
        XCTAssertEqual(
            AppDelegate.versionMenuTitle(bundle: StubBundle(short: nil, build: "7")),
            "Murmur"
        )
    }

    /// The literal it replaced said "v0.1" through twenty-eight releases.
    func testVersionMenuTitle_neverEmitsTheOldLiteral() {
        let title = AppDelegate.versionMenuTitle(bundle: StubBundle(short: "0.1.28", build: "29"))
        XCTAssertNotEqual(title, "Murmur v0.1")
        XCTAssertTrue(title.contains("0.1.28"))
    }

    // MARK: - Hotkey outcome (F-25 / F-26)

    func testHotkeyOutcome_distinguishesSuccessFromFailure() {
        XCTAssertNotEqual(
            HotkeyController.HotkeyOutcome.copiedToClipboard,
            .failed("No dictation or transform available")
        )
        XCTAssertEqual(
            HotkeyController.HotkeyOutcome.failed("boom"),
            .failed("boom")
        )
    }
}

/// Minimal `Bundle` stand-in for the version-title seam — subclassing `Bundle`
/// and overriding `infoDictionary` avoids needing a real bundle on disk.
private final class StubBundle: Bundle, @unchecked Sendable {
    private let stubInfo: [String: Any]

    init(short: String?, build: String?) {
        var info: [String: Any] = [:]
        if let short { info["CFBundleShortVersionString"] = short }
        if let build { info["CFBundleVersion"] = build }
        self.stubInfo = info
        super.init()
    }

    override var infoDictionary: [String: Any]? { stubInfo }
}
