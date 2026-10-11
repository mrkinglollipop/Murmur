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
