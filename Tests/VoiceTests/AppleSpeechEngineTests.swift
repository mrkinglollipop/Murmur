import AVFoundation
import Speech
import XCTest
@testable import Voice

final class AppleSpeechEngineTests: XCTestCase {

    func testAppleLocalModelUsesStableStoredIDAndBuiltInDisplayName() {
        XCTAssertEqual(LocalModel.appleSpeech.rawValue, "appleSpeech")
        XCTAssertEqual(LocalModel.appleSpeech.displayName, "Apple (built in)")
        XCTAssertEqual(LocalModel.appleSpeech.engineID, .appleSpeech)
        XCTAssertNil(LocalModel.appleSpeech.whisperKitModelID)
    }

    func testLocalModelCodableRoundTripsEveryStoredCase() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for model in LocalModel.allCases {
            XCTAssertEqual(try decoder.decode(LocalModel.self, from: encoder.encode(model)), model)
        }
    }

    func testStoredLocalSelectionAlwaysWinsOverEveryFreshInstallSignal() {
        for stored in LocalModel.allCases {
            for hasStoredCloudSelection in [false, true] {
                for hasCloudKey in [false, true] {
                    for downloadedLocalModel in [nil] + LocalModel.allCases.map(Optional.some) {
                        XCTAssertEqual(
                            SettingsStore.initialLocalModel(
                                storedRawValue: stored.rawValue,
                                hasStoredCloudSelection: hasStoredCloudSelection,
                                hasCloudKey: hasCloudKey,
                                downloadedLocalModel: downloadedLocalModel
                            ),
                            stored
                        )
                    }
                }
            }
        }
    }

    func testFreshInstallSelectsAppleOnlyWithoutPriorCloudOrDownloadedModel() {
        for hasStoredCloudSelection in [false, true] {
            for hasCloudKey in [false, true] {
                for downloadedLocalModel in [nil] + LocalModel.allCases.map(Optional.some) {
                    let model = SettingsStore.initialLocalModel(
                        storedRawValue: nil,
                        hasStoredCloudSelection: hasStoredCloudSelection,
                        hasCloudKey: hasCloudKey,
                        downloadedLocalModel: downloadedLocalModel
                    )
                    if let downloadedLocalModel {
                        XCTAssertEqual(model, downloadedLocalModel)
                    } else if !hasStoredCloudSelection && !hasCloudKey {
                        XCTAssertEqual(model, .appleSpeech)
                    } else {
                        XCTAssertEqual(model, .default)
                    }
                }
            }
        }
        XCTAssertEqual(
            SettingsStore.initialLocalModel(
                storedRawValue: "retired-model",
                hasStoredCloudSelection: false,
                hasCloudKey: false,
                downloadedLocalModel: nil
            ),
            .default
        )
    }

    func testAppleEngineHistoryDisplayName() {
        XCTAssertEqual(EngineDisplayName.displayName(for: "appleSpeech"), "Apple")
    }

    func testFinalTranscriptSegmentsAreAppendedInOrder() {
        var transcript = ""
        for segment in ["First sentence.", "Second sentence."] {
            transcript = AppleSpeechEngine.appendingFinalSegment(segment, to: transcript)
        }
        XCTAssertEqual(transcript, "First sentence. Second sentence.")
    }
}

