import AppKit
import XCTest
@testable import Voice

/// Plan 034 slice B: HUD notice, status-menu item, Settings "Check now".
@MainActor
final class ProviderOutageSurfaceTests: XCTestCase {

    private func content(_ hud: RecordingHUD) throws -> NSView {
        try XCTUnwrap(Mirror(reflecting: hud).children.first(where: { $0.label == "waveformView" })?.value as? NSView)
    }

    private func interimLabel(_ view: NSView) throws -> NSTextField {
        try XCTUnwrap(Mirror(reflecting: view).children.first(where: { $0.label == "interimLabel" })?.value as? NSTextField)
    }

    private func notice(_ kind: CloudFailureKind = .billing, provider: CloudProvider = .elevenLabs) -> ProviderNotice {
        ProviderNotice(provider: provider, kind: kind, lastRejection: Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: HUD

    func testHUDShowsAmberNoticeAtHoldStartAndThroughProcessing() throws {
        let hud = RecordingHUD(presentsWindows: false)
        defer { hud.hide() }
        let view = try content(hud)
        let label = try interimLabel(view)

        hud.setProviderNotice(notice())
        hud.show()
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(label.stringValue, "ElevenLabs: payment needed\nUsing on-device · may be slower")
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(hud.currentState, .listening, "Notice is an overlay, never a blocking state")
        XCTAssertEqual(label.accessibilityLabel(), "ElevenLabs: payment needed. Using on-device · may be slower")

        hud.setProcessing()
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(hud.isProcessing, "Processing semantics are unchanged")
        XCTAssertEqual(label.stringValue, "ElevenLabs: payment needed\nUsing on-device · may be slower")
    }

    func testHUDNoticeClearsBackToNormalLabels() throws {
        let hud = RecordingHUD(presentsWindows: false)
        defer { hud.hide() }
        let view = try content(hud)
        let label = try interimLabel(view)

        hud.show()
        hud.setProviderNotice(notice(.auth))
        XCTAssertEqual(label.stringValue, "ElevenLabs: key rejected\nUsing on-device · may be slower")
        hud.setProviderNotice(nil)
        XCTAssertTrue(label.isHidden)
        XCTAssertEqual(label.stringValue, "")

        hud.setProcessing()
        XCTAssertEqual(label.stringValue, "Transcribing…")
        hud.setProviderNotice(notice(.rateLimited, provider: .xai))
        XCTAssertEqual(label.stringValue, "xAI: rate limited\nUsing on-device · may be slower")
        hud.setProviderNotice(nil)
        XCTAssertEqual(label.stringValue, "Transcribing…")
    }

    // MARK: Menu

    func testStatusMenuGainsOutageItemAtTopThatOpensRemedyURL() throws {
        let plain = AppDelegate.makeStatusMenu(
            versionTitle: "Murmur 1.0", isPaused: false, updateTitle: "Check for Updates…",
            updatesEnabled: true, target: nil, updater: nil)
        XCTAssertEqual(plain.items.first?.title, "Murmur 1.0")

        let menu = AppDelegate.makeStatusMenu(
            versionTitle: "Murmur 1.0", isPaused: false, updateTitle: "Check for Updates…",
            updatesEnabled: true, target: nil, updater: nil, outage: notice())
        XCTAssertEqual(menu.items.first?.title, "ElevenLabs: payment needed — Open billing…")
        XCTAssertEqual(menu.items.first?.representedObject as? URL, CloudProvider.elevenLabs.billingURL)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "Murmur 1.0")

        let auth = AppDelegate.makeStatusMenu(
            versionTitle: "Murmur", isPaused: false, updateTitle: "Check for Updates…",
            updatesEnabled: true, target: nil, updater: nil, outage: notice(.auth))
        XCTAssertEqual(auth.items.first?.title, "ElevenLabs: key rejected — Open key page…")
        XCTAssertEqual(auth.items.first?.representedObject as? URL, CloudProvider.elevenLabs.signupURL)

        let limited = AppDelegate.makeStatusMenu(
            versionTitle: "Murmur", isPaused: false, updateTitle: "Check for Updates…",
            updatesEnabled: true, target: nil, updater: nil, outage: notice(.rateLimited))
        XCTAssertEqual(limited.items.first?.title, "Murmur", "A 60 s rate-limit pause is not an outage item")
    }

    // MARK: Check now

    private struct FakeService: CloudTranscriptionService {
        let result: Result<String, Error>
        func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
            // The test clip really is a readable WAV.
            XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
            return try result.get()
        }
    }

    private func withStore(key: String?, check: (SettingsStore) async throws -> Void) async throws {
        let suite = "murmur.outage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(LocalModel.appleSpeech.rawValue, forKey: "voice.settings.selectedLocalModel")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(
            defaults: defaults, profileDirectory: FileManager.default.temporaryDirectory,
            keychain: KeychainStore(service: "com.matt.voice-dictation.apikeys.TESTS"),
            apiKeyLookup: { _ in key })
        let selector = ASREngineSelector()
        selector.providerHealth = ProviderHealthStore(postsNotifications: false)
        store.asrEngineSelector = selector
        try await check(store)
    }

    func testCheckNowPassesOnEmptyTranscriptAndClearsNotice() async throws {
        try await withStore(key: "dummy-test-key") { store in
            store.providerHealth.recordFailure(.elevenLabs, kind: .billing)
            XCTAssertNotNil(store.refusalNotice(for: .elevenLabs))
            store.checkServiceProvider = { _ in FakeService(result: .failure(CloudTranscriptionError.emptyTranscript(provider: .elevenLabs))) }
            let result = await store.checkProvider(.elevenLabs)
            XCTAssertEqual(result, .ok)
            XCTAssertNil(store.refusalNotice(for: .elevenLabs))
        }
    }

    func testCheckNowReportsClassifiedRejection() async throws {
        try await withStore(key: "dummy-test-key") { store in
            let body = #"{"detail":{"type":"payment_required","code":"payment_issue"}}"#
            store.checkServiceProvider = { _ in
                FakeService(result: .failure(CloudTranscriptionError.httpStatus(401, provider: .elevenLabs, body: body)))
            }
            let result = await store.checkProvider(.elevenLabs)
            XCTAssertEqual(result, .rejected(.billing))
            XCTAssertEqual(store.refusalNotice(for: .elevenLabs)?.kind, .billing)
        }
    }

    func testCheckNowTransientDoesNotChangeHealthAndNoKeyIsReported() async throws {
        try await withStore(key: "dummy-test-key") { store in
            store.checkServiceProvider = { _ in FakeService(result: .failure(URLError(.timedOut))) }
            let result = await store.checkProvider(.elevenLabs)
            guard case .failed = result else { return XCTFail("expected failed, got \(result)") }
            XCTAssertNil(store.refusalNotice(for: .elevenLabs))
        }
        try await withStore(key: nil) { store in
            let result = await store.checkProvider(.elevenLabs)
            XCTAssertEqual(result, .noKey)
        }
    }

    func testSilentClipIsAValidOneSecondWAV() throws {
        let data = SettingsStore.silentWAV(seconds: 1)
        XCTAssertEqual(data.count, 44 + 32_000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outage-\(UUID().uuidString).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let wav = try CloudAudioTranscoder.wavUploadPayload(from: url)
        XCTAssertFalse(wav.data.isEmpty)
    }
}
