import XCTest
@testable import Voice

final class CorrectionExtractorTests: XCTestCase {

    func testLocatePrefersMatchEndingAtCaret() {
        let field = "Hello Groq world Groq"
        // Second Groq ends at utf16 offset: "Hello Groq world ".utf16.count + 4
        let secondEnd = ("Hello Groq world Groq" as NSString).length
        let located = CorrectionExtractor.locate(
            deliveredText: "Groq",
            in: field,
            caretUTF16: secondEnd
        )
        XCTAssertEqual(located?.utf16Location, ("Hello Groq world " as NSString).length)
        XCTAssertEqual(located?.utf16Length, 4)
    }

    func testLocateMidDocument() {
        let field = "aaa TARGET bbb"
        let start = ("aaa " as NSString).length
        let caret = start + ("TARGET" as NSString).length
        let located = CorrectionExtractor.locate(
            deliveredText: "TARGET",
            in: field,
            caretUTF16: caret
        )
        XCTAssertEqual(located?.utf16Location, start)
        XCTAssertEqual(located?.utf16Length, 6)
    }

    func testLocateAmbiguousNearestReturnsNil() {
        // Two matches equally far from caret in the middle
        let field = "xx ABxxABxx"
        // caret between the two AB ends — both distance equal
        let firstEnd = ("xx AB" as NSString).length
        let secondEnd = ("xx ABxxAB" as NSString).length
        let mid = (firstEnd + secondEnd) / 2
        let located = CorrectionExtractor.locate(
            deliveredText: "AB",
            in: field,
            caretUTF16: mid
        )
        // If distances are equal, abort
        if abs(firstEnd - mid) == abs(secondEnd - mid) {
            XCTAssertNil(located)
        }
    }

    func testRegionDiffWordEdit() {
        let snapshot = "Say Groq please"
        let start = ("Say " as NSString).length
        let diff = CorrectionExtractor.regionDiff(
            snapshotValue: snapshot,
            injectedUTF16Location: start,
            injectedUTF16Length: 4,
            currentValue: "Say Grok please"
        )
        XCTAssertEqual(diff?.oldRegion, "Groq")
        XCTAssertEqual(diff?.newRegion, "Grok")
    }

    func testRegionDiffUnchangedReturnsNil() {
        let snapshot = "Say Groq please"
        let start = ("Say " as NSString).length
        let diff = CorrectionExtractor.regionDiff(
            snapshotValue: snapshot,
            injectedUTF16Location: start,
            injectedUTF16Length: 4,
            currentValue: snapshot
        )
        XCTAssertNil(diff)
    }

    func testRegionDiffMidDocument() {
        let snapshot = "prefix injected suffix"
        let start = ("prefix " as NSString).length
        let len = ("injected" as NSString).length
        let diff = CorrectionExtractor.regionDiff(
            snapshotValue: snapshot,
            injectedUTF16Location: start,
            injectedUTF16Length: len,
            currentValue: "prefix fixed suffix"
        )
        XCTAssertEqual(diff?.oldRegion, "injected")
        XCTAssertEqual(diff?.newRegion, "fixed")
    }

    func testExceedsFieldCap() {
        let big = String(repeating: "a", count: CorrectionExtractor.maxFieldUTF16Units + 1)
        XCTAssertTrue(CorrectionExtractor.exceedsFieldCap(big))
        XCTAssertFalse(CorrectionExtractor.exceedsFieldCap("small"))
    }

    func testAutomatedLearnGroqToGrokViaExtractor() {
        let store = DictionaryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("dict-grok-\(UUID().uuidString).json")
        )
        let snapshot = "I use Groq daily"
        let start = ("I use " as NSString).length
        let diff = CorrectionExtractor.regionDiff(
            snapshotValue: snapshot,
            injectedUTF16Location: start,
            injectedUTF16Length: 4,
            currentValue: "I use Grok daily"
        )
        XCTAssertNotNil(diff)
        let learned = store.learn(
            from: diff!.oldRegion,
            to: diff!.newRegion,
            userInitiated: false
        )
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.variant, "Groq")
        XCTAssertEqual(learned.first?.term, "Grok")
        XCTAssertEqual(store.correct("try Groq now").text, "try Grok now")
    }

    func testAutomatedLearnSkipsBlocklistedPair() {
        let store = DictionaryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("dict-bl-\(UUID().uuidString).json"),
            blocklistFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("bl-\(UUID().uuidString).json")
        )
        store.blocklistPair(heard: "Groq", replaced: "Grok")
        let learned = store.learn(from: "Groq", to: "Grok", userInitiated: false)
        XCTAssertTrue(learned.isEmpty)
    }
}
