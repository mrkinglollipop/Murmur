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

    func testRemoveByIDPersists() {
        let (log, url) = makeLog()
        let keep = CorrectionRecord(heard: "a", replaced: "A", source: .dictionary)
        let drop = CorrectionRecord(heard: "b", replaced: "B", source: .learnAccepted)
        log.append([keep, drop])
        log.remove(id: drop.id)
        log.flush()

        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(log.records.first?.id, keep.id)

        let reloaded = CorrectionsLog(fileURL: url)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.id, keep.id)
    }

    func testRemoveUnknownIDIsNoOp() {
        let (log, _) = makeLog()
        log.append([
            CorrectionRecord(heard: "a", replaced: "A", source: .phonetic)
        ])
        log.remove(id: UUID())
        XCTAssertEqual(log.records.count, 1)
    }

    func testRemoveIDsDropsMatchingRecords() {
        let (log, url) = makeLog()
        let keep = CorrectionRecord(heard: "a", replaced: "A", source: .dictionary)
        let dropA = CorrectionRecord(heard: "b", replaced: "B", source: .phonetic)
        let dropB = CorrectionRecord(heard: "c", replaced: "C", source: .phonetic)
        log.append([keep, dropA, dropB])
        log.remove(ids: [dropA.id, dropB.id])
        log.flush()
        XCTAssertEqual(log.records.map(\.id), [keep.id])

        let reloaded = CorrectionsLog(fileURL: url)
        XCTAssertEqual(reloaded.records.map(\.id), [keep.id])
    }

    func testGroupedRecentCollapsesMisspellingsUnderOneTerm() {
        let (log, _) = makeLog()
        let now = Date()
        log.append([
            CorrectionRecord(heard: "Keepu", replaced: "Khipu", source: .dictionary, date: now),
            CorrectionRecord(heard: "Keefu", replaced: "Khipu", source: .phonetic, date: now.addingTimeInterval(-60)),
            CorrectionRecord(heard: "mana", replaced: "Manna", source: .dictionary, date: now.addingTimeInterval(-120))
        ])
        let groups = log.groupedRecent(days: 7, now: now)
        XCTAssertEqual(groups.map(\.replaced), ["Khipu", "Manna"])
        XCTAssertEqual(groups[0].rows.map(\.heard), ["Keepu", "Keefu"])
        XCTAssertEqual(groups[0].recordIDs.count, 2)
        XCTAssertEqual(groups[1].rows.map(\.heard), ["mana"])
    }

    func testGroupedRecentCollapsesRepeatFiringsButKeepsAllIDs() {
        let (log, _) = makeLog()
        let now = Date()
        let first = CorrectionRecord(
            heard: "mana",
            replaced: "Manna",
            source: .dictionary,
            date: now.addingTimeInterval(-3600)
        )
        let second = CorrectionRecord(
            heard: "mana",
            replaced: "Manna",
            source: .dictionary,
            date: now
        )
        log.append([first, second])
        let groups = log.groupedRecent(days: 7, now: now)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.map(\.id), [second.id])
        XCTAssertEqual(Set(groups[0].recordIDs), [first.id, second.id])
    }

    func testGroupedRecentExcludesOldRecords() {
        let (log, _) = makeLog()
        let now = Date()
        log.append([
            CorrectionRecord(
                heard: "land",
                replaced: "Linode",
                source: .phonetic,
                date: now.addingTimeInterval(-10 * 24 * 60 * 60)
            ),
            CorrectionRecord(heard: "mana", replaced: "Manna", source: .dictionary, date: now)
        ])
        let groups = log.groupedRecent(days: 7, now: now)
        XCTAssertEqual(groups.map(\.replaced), ["Manna"])
    }
}
