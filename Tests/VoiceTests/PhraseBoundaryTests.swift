import XCTest
@testable import Voice

/// Whole-phrase matching for dictionary variants and snippet triggers.
/// Punctuation-edged phrases (".net", "@work", "c++") never matched under the
/// old `\b...\b` pattern; plain word phrases must keep their exact behavior.
/// Stores always get temp fileURLs — never production App Support.
final class PhraseBoundaryTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        super.tearDown()
    }

    private func tempFile(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-test-\(name)-\(UUID().uuidString).json")
        tempURLs.append(url)
        return url
    }

    private func makeDictionaryStore(_ name: String) -> DictionaryStore {
        DictionaryStore(fileURL: tempFile(name), blocklistFileURL: tempFile("\(name)-blocklist"))
    }

    private func matches(_ phrase: String, in text: String) -> Int {
        let regex = try! NSRegularExpression(
            pattern: PhraseBoundaryPattern.wholePhrase(for: phrase),
            options: [.caseInsensitive]
        )
        return regex.numberOfMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
    }

    // MARK: - Pattern itself

    func testPlainWordKeepsWholeWordBehavior() {
        XCTAssertEqual(matches("cat", in: "the cat sat"), 1)
        XCTAssertEqual(matches("cat", in: "concatenate"), 0, "must not match inside a longer word")
        XCTAssertEqual(matches("cat", in: "cat"), 1, "string start and end are boundaries")
        XCTAssertEqual(matches("cat", in: "cat, dog"), 1, "punctuation is a boundary")
    }

    func testMultiWordPhraseKeepsWholeWordBehavior() {
        XCTAssertEqual(matches("my email address", in: "send my email address please"), 1)
        XCTAssertEqual(matches("my email address", in: "my email addresses"), 0)
    }

    func testLeadingPunctuationPhraseMatches() {
        XCTAssertEqual(matches(".net", in: "we ship on .net today"), 1)
        XCTAssertEqual(matches("@work", in: "ping me @work tomorrow"), 1)
        XCTAssertEqual(matches("@work", in: "user@workplace"), 0, "must not match inside a word")
    }

    func testTrailingPunctuationPhraseMatches() {
        XCTAssertEqual(matches("c++", in: "i write c++ daily"), 1)
        XCTAssertEqual(matches("c++", in: "i write c++"), 1, "end of string is a boundary")
        XCTAssertEqual(matches("c++", in: "c++x"), 0, "must not match when a word char follows")
    }

    func testRegexMetacharactersInPhraseAreEscaped() {
        XCTAssertEqual(matches("c++", in: "cccc"), 0, "'+' must be literal, not a quantifier")
    }

    // MARK: - SnippetsStore.expand

    func testSnippetExpandsPunctuationEdgedTrigger() {
        let store = SnippetsStore(fileURL: tempFile("snippets-punct"))
        store.add(trigger: "@work", expansion: "matt@example.com")
        XCTAssertEqual(store.expand("ping me @work tomorrow"), "ping me matt@example.com tomorrow")
    }

    func testSnippetExpandsTrailingPunctuationTrigger() {
        let store = SnippetsStore(fileURL: tempFile("snippets-cpp"))
        store.add(trigger: "c++", expansion: "C plus plus")
        XCTAssertEqual(store.expand("i write c++ daily"), "i write C plus plus daily")
    }

    func testSnippetStillDoesNotExpandInsideWord() {
        let store = SnippetsStore(fileURL: tempFile("snippets-inside"))
        store.add(trigger: "@work", expansion: "matt@example.com")
        XCTAssertEqual(store.expand("user@workplace"), "user@workplace")
    }

    func testSnippetWordTriggerUnchanged() {
        let store = SnippetsStore(fileURL: tempFile("snippets-word"))
        store.add(trigger: "see", expansion: "SEE")
        XCTAssertEqual(store.expand("see the seeds"), "SEE the seeds")
    }

    // MARK: - DictionaryStore.correct

    func testDictionaryCorrectsPunctuationEdgedVariant() {
        let store = makeDictionaryStore("dict-punct")
        store.add(term: ".NET", variants: [".net"])
        XCTAssertEqual(store.correct("we ship on .net today").text, "we ship on .NET today")
    }

    /// The phonetic pass substitutes a bare word token with the term verbatim.
    /// With no literal variant to match, a punctuation-edged term used to be
    /// pulled in phonetically and doubled the text's own punctuation
    /// ("we ship on .net" -> "we ship on ..NET").
    func testPhoneticPassDoesNotDuplicateTermPunctuation() {
        let store = makeDictionaryStore("dict-phonetic-punct")
        store.add(term: ".NET", variants: ["dotnet"])
        XCTAssertEqual(store.correct("we ship on .net today").text, "we ship on .net today")
    }

    func testDictionaryWordVariantUnchanged() {
        let store = makeDictionaryStore("dict-word")
        store.add(term: "Kubernetes", variants: ["kubernetis"])
        XCTAssertEqual(store.correct("deploy to kubernetis now").text, "deploy to Kubernetes now")
        XCTAssertEqual(
            store.correct("kubernetisation").text,
            "kubernetisation",
            "must not correct inside a longer word"
        )
    }
}
