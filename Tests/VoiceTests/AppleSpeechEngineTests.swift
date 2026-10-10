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
                    for hasDownloadedLocalModel in [false, true] {
                        XCTAssertEqual(
                            SettingsStore.initialLocalModel(
                                storedRawValue: stored.rawValue,
                                hasStoredCloudSelection: hasStoredCloudSelection,
                                hasCloudKey: hasCloudKey,
                                hasDownloadedLocalModel: hasDownloadedLocalModel
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
                for hasDownloadedLocalModel in [false, true] {
                    let model = SettingsStore.initialLocalModel(
                        storedRawValue: nil,
                        hasStoredCloudSelection: hasStoredCloudSelection,
                        hasCloudKey: hasCloudKey,
                        hasDownloadedLocalModel: hasDownloadedLocalModel
                    )
                    if !hasStoredCloudSelection && !hasCloudKey && !hasDownloadedLocalModel {
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
                hasDownloadedLocalModel: false
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
