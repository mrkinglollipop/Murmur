import XCTest
@testable import Voice

/// Plan 034: classify provider refusals, remember them in memory, and skip
/// cloud while a provider is refusing. No Keychain, no network, no real key.
final class ProviderOutageTests: XCTestCase {

    // MARK: - Fixtures

    /// Real ElevenLabs body from 2026-10-26 (HTTP 401).
    private let elevenLabsPaymentBody = #"{"detail":{"type":"payment_required","code":"payment_issue","message":"Your subscription has a failed or incomplete payment. Complete the latest invoice to continue usage.","status":"payment_issue"}}"#
    private let invalidKeyBody = #"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#

    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    private func makeStore(_ clock: Clock) -> ProviderHealthStore {
        ProviderHealthStore(now: { clock.date }, postsNotifications: false)
    }

    // MARK: - Classifier

    func testElevenLabsPaymentIssue401IsBilling() {
        XCTAssertEqual(CloudFailureClassifier.classify(status: 401, body: elevenLabsPaymentBody), .billing)
        let error = CloudTranscriptionError.httpStatus(401, provider: .elevenLabs, body: elevenLabsPaymentBody)
        XCTAssertEqual(error.kind, .billing)
        XCTAssertEqual(error.statusCode, 401)
        XCTAssertFalse(error.isProvisional)
    }

    func testInvalidKey401IsAuth() {
        XCTAssertEqual(CloudFailureClassifier.classify(status: 401, body: invalidKeyBody), .auth)
        XCTAssertEqual(CloudFailureClassifier.classify(status: 403, body: nil), .auth)
        XCTAssertEqual(CloudTranscriptionError.httpStatus(401, provider: .xai, body: invalidKeyBody).kind, .auth)
    }

