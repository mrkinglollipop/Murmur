import XCTest
@testable import Voice

final class CorrectionsLogTests: XCTestCase {

    private func makeLog() -> (CorrectionsLog, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrections-test-\(UUID().uuidString).json")
        return (CorrectionsLog(fileURL: url), url)
    }

    func testAppendCapsAt200FIFO() {
        let (log, _) = makeLog()
        for index in 0..<205 {
            log.append([
                CorrectionRecord(
                    heard: "heard\(index)",
                    replaced: "term\(index)",
                    source: .dictionary
                )
            ])
        }
        XCTAssertEqual(log.records.count, 200)
        XCTAssertEqual(log.records.first?.heard, "heard5")
        XCTAssertEqual(log.records.last?.heard, "heard204")
    }

    func testRecentFiltersByDays() {
        let (log, _) = makeLog()
        let now = Date()
        let old = now.addingTimeInterval(-10 * 24 * 60 * 60)
        log.append([
            CorrectionRecord(heard: "old", replaced: "new", source: .phonetic, date: old),
            CorrectionRecord(heard: "fresh", replaced: "new", source: .phonetic, date: now)
        ])
        let recent = log.recent(days: 7, now: now)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.heard, "fresh")
    }

    func testPersistenceRoundTrip() {
        let (log, url) = makeLog()
        log.append([
            CorrectionRecord(heard: "grok", replaced: "Groq", source: .phonetic)
        ])
        log.flush()

        let reloaded = CorrectionsLog(fileURL: url)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.heard, "grok")
        XCTAssertEqual(reloaded.records.first?.replaced, "Groq")
    }

    func testLearnAcceptedRoundTripRequiresEntryMetadata() {
        let (log, url) = makeLog()
        let entryID = UUID()
        log.append([
            CorrectionRecord(
                heard: "Groq",
                replaced: "Grok",
                source: .learnAccepted,
                entryID: entryID,
                createdNewEntry: true
            )
        ])
        log.flush()

        let reloaded = CorrectionsLog(fileURL: url)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.source, .learnAccepted)
        XCTAssertEqual(reloaded.records.first?.entryID, entryID)
        XCTAssertEqual(reloaded.records.first?.createdNewEntry, true)
    }

    func testOldRecordsDecodeWithoutEntryMetadata() {
        let (log, url) = makeLog()
        log.append([
            CorrectionRecord(heard: "legacy", replaced: "term", source: .dictionary)
        ])
        log.flush()
        let reloaded = CorrectionsLog(fileURL: url)
        XCTAssertNil(reloaded.records.first?.entryID)
        XCTAssertNil(reloaded.records.first?.createdNewEntry)
    }
}
