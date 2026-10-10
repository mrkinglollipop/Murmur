import XCTest
@testable import Voice

/// Synthetic events exercise ingestion without starting a socket or audio capture.
final class StitchReplayTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let events: [Event]
        let expected: String
    }

    private struct Event: Decodable {
        enum Kind: String, Decodable { case final, interim }

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

    func testReplayAllFixtures() throws {
        let bundle = Bundle(for: Self.self)
        // XcodeGen may preserve the directory or flatten individual resources.
        let urls = (bundle.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures") ?? [])
            + (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
        let fixtureURLs = Set(urls.map { $0 as URL })
            .filter { $0.lastPathComponent.hasPrefix("stitch-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(fixtureURLs.count, 5, "Replay fixtures must be bundled in VoiceTests.")
        let fixtures = try fixtureURLs.map { try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(Set(fixtures.map(\.name)).count, fixtures.count, "Fixture names must be unique.")
        XCTAssertTrue(fixtures.contains { $0.events.contains { !$0.words.isEmpty } }, "Replay must exercise word timestamps.")

        for fixture in fixtures {
            XCTContext.runActivity(named: fixture.name) { _ in
                XCTAssertFalse(fixture.events.isEmpty, "\(fixture.name): fixture must contain events.")
                // No start()/send()/finalize(): each session is confined to this
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
                    case .interim:
                        // Use the real event handler to populate private interim
                        // state without introducing another production seam.
                        do {
                            let data = try JSONSerialization.data(withJSONObject: [
                                "type": "transcript.partial", "text": event.text,
                                "is_final": false, "speech_final": false
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
                print("STITCH_REPLAY \(fixture.name)")
            }
        }
    }
}