    func test402IsBillingAndQuotaBodyIsBilling() {
        XCTAssertEqual(CloudFailureClassifier.classify(status: 402, body: nil), .billing)
        XCTAssertEqual(CloudFailureClassifier.classify(status: 401, body: #"{"detail":{"status":"quota_exceeded"}}"#), .billing)
    }

    func testEdgeProxy403IsTransientNotAuth() {
        let challenge = "<!DOCTYPE html><html><title>Just a moment...</title>Cloudflare challenge</html>"
        XCTAssertEqual(CloudFailureClassifier.classify(status: 403, body: challenge), .transient)
        let error = CloudTranscriptionError.httpStatus(403, provider: .xai, body: challenge)
        XCTAssertEqual(error.kind, .transient)
        let store = makeStore(Clock())
        store.recordFailure(.xai, error: error)
        XCTAssertEqual(store.state(for: .xai), .ok)
    }

    func testLateHandshakeVerdictAfterSuccessOnSameAttemptIsIgnored() {
        let clock = Clock()
        let store = makeStore(clock)
        let attemptStarted = store.timestamp()
        clock.advance(2)
        store.recordSuccess(.elevenLabs)          // batch already landed this hold
        clock.advance(1)
        store.recordFailure(.elevenLabs, error: CloudTranscriptionError.handshakeRejected(401, provider: .elevenLabs),
                            attemptStartedAt: attemptStarted)
        XCTAssertEqual(store.state(for: .elevenLabs), .ok)
        XCTAssertTrue(store.allowsStream(for: .elevenLabs))

        // A handshake verdict from an attempt that began after the success still counts.
        let nextAttempt = store.timestamp()
        clock.advance(1)
        store.recordFailure(.elevenLabs, error: CloudTranscriptionError.handshakeRejected(401, provider: .elevenLabs),
                            attemptStartedAt: nextAttempt)
        XCTAssertFalse(store.allowsStream(for: .elevenLabs))
        XCTAssertTrue(store.allowsBatch(for: .elevenLabs))
    }

    func test429IsRateLimited() {
        XCTAssertEqual(CloudFailureClassifier.classify(status: 429, body: "slow down"), .rateLimited)
        XCTAssertEqual(CloudTranscriptionError.httpStatus(429, provider: .xai).kind, .rateLimited)
    }

    func test5xxAndNetworkErrorsAreTransient() {
        XCTAssertEqual(CloudFailureClassifier.classify(status: 500, body: "boom"), .transient)
        XCTAssertEqual(CloudFailureClassifier.classify(status: 503, body: elevenLabsPaymentBody), .transient)
        XCTAssertEqual(CloudFailureClassifier.classify(status: nil, body: nil), .transient)
        XCTAssertEqual(CloudFailureClassifier.kind(of: URLError(.timedOut)), .transient)
        XCTAssertEqual(CloudTranscriptionError(provider: .xai, message: "Timed out").kind, .transient)
    }

    func testHandshakeRejectionIsProvisional() {
        let error = CloudTranscriptionError.handshakeRejected(401, provider: .elevenLabs)
        XCTAssertEqual(error.kind, .auth)
        XCTAssertEqual(error.statusCode, 401)
        XCTAssertTrue(error.isProvisional)
        XCTAssertEqual(CloudTranscriptionError.handshakeRejected(402, provider: .xai).kind, .billing)
    }

    func testErrorMessageStillRedactedAndBodyNotStored() {
        let error = CloudTranscriptionError.httpStatus(
            401, provider: .elevenLabs, body: #"{"key":"sk_0123456789abcdef0123456789abcdef payment"}"#)
        XCTAssertFalse(error.message.contains("0123456789abcdef0123456789abcdef"))
        XCTAssertEqual(error.kind, .billing)
    }

    // MARK: - Health state machine

    func testBillingRefusalBlocksStreamAndBatchUntilRetryWindow() {
        let clock = Clock()
        let store = makeStore(clock)
        XCTAssertTrue(store.allowsStream(for: .elevenLabs))

        store.recordFailure(.elevenLabs, kind: .billing)
        XCTAssertFalse(store.allowsStream(for: .elevenLabs))
        XCTAssertFalse(store.allowsBatch(for: .elevenLabs))
        XCTAssertTrue(store.allowsStream(for: .xai), "Other providers are unaffected")

        clock.advance(299)
        XCTAssertFalse(store.allowsBatch(for: .elevenLabs))
        clock.advance(1)
        XCTAssertTrue(store.allowsStream(for: .elevenLabs), "Retry fires 5 minutes after the last rejection")
        XCTAssertTrue(store.allowsBatch(for: .elevenLabs))

        // A failed retry restarts the window.
        store.recordFailure(.elevenLabs, kind: .billing)
        XCTAssertFalse(store.allowsBatch(for: .elevenLabs))
        clock.advance(299)
        XCTAssertFalse(store.allowsBatch(for: .elevenLabs))
    }

    func testSuccessClearsRefusalAndNotice() {
        let clock = Clock()
        let store = makeStore(clock)
        store.recordFailure(.elevenLabs, kind: .auth)
        XCTAssertNotNil(store.notice(for: .elevenLabs))
        store.recordSuccess(.elevenLabs)
        XCTAssertEqual(store.state(for: .elevenLabs), .ok)
        XCTAssertNil(store.notice(for: .elevenLabs))
        XCTAssertTrue(store.allowsBatch(for: .elevenLabs))
    }

    func testKeySaveClearsRefusal() {
        let clock = Clock()
        let store = makeStore(clock)
        store.recordFailure(.xai, kind: .billing)
        store.keySaved(for: .xai)
        XCTAssertEqual(store.state(for: .xai), .ok)
        XCTAssertTrue(store.allowsStream(for: .xai))
    }

    func testRateLimitSkipsForSixtySecondsOnly() {
        let clock = Clock()
        let store = makeStore(clock)
        store.recordFailure(.xai, kind: .rateLimited)
        XCTAssertFalse(store.allowsBatch(for: .xai))
        XCTAssertEqual(store.notice(for: .xai)?.kind, .rateLimited)
        clock.advance(59)
        XCTAssertFalse(store.allowsStream(for: .xai))
        clock.advance(1)
        XCTAssertTrue(store.allowsStream(for: .xai))
        XCTAssertNil(store.notice(for: .xai))
    }

    func testTransientFailureChangesNothing() {
        let clock = Clock()
        let store = makeStore(clock)
        store.recordFailure(.elevenLabs, kind: .transient)
        XCTAssertEqual(store.state(for: .elevenLabs), .ok)
        XCTAssertTrue(store.allowsStream(for: .elevenLabs))
        XCTAssertNil(store.notice(for: .elevenLabs))
        store.recordFailure(.elevenLabs, error: URLError(.notConnectedToInternet))
        XCTAssertEqual(store.state(for: .elevenLabs), .ok)
    }

    func testProvisionalHandshakeBlocksStreamButLetsOneBatchConfirm() {
        let clock = Clock()
        let store = makeStore(clock)
        store.recordFailure(.elevenLabs, error: CloudTranscriptionError.handshakeRejected(401, provider: .elevenLabs))
        XCTAssertFalse(store.allowsStream(for: .elevenLabs))
        XCTAssertTrue(store.allowsBatch(for: .elevenLabs), "Same-hold batch must be able to confirm")

        // The batch body makes it final: billing, and now batch is blocked too.
        store.recordFailure(.elevenLabs, error:
            CloudTranscriptionError.httpStatus(401, provider: .elevenLabs, body: elevenLabsPaymentBody))
        XCTAssertEqual(store.notice(for: .elevenLabs)?.kind, .billing)
        XCTAssertFalse(store.allowsBatch(for: .elevenLabs))

        // A later handshake status never downgrades the final verdict.
        store.recordFailure(.elevenLabs, error: CloudTranscriptionError.handshakeRejected(401, provider: .elevenLabs))
        XCTAssertEqual(store.notice(for: .elevenLabs)?.kind, .billing)
        XCTAssertFalse(store.allowsBatch(for: .elevenLabs))
    }

    func testNoticeCopyMatchesMock() {
        let clock = Clock()
        let store = makeStore(clock)
        store.recordFailure(.elevenLabs, kind: .billing)
        let notice = store.notice(for: .elevenLabs)
        XCTAssertEqual(notice?.title, "ElevenLabs: payment needed")
        XCTAssertEqual(notice?.subtitle, "Using on-device · may be slower")
        XCTAssertEqual(notice?.menuTitle, "ElevenLabs: payment needed — Open billing…")
        XCTAssertEqual(notice?.settingsLine(timeFormatter: { _ in "8:43 PM" }),
                       "Rejected 8:43 PM: payment needed. Dictation is using on-device.")
        store.recordFailure(.xai, kind: .rateLimited)
        XCTAssertEqual(store.notice(for: .xai)?.title, "xAI: rate limited")
        XCTAssertNil(store.notice(for: .xai)?.menuTitle)
        store.recordFailure(.gemini, kind: .auth)
        XCTAssertEqual(store.notice(for: .gemini)?.title, "Gemini: key rejected")
    }

    func testStreamingEngineIDMapsToProvider() {
        XCTAssertEqual(TranscriptionPipeline.streamingProvider(forEngineID: "cloud:elevenlabs-streaming"), .elevenLabs)
        XCTAssertEqual(TranscriptionPipeline.streamingProvider(forEngineID: "cloud:xai-streaming"), .xai)
        XCTAssertNil(TranscriptionPipeline.streamingProvider(forEngineID: "whisperKit:streaming"))
        XCTAssertNil(TranscriptionPipeline.streamingProvider(forEngineID: "cloud:elevenLabs"))
    }

    // MARK: - Selector gating

    @MainActor
    func testRefusingProviderGetsNoStreamingSession() {
        let clock = Clock()
        let selector = ASREngineSelector()
        selector.providerHealth = makeStore(clock)
        selector.cloudModel = .elevenLabsScribeV2Realtime
        selector.apiKeyProvider = { _ in "dummy-test-key" }
        XCTAssertNotNil(selector.makeElevenLabsStreamingSession())
        selector.providerHealth.recordFailure(.elevenLabs, kind: .billing)
        XCTAssertNil(selector.makeElevenLabsStreamingSession())
        clock.advance(301)
        XCTAssertNotNil(selector.makeElevenLabsStreamingSession())
    }

    // MARK: - Pipeline

    private struct CountingCloud: CloudTranscriptionService {
        let counter: Counter
        var result: Result<String, Error>
        func transcribe(audioURL: URL, apiKey: String, model: CloudModel, language: String) async throws -> String {
            counter.increment()
            return try result.get()
        }
    }

    private final class Counter {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct LocalStub: ASREngine {
        let id = "local-stub"
        let displayName = "Local stub"
        let run: (URL) async throws -> String
        func transcribe(audioURL: URL) async throws -> String { try await run(audioURL) }
    }

    @MainActor
    private func runPipeline(
        health: ProviderHealthStore,
        cloud: CountingCloud,
        constructions: Counter,
        localCalls: Counter
    ) -> [CloudProvider] {
        let selector = ASREngineSelector()
        selector.providerHealth = health
        selector.cloudModel = .elevenLabsScribeV2Realtime
        selector.apiKeyProvider = { _ in "dummy-test-key" }
        let pipeline = selector.pipeline
        pipeline.cloudServiceProvider = { _ in
            constructions.increment()
            return cloud
        }
        pipeline.localEngineProvider = {
            LocalStub { _ in
                localCalls.increment()
                return ""
            }
        }
        pipeline.onTranscriptionLogged = { _, _, _, _, _, _ in }
        pipeline.onFailure = { _ in }
        var skipped: [CloudProvider] = []
        pipeline.onCloudSkippedForOutage = { skipped.append($0) }
        let done = expectation(description: "pipeline finished")
        pipeline.transcribeAndLog(
            audioURL: URL(fileURLWithPath: "/unused-stub-audio.caf"), audioIsTemporary: true,
            sessionHeldToken: pipeline.test_holdSnapshot(.unknown)
        ) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        return skipped
    }

    @MainActor
    func testRefusingProviderSkipsCloudAndRunsLocalOnce() {
        let clock = Clock()
        let health = makeStore(clock)
        health.recordFailure(.elevenLabs, kind: .billing)
        let constructions = Counter(), cloudCalls = Counter(), localCalls = Counter()
        let skipped = runPipeline(
            health: health,
            cloud: CountingCloud(counter: cloudCalls, result: .success("never")),
            constructions: constructions, localCalls: localCalls)
        XCTAssertEqual(constructions.count, 0, "Cloud service must not even be constructed")
        XCTAssertEqual(cloudCalls.count, 0)
        XCTAssertEqual(localCalls.count, 1)
        XCTAssertEqual(skipped, [.elevenLabs])
        XCTAssertEqual(health.notice(for: .elevenLabs)?.title, "ElevenLabs: payment needed")
    }

    @MainActor
    func testRetryAfterWindowCallsCloudAndSuccessClearsNotice() {
        let clock = Clock()
        let health = makeStore(clock)
        health.recordFailure(.elevenLabs, kind: .billing)
        clock.advance(301)
        let constructions = Counter(), cloudCalls = Counter(), localCalls = Counter()
        let skipped = runPipeline(
            health: health,
            cloud: CountingCloud(counter: cloudCalls, result: .success("Hello there.")),
            constructions: constructions, localCalls: localCalls)
        XCTAssertEqual(cloudCalls.count, 1)
        XCTAssertEqual(localCalls.count, 0)
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertNil(health.notice(for: .elevenLabs))
        XCTAssertEqual(health.state(for: .elevenLabs), .ok)
    }

    @MainActor
    func testBillingResponseRefusesAndFallsBackToLocal() {
        let clock = Clock()
        let health = makeStore(clock)
        let constructions = Counter(), cloudCalls = Counter(), localCalls = Counter()
        let error = CloudTranscriptionError.httpStatus(401, provider: .elevenLabs, body: elevenLabsPaymentBody)
        _ = runPipeline(
            health: health,
            cloud: CountingCloud(counter: cloudCalls, result: .failure(error)),
            constructions: constructions, localCalls: localCalls)
        XCTAssertEqual(cloudCalls.count, 1)
        XCTAssertEqual(localCalls.count, 1, "Today's fallback still runs on the failing hold")
        XCTAssertEqual(health.notice(for: .elevenLabs)?.kind, .billing)
        XCTAssertFalse(health.allowsBatch(for: .elevenLabs))
    }

    @MainActor
    func testTransientFailureLeavesHealthUntouchedAndStillFallsBack() {
        let clock = Clock()
        let health = makeStore(clock)
        let constructions = Counter(), cloudCalls = Counter(), localCalls = Counter()
        _ = runPipeline(
            health: health,
            cloud: CountingCloud(counter: cloudCalls, result: .failure(URLError(.timedOut))),
            constructions: constructions, localCalls: localCalls)
        XCTAssertEqual(cloudCalls.count, 1)
        XCTAssertEqual(localCalls.count, 1)
        XCTAssertEqual(health.state(for: .elevenLabs), .ok)
    }
}
