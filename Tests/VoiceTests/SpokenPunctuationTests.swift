import XCTest
@testable import Voice

final class SpokenPunctuationTests: XCTestCase {

    func testUnderscoreBetweenWords() {
        XCTAssertEqual(SpokenPunctuation.apply("foo underscore bar"), "foo_bar")
    }

    func testUnderscoreChain() {
        XCTAssertEqual(
            SpokenPunctuation.apply("foo underscore bar underscore baz"),
            "foo_bar_baz"
        )
    }

    func testUnderScoreAlias() {
        XCTAssertEqual(SpokenPunctuation.apply("foo under score bar"), "foo_bar")
    }

    func testOpenParen() {
        XCTAssertEqual(SpokenPunctuation.apply("call open paren here"), "call ( here")
    }

    func testParenthesisAliases() {
        XCTAssertEqual(SpokenPunctuation.apply("open parenthesis x close parenthesis"), "( x )")
        XCTAssertEqual(SpokenPunctuation.apply("left paren right paren"), "( )")
    }

    func testNewLine() {
        XCTAssertEqual(
            SpokenPunctuation.apply("first line new line second line"),
            "first line \n second line"
        )
    }

    func testTab() {
        XCTAssertEqual(SpokenPunctuation.apply("indent tab key here"), "indent \t here")
    }

    func testMixedChain() {
        let input = "open paren foo underscore bar close paren"
        XCTAssertEqual(SpokenPunctuation.apply(input), "( foo_bar )")
    }

    func testDotBetweenWords() {
        XCTAssertEqual(
            SpokenPunctuation.apply("rereadpersona_Deadpool dot mid"),
            "rereadpersona_Deadpool.mid"
        )
    }

    func testDotChain() {
        XCTAssertEqual(SpokenPunctuation.apply("foo dot bar dot baz"), "foo.bar.baz")
    }

    func testPeriodAlias() {
        XCTAssertEqual(
            SpokenPunctuation.apply("SettingsStore period swift"),
            "SettingsStore.swift"
        )
    }

    func testLetterSpacedFileExtensionAfterDot() {
        XCTAssertEqual(SpokenPunctuation.apply("Conduct.m d c"), "Conduct.mdc")
        XCTAssertEqual(SpokenPunctuation.apply("Conduct dot m d c"), "Conduct.mdc")
        XCTAssertEqual(SpokenPunctuation.apply("rules forward slash conduct dot m d c"), "rules/conduct.mdc")
        XCTAssertEqual(SpokenPunctuation.apply("file.t s"), "file.ts")
        XCTAssertEqual(SpokenPunctuation.apply("App.s w i f t"), "App.swift")
        XCTAssertEqual(
            SpokenPunctuation.apply("Draft a session start hook for conduct.m d c."),
            "Draft a session start hook for conduct.mdc."
        )
        // Title-cased letter spelling must still yield a lowercase extension.
        XCTAssertEqual(SpokenPunctuation.apply("Conduct.M D C"), "Conduct.mdc")
        XCTAssertEqual(SpokenPunctuation.apply("App Dot S W I F T"), "App.swift")
        XCTAssertEqual(SpokenPunctuation.apply("conduct Dot Mdc"), "conduct.mdc")
    }

    func testConductDotMdcJoinsAndIsIdempotent() {
        let joined = SpokenPunctuation.apply("conduct dot mdc")
        XCTAssertEqual(joined, "conduct.mdc")
        // Cleanup sometimes re-expands; re-applying must restore the join.
        XCTAssertEqual(SpokenPunctuation.apply("conduct dot mdc"), "conduct.mdc")
        XCTAssertEqual(SpokenPunctuation.apply(joined), "conduct.mdc")
        XCTAssertEqual(
            SpokenPunctuation.apply(
                "Is any part of conduct dot mdc outside of those two active hooks"
            ),
            "Is any part of conduct.mdc outside of those two active hooks"
        )
    }

    func testSpacedExtensionDoesNotEatProseAfterPeriod() {
        // Space after `.` means sentence boundary, not a file extension.
        XCTAssertEqual(
            SpokenPunctuation.apply("Mr. A B C was here"),
            "Mr. A B C was here"
        )
        XCTAssertEqual(
            SpokenPunctuation.apply("see section. A B was wrong"),
            "see section. A B was wrong"
        )
        // Glued outline label with unknown "extension" must not collapse.
        XCTAssertEqual(
            SpokenPunctuation.apply("see section.a b was wrong"),
            "see section.a b was wrong"
        )
    }

    func testForwardSlashBetweenWords() {
        XCTAssertEqual(
            SpokenPunctuation.apply("myauditandfix forward slash commitprmerge"),
            "myauditandfix/commitprmerge"
        )
    }

    func testForwardSlashStandalone() {
        XCTAssertEqual(
            SpokenPunctuation.apply("type forward slash at the start"),
            "type / at the start"
        )
    }

    func testBackSlashBetweenWords() {
        XCTAssertEqual(
            SpokenPunctuation.apply("foo back slash bar"),
            "foo\\bar"
        )
    }

    func testBackSlashStandalone() {
        XCTAssertEqual(SpokenPunctuation.apply("escape backslash here"), "escape \\ here")
    }

    func testColonBetweenWords() {
        XCTAssertEqual(SpokenPunctuation.apply("Array colon String"), "Array:String")
    }

    func testCommonCodingSymbols() {
        let cases: [(String, String)] = [
            ("assign equals sign five", "assign = five"),
            ("x plus sign y", "x + y"),
            ("a minus sign b", "a - b"),
            ("use asterisk wildcard", "use * wildcard"),
            ("star operator", "* operator"),
            ("foo semicolon bar", "foo ; bar"),
            ("hash sign include", "# include"),
            ("at sign MainActor", "@ MainActor"),
            ("dollar sign zero", "$ zero"),
            ("percent sign done", "% done"),
            ("less than sign T greater than sign", "< T >"),
            ("not equals nil", "!= nil"),
            ("equals equals zero", "== zero"),
            ("plus equals one", "+= one"),
            ("fat arrow Unit", "=> Unit"),
            ("thin arrow Void", "-> Void"),
            ("double colon self", ":: self"),
            ("open brace close brace", "{ }"),
            ("open bracket close bracket", "[ ]"),
            ("backtick SwiftUI dot View backtick", "` SwiftUI.View `"),
            ("comma separated", ", separated"),
            ("pipe nil coalescing", "| nil coalescing"),
            ("vertical bar filter", "| filter"),
            ("caret anchor", "^ anchor"),
            ("tilde home", "~ home"),
            ("question mark optional", "? optional"),
            ("exclamation mark force unwrap", "! force unwrap"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SpokenPunctuation.apply(input), expected, "input: \(input)")
        }
    }

    func testProseGuardrailsUnchanged() {
        let prose = [
            "cost less than five dollars",
            "greater than expected growth",
            "hash map and hash table",
            "open a new tab in the browser",
            "review and sign the document",
        ]
        for text in prose {
            XCTAssertEqual(SpokenPunctuation.apply(text), text, "prose corrupted: \(text)")
        }
    }
}
