import XCTest
@testable import Voice

final class CloudModelSelectionTests: XCTestCase {

    func testSelectableContainsXAIElevenLabsGeminiAndMuse() {
        XCTAssertEqual(
            Set(CloudModel.selectable),
            [.xaiGrokSTT, .elevenLabsScribeV2Realtime, .gemini35TranscribeLive, .museVoiceTranscribeLive]
        )
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
        XCTAssertEqual(CloudModel.selectableOrFallback(.gemini35TranscribeLive), .gemini35TranscribeLive)
        XCTAssertEqual(CloudModel.selectableOrFallback(.museVoiceTranscribeLive), .museVoiceTranscribeLive)
    }

    func testFactoryStillServesAllEightProviders() {
        for model in CloudModel.allCases {
            let service = CloudTranscriberFactory.service(for: model)
            XCTAssertNotNil(service, "expected a service for \(model.rawValue)")
        }
        XCTAssertEqual(CloudModel.allCases.count, 8)
    }
}
