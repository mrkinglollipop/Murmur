import AppKit
import XCTest
@testable import Voice

/// Covers the pure seams introduced or corrected by the 024 audit fix pass.
final class AuditFixTests: XCTestCase {

    // MARK: - Transform backend selection (F-27)

    func testOrderedBackends_onDeviceNeverFallsBackToCloud() {
        XCTAssertEqual(TransformRunner.orderedBackends(preferring: .onDevice), [.onDevice])
    }

    func testOrderedBackends_cloudSelectionsKeepConfiguredFallbacks() {
        for preferred in [CleanupBackend.cloud, .xaiGrok] {
            let ordered = TransformRunner.orderedBackends(preferring: preferred)
            XCTAssertEqual(ordered.first, preferred)
            XCTAssertEqual(Set(ordered), Set(CleanupBackend.allCases))
            XCTAssertEqual(ordered.count, CleanupBackend.allCases.count, "no duplicates")
        }
    }

    func testUnavailableOnDeviceTransformExplainsPrivacyBoundary() {
        let message = TransformRunnerError.onDeviceUnavailable.localizedDescription
        XCTAssertTrue(message.contains("on-device model is unavailable"))
        XCTAssertTrue(message.contains("no text was sent to a cloud backend"))
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

    // MARK: - Per-app style target

    @MainActor
    func testStyleTargetSkipsNonRegularAppsAndMurmur() {
        for policy in [NSApplication.ActivationPolicy.accessory, .prohibited] {
            XCTAssertNil(StyleStore.externalApp(
                bundleID: "com.apple.SecurityAgent", name: "SecurityAgent",
                activationPolicy: policy, ownBundleID: "com.matt.voice-dictation"
            ))
        }
        XCTAssertNil(StyleStore.externalApp(
            bundleID: "com.matt.voice-dictation", name: "Murmur",
            activationPolicy: .regular, ownBundleID: "com.matt.voice-dictation"
        ))
        XCTAssertNil(StyleStore.externalApp(
            bundleID: nil, name: "Unknown", activationPolicy: .regular
        ))
    }

    @MainActor
    func testStyleTargetKeepsRegularExternalAppsAndNameFallback() {
        XCTAssertEqual(StyleStore.externalApp(
            bundleID: "com.example.editor", name: "Editor", activationPolicy: .regular
        ), StyleStore.ExternalApp(bundleID: "com.example.editor", name: "Editor"))
        XCTAssertEqual(StyleStore.externalApp(
            bundleID: "com.example.editor", name: nil, activationPolicy: .regular
        ), StyleStore.ExternalApp(bundleID: "com.example.editor", name: "com.example.editor"))
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

    // MARK: - Review 030 UI helpers

    func testReview030SettingsSectionMembershipIsExclusiveAndComplete() {
        let expected: [SettingsSection: Set<String>] = [
            .general: ["Activation", "System", "Voice"],
            .engine: ["Transcription Engine", "Language", "Local Model", "Cloud Model"],
            .text: ["Cleanup", "Dictation text"],
            .storage: ["Storage"],
            .permissions: ["Permissions"],
            .about: ["What's New", "Acknowledgements"],
        ]
        for (section, cards) in expected {
            for card in cards { XCTAssertTrue(SettingsSection.contains(card, in: section)) }
        }
        XCTAssertFalse(SettingsSection.contains("Cloud Model", in: .general))
        XCTAssertFalse(SettingsSection.contains("Voice", in: .about))
    }

    func testReview030StorageSummaryPluralAndFullCap() {
        XCTAssertEqual(SettingsView.storageSummary(fileCount: 1, usageBytes: 10_000_000, budgetMB: 200), "Retained audio: 1 file · 10 MB of 200 MB")
        XCTAssertEqual(SettingsView.storageSummary(fileCount: 114, usageBytes: 209_500_000, budgetMB: 200), "Retained audio: 114 files · 200 MB, full")
    }

    func testReview030PermissionSnapshotOnlyCompletesWhenAllThreeGranted() {
        for microphone in [false, true] {
            for accessibility in [false, true] {
                for inputMonitoring in [false, true] {
                    let snapshot = PermissionSnapshot(microphone: microphone, accessibility: accessibility, inputMonitoring: inputMonitoring)
                    XCTAssertEqual(snapshot.allGranted, microphone && accessibility && inputMonitoring)
                }
            }
        }
    }

    func testReview030InsightsStreakExpiresWhenLatestEntryIsOlderThanYesterday() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        XCTAssertEqual(InsightsView.dayStreak(activeDays: [twoDaysAgo], today: today, calendar: calendar), 0)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        XCTAssertEqual(InsightsView.dayStreak(activeDays: [today], today: today, calendar: calendar), 1)
        XCTAssertEqual(InsightsView.dayStreak(activeDays: [yesterday], today: today, calendar: calendar), 1)
        XCTAssertEqual(InsightsView.dayStreak(activeDays: [tomorrow], today: today, calendar: calendar), 0)
    }

    func testReview030InsightsQuantilesHaveFourPositiveStepsAndLocaleGrouping() {
        let counts = [1, 10, 100, 1_000]
        XCTAssertEqual(counts.map { InsightsView.heatmapIntensity(for: $0, positiveWordCounts: counts) }, [1, 2, 3, 4])
        XCTAssertEqual(InsightsView.heatmapIntensity(for: 0, positiveWordCounts: counts), 0)
        XCTAssertEqual(InsightsView.heatmapIntensity(for: 10, positiveWordCounts: [10, 10, 10, 10]), 1)
        XCTAssertEqual(InsightsView.heatmapIntensity(for: 10, positiveWordCounts: []), 1)
        XCTAssertEqual(InsightsView.groupedInteger(25_281, locale: Locale(identifier: "en_US")), "25,281")
        XCTAssertEqual(InsightsView.groupedInteger(25_281, locale: Locale(identifier: "de_DE")), "25.281")
    }

    func testReview030PausedHotkeyAndActivationPassThrough() {
        XCTAssertTrue(HotkeyController.shouldRegisterHotkey(isPaused: false))
        XCTAssertFalse(HotkeyController.shouldRegisterHotkey(isPaused: true))
        XCTAssertTrue(ActivationController.shouldProcessActivationEvent(isPaused: false, hasActiveRecording: false))
        XCTAssertFalse(ActivationController.shouldProcessActivationEvent(isPaused: true, hasActiveRecording: false))
        XCTAssertTrue(ActivationController.shouldProcessActivationEvent(isPaused: true, hasActiveRecording: true))
    }

    func testReview030PauseClearsPendingFnStateButPreservesRecording() {
        var pending = FnActivationLogic.State(
            isRecording: false,
            isToggleLocked: false,
            firstTapAnchor: Date(),
            fnPhysicallyDown: true,
            holdDeadline: Date().addingTimeInterval(FnActivationLogic.holdThreshold)
        )
        FnActivationLogic.prepareForPause(state: &pending)
        XCTAssertNil(pending.firstTapAnchor)
        XCTAssertNil(pending.holdDeadline)
        XCTAssertFalse(pending.fnPhysicallyDown)

        var recording = FnActivationLogic.State(isRecording: true, fnPhysicallyDown: true)
        FnActivationLogic.prepareForPause(state: &recording)
        XCTAssertTrue(recording.isRecording)
        XCTAssertTrue(recording.fnPhysicallyDown)
    }

    @MainActor
    func testReview030StatusMenuBuildsRequiredTitlesKeysEnabledStateAndPauseToggle() {
        let menu = AppDelegate.makeStatusMenu(versionTitle: "Murmur 9.9.9", isPaused: false, updateTitle: "Check for Updates…", updatesEnabled: false, target: nil, updater: nil)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["Murmur 9.9.9", "Open Murmur", "Settings…", "Pause dictation", "Check for Updates…", "Quit Murmur"])
        XCTAssertEqual(menu.item(withTitle: "Settings…")?.keyEquivalent, ",")
        XCTAssertEqual(menu.item(withTitle: "Settings…")?.keyEquivalentModifierMask, .command)
        XCTAssertFalse(menu.item(withTitle: "Check for Updates…")?.isEnabled ?? true)
        XCTAssertEqual(menu.item(withTitle: "Quit Murmur")?.keyEquivalent, "q")
        let resumed = AppDelegate.makeStatusMenu(versionTitle: "Murmur", isPaused: true, updateTitle: "Check for Updates…", updatesEnabled: true, target: nil, updater: nil)
        XCTAssertNotNil(resumed.item(withTitle: "Resume dictation"))
        XCTAssertTrue(resumed.item(withTitle: "Check for Updates…")?.isEnabled ?? false)
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
