import XCTest
@testable import Voice

final class CloudModelSelectionTests: XCTestCase {

    func testSelectableContainsExactlyXAIAndElevenLabs() {
        XCTAssertEqual(Set(CloudModel.selectable), [.xaiGrokSTT, .elevenLabsScribeV2Realtime])
    }

    func testSelectableExcludesRetiredProviders() {
        let retired: Set<CloudModel> = [
            .assemblyAIUniversal3,
            .deepgramNova3,
            .openAIGPT4oTranscribe,
            .groqWhisperLargeV3Turbo,
        ]
        XCTAssertTrue(retired.isDisjoint(with: CloudModel.selectable))
    }

    func testFallbackMapsRetiredModelToXAI() {
        XCTAssertEqual(CloudModel.selectableOrFallback(.assemblyAIUniversal3), .xaiGrokSTT)
        XCTAssertEqual(CloudModel.selectableOrFallback(.deepgramNova3), .xaiGrokSTT)
        XCTAssertEqual(CloudModel.selectableOrFallback(.openAIGPT4oTranscribe), .xaiGrokSTT)
        XCTAssertEqual(CloudModel.selectableOrFallback(.groqWhisperLargeV3Turbo), .xaiGrokSTT)
    }

    func testFallbackLeavesValidSelectionUntouched() {
        XCTAssertEqual(CloudModel.selectableOrFallback(.xaiGrokSTT), .xaiGrokSTT)
        XCTAssertEqual(CloudModel.selectableOrFallback(.elevenLabsScribeV2Realtime), .elevenLabsScribeV2Realtime)
    }

    /// Regression guard for "leave the scaffolding": the factory must still
    /// serve a working service for every provider, including the four
    /// retired-from-the-UI models, so re-enabling one later is a one-line
    /// change rather than a resurrection.
    func testFactoryStillServesAllSixProviders() {
        for model in CloudModel.allCases {
            let service = CloudTranscriberFactory.service(for: model)
            XCTAssertNotNil(service, "expected a service for \(model.rawValue)")
        }
        XCTAssertEqual(CloudModel.allCases.count, 6)
    }
}
