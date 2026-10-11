import XCTest
@testable import Voice

/// Synthetic events exercise ingestion without starting a socket or audio capture.
final class StitchReplayTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let events: [Event]
        let expected: String
        let requiresRecovery: Bool?
        let verifyFinalize: Bool?
    }

    private struct Event: Decodable {
        enum Kind: String, Decodable { case final, interim, done }

        let type: Kind
        let text: String
        let speechFinal: Bool
        let words: [Word]
        let expectedAfter: String?
    }

    private struct Word: Decodable {
        let text: String
        let start: Double
        let end: Double

        var transcriptWord: TranscriptWord {
            TranscriptWord(text: text, start: start, end: end)
        }
    }

    func testReplayAllFixtures() async throws {
        let bundle = Bundle(for: Self.self)
        // XcodeGen may preserve the directory or flatten individual resources.
        let bundledURLs = (bundle.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures") ?? [])
            + (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
        // New replay cases remain source fixtures until their project resources
        // are regenerated. Prefer source paths so every checked-in fixture runs
        // without changing the generated Xcode project in a stitch-only repair.
        let sourceFixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: sourceFixtureDirectory,
            includingPropertiesForKeys: nil
        )
        var fixtureURLByName: [String: URL] = [:]
        for url in bundledURLs where url.lastPathComponent.hasPrefix("stitch-") {
            fixtureURLByName[url.lastPathComponent] = url
        }
        for url in sourceURLs where url.lastPathComponent.hasPrefix("stitch-") && url.pathExtension == "json" {
            fixtureURLByName[url.lastPathComponent] = url
        }
        let fixtureURLs = fixtureURLByName.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(fixtureURLs.count, 5, "Replay fixtures must be bundled in VoiceTests.")
        let fixtures = try fixtureURLs.map { try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(Set(fixtures.map(\.name)).count, fixtures.count, "Fixture names must be unique.")
        XCTAssertTrue(fixtures.contains { $0.events.contains { !$0.words.isEmpty } }, "Replay must exercise word timestamps.")
        let requiredNames: Set<String> = [
            "r3-2-untimed-tail", "r3-3-nonmonotonic", "r3-4-misaligned-incoming", "r3-5-reset-origin",
            "regression-near-duplicate-tail", "xai-done-replaces-owned-interim", "xai-done-full-session-completion",
            "xai-untimed-utterance-final-owns-chunk", "xai-done-ambiguous-conflict-recovers",
            "xai-distinct-utterances-remain-distinct", "xai-done-only-full-session",
            "xai-done-full-session-prefix-extension", "xai-untimed-separate-utterances-remain-distinct",
            "xai-invalid-word-prefix-remains-ambiguous", "xai-older-ambiguity-survives-last-chunk-refinement",
            "xai-empty-done-promotes-provisional-ambiguity", "xai-done-sign-conflict-remains-ambiguous",
            "xai-untimed-negation-prefix-remains-ambiguous", "xai-untimed-decimal-prefix-remains-ambiguous"
        ]
        XCTAssertTrue(requiredNames.isSubset(of: Set(fixtures.map(\.name))),
                      "Replay must include every xAI stitch acceptance fixture.")

        var finalizations: [(Fixture, XAIStreamingTranscriber)] = []
        for fixture in fixtures {
            XCTContext.runActivity(named: fixture.name) { _ in
                XCTAssertFalse(fixture.events.isEmpty, "\(fixture.name): fixture must contain events.")
                // No start()/send(): each session is confined to this
                // synchronous replay, so no other thread can access its state.
                let session = XAIStreamingTranscriber(apiKey: "synthetic-replay-key")
                for (index, event) in fixture.events.enumerated() {
                    switch event.type {
                    case .final:
                        session.ingestFinalSegment(
                            text: event.text,
                            words: event.words.map(\.transcriptWord),
                            speechFinal: event.speechFinal
                        )
                    case .interim, .done:
                        // Use the real event handler to populate private interim
                        // state without introducing another production seam.
                        do {
                            let data = try JSONSerialization.data(withJSONObject: [
                                "type": event.type == .done ? "transcript.done" : "transcript.partial", "text": event.text,
                                "is_final": false, "speech_final": false,
                                "words": event.words.map {
                                    ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any]
                                }
                            ])
                            session.handleServerEvent(String(decoding: data, as: UTF8.self))
                        } catch {
                            XCTFail("\(fixture.name): cannot encode interim event \(index): \(error)")
                        }
                    }
                    if let expected = event.expectedAfter {
                        XCTAssertEqual(session.mergeConfirmedWithInterim(), expected, "\(fixture.name): event \(index)")
                    }
                }
                XCTAssertEqual(session.mergeConfirmedWithInterim(), fixture.expected, fixture.name)
                if let requiresRecovery = fixture.requiresRecovery {
                    XCTAssertEqual(session.requiresBufferedAudioRecovery, requiresRecovery, fixture.name)
                }
                if fixture.verifyFinalize == true {
                    if !fixture.events.contains(where: { $0.type == .done }) {
                        session.handleServerEvent(#"{"type":"transcript.done","text":""}"#)
                    }
                    finalizations.append((fixture, session))
                }
                print("STITCH_REPLAY \(fixture.name)")
            }
        }

        for (fixture, session) in finalizations {
            let finalized = await session.finalize()
            XCTAssertEqual(finalized, fixture.expected, "\(fixture.name): finalized")
            let expectedRecovery = try XCTUnwrap(fixture.requiresRecovery)
            XCTAssertEqual(session.requiresBufferedAudioRecovery, expectedRecovery,
                           "\(fixture.name): recovery survives reset")
            XCTAssertEqual(session.joinedTranscriptSnapshot(), "", "\(fixture.name): finalized state resets")
        }
    }
}
