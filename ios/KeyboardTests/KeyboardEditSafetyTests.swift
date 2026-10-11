import XCTest

final class KeyboardEditSafetyTests: XCTestCase {
    func test01AutomaticDeletionPreservesFreshDictationWithNilOrEmptySelection() {
        let transcript = "A fresh dictated sentence "
        for selection in [nil, ""] as [String?] {
            var proxy = ClumpingProxy(text: transcript, selected: selection)
            if KeyboardBulkEditPolicy.allowsDeletion(
                count: 1, beforeInput: proxy.text, selected: proxy.selected,
                recentBulkInsert: transcript, textAfterBulkInsert: ""
            ) {
                proxy.deleteBackward()
            }
            XCTAssertEqual(proxy.text, transcript)
            XCTAssertEqual(proxy.deleteCalls, 0)
        }
    }

    func test01SwipePunctuationAndReturnAreInsertOnly() {
        let origin = KeyboardInsertOrigin.swipe("hello ")
        for key in [".", ",", "!", "?", "\n", " "] {
            XCTAssertEqual(origin.trailingDeleteCount(beforeInserting: key, context: "hello "), 0)
        }
        XCTAssertEqual(KeyboardBulkEditPolicy.punctuationDeleteCount(
            trailing: " ", recentBulkInsert: nil
        ), 1)
        XCTAssertEqual(KeyboardBulkEditPolicy.punctuationDeleteCount(
            trailing: " ", recentBulkInsert: "hello "
        ), 0)
    }

    func test01DeletionCannotCrossFromTypedTextIntoBulkInsertion() {
        let transcript = "Dictated text "
        XCTAssertTrue(KeyboardBulkEditPolicy.allowsDeletion(
            count: 3, beforeInput: transcript + "teh", selected: nil,
            recentBulkInsert: transcript, textAfterBulkInsert: "teh"
        ))
        XCTAssertFalse(KeyboardBulkEditPolicy.allowsDeletion(
            count: 4, beforeInput: transcript + "teh", selected: nil,
            recentBulkInsert: transcript, textAfterBulkInsert: "teh"
        ))
        XCTAssertFalse(KeyboardBulkEditPolicy.allowsDeletion(
            count: 1, beforeInput: "A different caret location", selected: nil,
            recentBulkInsert: transcript, textAfterBulkInsert: "teh"
        ))
        XCTAssertFalse(KeyboardBulkEditPolicy.allowsDeletion(
            count: 1, beforeInput: "hello ", selected: nil,
            recentBulkInsert: "hello ", textAfterBulkInsert: ""
        ))
        for typed in [" ", "  ", ".", "\n"] {
            XCTAssertFalse(KeyboardBulkEditPolicy.allowsDeletion(
                count: 1, beforeInput: transcript + typed, selected: nil,
                recentBulkInsert: transcript, textAfterBulkInsert: typed
            ))
        }
        let typed = "👩🏽‍💻é"
        XCTAssertTrue(KeyboardBulkEditPolicy.allowsDeletion(
            count: typed.count, beforeInput: transcript + typed, selected: nil,
            recentBulkInsert: transcript, textAfterBulkInsert: typed
        ))
        XCTAssertFalse(KeyboardBulkEditPolicy.allowsDeletion(
            count: typed.count + 1, beforeInput: transcript + typed, selected: nil,
            recentBulkInsert: transcript, textAfterBulkInsert: typed
        ))
    }

    func test04SpacePreservesIdentifierAndURLInDefaultField() {
        XCTAssertTrue(KeyboardAutocorrectionPolicy.allowsReplacement(
            autocorrectionType: .yes, keyboardType: .default, isSecure: false
        ))
        for input in ["build_teh", "See https://example.com/teh", "send user@teh", "release2teh"] {
            XCTAssertEqual(committingSpace(to: input), input + " ")
            for context in [input, input + " "] {
                XCTAssertNil(KeyboardBulkEditPolicy.candidateSpan(
                    beforeInput: context, recentBulkInsert: nil, textAfterBulkInsert: ""
                ))
            }
        }
        XCTAssertEqual(committingSpace(to: "say teh"), "say the ")
        XCTAssertEqual(committingSpace(to: "say (teh"), "say (the ")
    }

    func test05OriginalCandidateRestoresNewWordDuringBulkWindow() {
        let transcript = "Dictated text "
        var context = committingSpace(to: transcript + "teh")
        let span = KeyboardBulkEditPolicy.candidateSpan(
            beforeInput: context, recentBulkInsert: transcript, textAfterBulkInsert: "the "
        )
        if let span {
            let removable = span.word + span.trailing
            if KeyboardBulkEditPolicy.allowsDeletion(
                count: removable.count, beforeInput: context, selected: "",
                recentBulkInsert: transcript, textAfterBulkInsert: "the "
            ) {
                context.removeLast(removable.count)
                context += "teh" + span.trailing
            }
        }
        XCTAssertEqual(context, transcript + "teh ")
    }

    func test05CandidatesCannotTargetBulkTextOrCrossItsBoundary() {
        let transcript = "Dictated text "
        XCTAssertNil(KeyboardBulkEditPolicy.candidateSpan(
            beforeInput: transcript, recentBulkInsert: transcript, textAfterBulkInsert: ""
        ))
        XCTAssertNil(KeyboardBulkEditPolicy.candidateSpan(
            beforeInput: "Dictated text", recentBulkInsert: "Dictated tex",
            textAfterBulkInsert: "t"
        ))
        let active = KeyboardBulkEditPolicy.candidateSpan(
            beforeInput: transcript + "teh", recentBulkInsert: transcript,
            textAfterBulkInsert: "teh"
        )
        XCTAssertEqual(active?.word, "teh")
        XCTAssertEqual(active?.trailing, "")
        let ordinary = KeyboardBulkEditPolicy.candidateSpan(
            beforeInput: "say the ", recentBulkInsert: nil, textAfterBulkInsert: ""
        )
        XCTAssertEqual(ordinary?.word, "the")
        XCTAssertEqual(ordinary?.trailing, " ")
    }

    private func committingSpace(to context: String) -> String {
        let span = AutocorrectEngine.autocorrectionSpan(beforeInput: context)
        guard let correction = AutocorrectEngine.forcedTypo(span) else { return context + " " }
        let replacement = AutocorrectEngine.replacement(span: span, correction: correction)
        return String(context.dropLast(replacement.deleteCount)) + replacement.insert + " "
    }

    private struct ClumpingProxy {
        var text: String
        let selected: String?
        var deleteCalls = 0

        mutating func deleteBackward() {
            deleteCalls += 1
            text = ""
        }
    }
}
