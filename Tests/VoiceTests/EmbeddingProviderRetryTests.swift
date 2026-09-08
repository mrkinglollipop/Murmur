import FluidAudio
import XCTest
@testable import Voice

final class EmbeddingProviderRetryTests: XCTestCase {
    private actor Loader {
        var attempts = 0
        var release: CheckedContinuation<Void, Never>?
        let failFirst: Bool
        init(failFirst: Bool) { self.failFirst = failFirst }
        func load() async throws -> DiarizerManager {
            attempts += 1
            if failFirst && attempts == 1 { throw URLError(.notConnectedToInternet) }
            await withCheckedContinuation { release = $0 }
            return DiarizerManager()
        }
        func finish() { release?.resume(); release = nil }
        var suspended: Bool { release != nil }
    }

    func testFailedModelLoadCanBeRetriedWithoutOverlappingLoads() async throws {
        let loader = Loader(failFirst: true)
        let provider = FluidAudioEmbeddingProvider(loader: { try await loader.load() })
        for _ in 0..<100 {
            if await loader.attempts == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(provider.isReady)
        var retried = false
        for _ in 0..<100 {
            if provider.retryLoadingIfNeeded() { retried = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(retried)
        for _ in 0..<100 {
            if await loader.suspended { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(provider.retryLoadingIfNeeded(), "An in-flight load must be reused")
        await loader.finish()
        for _ in 0..<100 {
            if provider.isReady { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(provider.isReady)
        XCTAssertFalse(provider.retryLoadingIfNeeded(), "A ready model must be reused")
        let attempts = await loader.attempts
        XCTAssertEqual(attempts, 2)
    }
}