@MainActor
final class AppleSpeechAssetRegressionTests: XCTestCase {
    func testMissingAssetReachesHUDAndRetainsHistoryAudioForRetry() throws {
        let url = try makeAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try Data(contentsOf: url)
        let selector = ASREngineSelector()
        selector.cleanupEnabled = false
        let pipeline = selector.pipeline
        pipeline.localEngineProvider = {
            AppleSpeechEngine(transcribeAudio: { _, language in
                throw AppleSpeechEngineError.assetNotInstalled(language: language)
            })
        }
        var messages: [String] = []
        pipeline.onFailure = { messages.append($0.message) }
        var logged = 0
        pipeline.onTranscriptionLogged = { text, engine, inserted, path, failed, replacement in
            XCTAssertEqual(text, "")
            XCTAssertEqual(engine, "appleSpeech")
            XCTAssertFalse(inserted)
            XCTAssertEqual(path, url.path)
            XCTAssertTrue(failed)
            XCTAssertNil(replacement)
            logged += 1
        }
        let done = expectation(description: "missing asset recorded in history")
        pipeline.transcribeAndLog(audioURL: url, sessionHeldToken: pipeline.test_holdSnapshot(.unknown)) { result in
            XCTAssertEqual(result, .failed)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(messages, ["Speech model still downloading"])
        XCTAssertEqual(logged, 1)
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        let replacement = UUID()
        pipeline.localEngineProvider = { AppleSpeechEngine(transcribeAudio: { _, _ in "Recovered speech." }) }
        pipeline.onTranscriptionLogged = { text, engine, inserted, path, failed, id in
            XCTAssertEqual(text, "Recovered speech.")
            XCTAssertEqual(engine, "appleSpeech")
            XCTAssertFalse(inserted)
            XCTAssertEqual(path, url.path)
            XCTAssertFalse(failed)
            XCTAssertEqual(id, replacement)
            logged += 1
        }
        let retried = expectation(description: "same audio retried")
        pipeline.transcribeAndLog(audioURL: url, replaceHistoryEntryID: replacement) { result in
            XCTAssertEqual(result, .savedToHistory)
            retried.fulfill()
        }
        wait(for: [retried], timeout: 5)
        XCTAssertEqual(logged, 2)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testLanguageSwitchReleasesOldReservationsBeforeRequestingNewAsset() async {
        let inventory = FakeAppleSpeechInventory(reservations: ["en-US", "fr-FR"], limit: 2)
        let manager = ModelManager(loadDiskState: false, appleSpeechInventory: inventory)
        let requested = expectation(description: "new locale request")
        inventory.onRequest = { requested.fulfill() }
        manager.updateAppleSpeechLanguage("de")
        manager.downloadIfNeeded(.appleSpeech)
        await fulfillment(of: [requested], timeout: 5)
        XCTAssertEqual(inventory.events, ["release:en-US", "release:fr-FR", "request:de-DE"])
        XCTAssertEqual(inventory.reservations, [Locale(identifier: "de-DE")])
        XCTAssertEqual(inventory.capacityFailures, 0)
    }

    func testActiveTranscriptionsKeepReservationUntilLastDecoderFinishes() async throws {
        let url = try makeAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = AppleSpeechAssetUsage()
        let inventory = FakeAppleSpeechInventory(reservations: ["en-US", "fr-FR"], limit: 2)
        let manager = ModelManager(loadDiskState: false, appleSpeechInventory: inventory, appleSpeechUsage: usage)
        let firstGate = AppleDecodeGate()
        let secondGate = AppleDecodeGate()
        let firstStarted = expectation(description: "first decoder started")
        let secondStarted = expectation(description: "second decoder started")
        let first = AppleSpeechEngine(transcribeAudio: { _, _ in
            firstStarted.fulfill()
            return try await firstGate.value()
        }, assetUsage: usage)
        let second = AppleSpeechEngine(transcribeAudio: { _, _ in
            secondStarted.fulfill()
            return try await secondGate.value()
        }, assetUsage: usage)
        let firstTask = Task { try await first.transcribe(audioURL: url) }
        let secondTask = Task { try await second.transcribe(audioURL: url) }
        await fulfillment(of: [firstStarted, secondStarted], timeout: 5)

        await request("de", manager: manager, inventory: inventory)
        XCTAssertEqual(inventory.events, ["release:fr-FR", "request:de-DE"])
        XCTAssertTrue(inventory.reservations.contains(Locale(identifier: "en-US")))

        await firstGate.resolve(.failure(AppleSpeechEngineError.assetNotInstalled(language: "en")))
        _ = await firstTask.result
        inventory.events = []
        await request("es", manager: manager, inventory: inventory)
        XCTAssertEqual(inventory.events, ["release:de-DE", "request:es-ES"])
        XCTAssertTrue(inventory.reservations.contains(Locale(identifier: "en-US")))

        await secondGate.resolve(.success("Done."))
        _ = await secondTask.result
        inventory.events = []
        await request("fr", manager: manager, inventory: inventory)
        XCTAssertEqual(inventory.events, ["release:en-US", "release:es-ES", "request:fr-FR"])
        XCTAssertEqual(inventory.capacityFailures, 0)
    }

    func testSelectedLocaleAliasIsRetained() async {
        let inventory = FakeAppleSpeechInventory(reservations: ["en-US", "fr-FR"], limit: 2)
        let manager = ModelManager(loadDiskState: false, appleSpeechInventory: inventory,
                                   appleSpeechUsage: AppleSpeechAssetUsage())
        await request("en", manager: manager, inventory: inventory)
        XCTAssertEqual(inventory.events, ["release:fr-FR", "request:en-US"])
        XCTAssertEqual(inventory.reservations, [Locale(identifier: "en-US")])
    }

    private func request(_ language: String, manager: ModelManager, inventory: FakeAppleSpeechInventory) async {
        let requested = expectation(description: "requested \(language)")
        inventory.onRequest = { requested.fulfill() }
        manager.updateAppleSpeechLanguage(language)
        manager.downloadIfNeeded(.appleSpeech)
        await fulfillment(of: [requested], timeout: 5)
    }

    private func makeAudio() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".apple-test-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0.25, count: 800)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

@MainActor
private final class FakeAppleSpeechInventory: AppleSpeechAssetInventory {
    var reservations: [Locale]
    let limit: Int
    var events: [String] = []
    var capacityFailures = 0
    var onRequest: (() -> Void)?

    init(reservations: [String], limit: Int) {
        self.reservations = reservations.map(Locale.init(identifier:))
        self.limit = limit
    }

    func locale(for language: String) async throws -> Locale {
        Locale(identifier: ["en": "en-US", "fr": "fr-FR", "de": "de-DE", "es": "es-ES"][language] ?? language)
    }

    func status(for locale: Locale) async -> AssetInventory.Status { .supported }
    var reservedLocales: [Locale] { get async { reservations } }

    func release(_ locale: Locale) async {
        events.append("release:\(locale.identifier)")
        reservations.removeAll { $0 == locale }
    }

    func installationRequest(for locale: Locale) async throws -> AssetInstallationRequest? {
        events.append("request:\(locale.identifier)")
        defer { onRequest?() }
        if !reservations.contains(locale) {
            guard reservations.count < limit else {
                capacityFailures += 1
                throw NSError(domain: "FakeAssetCapacity", code: 1)
            }
            reservations.append(locale)
        }
        return nil
    }
}

private actor AppleDecodeGate {
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    func value() async throws -> String {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resolve(_ result: Result<String, Error>) {
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
