import XCTest

final class AutocorrectEngineTests: XCTestCase {
    func testWordSpanTakesTrailingLettersAndApostrophes() {
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "hello th"), "th")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "it's"), "it's")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "hello "), "")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: ""), "")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "teh"), "teh")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "say don't"), "don't")
    }

    func testWordSpanStopsAtPunctuation() {
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "hello,th"), "th")
        XCTAssertEqual(AutocorrectEngine.wordSpan(beforeInput: "ok."), "")
    }

    func testSkipDigitsAcronymsAndURLs() {
        XCTAssertTrue(AutocorrectEngine.shouldSkip("abc123"))
        XCTAssertTrue(AutocorrectEngine.shouldSkip("NASA"))
        XCTAssertTrue(AutocorrectEngine.shouldSkip("OK"))
        XCTAssertTrue(AutocorrectEngine.shouldSkip("https://example.com"))
        XCTAssertTrue(AutocorrectEngine.shouldSkip("www.apple.com"))
        XCTAssertTrue(AutocorrectEngine.shouldSkip("foo.bar"))
        XCTAssertFalse(AutocorrectEngine.shouldSkip("teh"))
        XCTAssertFalse(AutocorrectEngine.shouldSkip("The"))
        XCTAssertFalse(AutocorrectEngine.shouldSkip("I"))
    }

    func testCommitText() {
        XCTAssertTrue(AutocorrectEngine.isCommitText(" "))
        XCTAssertTrue(AutocorrectEngine.isCommitText("."))
        XCTAssertTrue(AutocorrectEngine.isCommitText(","))
        XCTAssertTrue(AutocorrectEngine.isCommitText("\n"))
        XCTAssertFalse(AutocorrectEngine.isCommitText("'"))
        XCTAssertFalse(AutocorrectEngine.isCommitText("a"))
        XCTAssertFalse(AutocorrectEngine.isCommitText("the"))
    }

    func testApplyCase() {
        XCTAssertEqual(AutocorrectEngine.applyCase(template: "teh", correction: "the"), "the")
        XCTAssertEqual(AutocorrectEngine.applyCase(template: "Teh", correction: "the"), "The")
        XCTAssertEqual(AutocorrectEngine.applyCase(template: "TEH", correction: "the"), "THE")
    }

    func testReplacementMath() {
        let replacement = AutocorrectEngine.replacement(span: "teh", correction: "the")
        XCTAssertEqual(replacement.deleteCount, 3)
        XCTAssertEqual(replacement.insert, "the")
        let titled = AutocorrectEngine.replacement(span: "Teh", correction: "the")
        XCTAssertEqual(titled.deleteCount, 3)
        XCTAssertEqual(titled.insert, "The")
    }

    func testPrefixMatchesExcludesExactAndRespectsLimit() {
        let list = ["the", "then", "there", "their", "theme"]
        XCTAssertEqual(
            AutocorrectEngine.prefixMatches(prefix: "the", in: list, limit: 3),
            ["then", "there", "their"]
        )
        XCTAssertEqual(
            AutocorrectEngine.prefixMatches(prefix: "the", in: ["Then", "THERE", "the"], limit: 3),
            ["Then", "THERE"]
        )
    }

    func testCommittedSpanKeepsTrailingWhitespace() {
        let spaced = AutocorrectEngine.committedSpan(beforeInput: "hello the ")
        XCTAssertEqual(spaced.word, "the")
        XCTAssertEqual(spaced.trailing, " ")
        let double = AutocorrectEngine.committedSpan(beforeInput: "the  ")
        XCTAssertEqual(double.word, "the")
        XCTAssertEqual(double.trailing, "  ")
        let punct = AutocorrectEngine.committedSpan(beforeInput: "the.")
        XCTAssertEqual(punct.word, "")
        XCTAssertEqual(punct.trailing, "")
        let midWord = AutocorrectEngine.committedSpan(beforeInput: "the")
        XCTAssertEqual(midWord.word, "the")
        XCTAssertEqual(midWord.trailing, "")
    }

    func testNeedsLeadingSpaceAfterWordNotAfterSpace() {
        XCTAssertTrue(AutocorrectEngine.needsLeadingSpace(beforeInput: "hello"))
        XCTAssertTrue(AutocorrectEngine.needsLeadingSpace(beforeInput: "hello."))
        XCTAssertFalse(AutocorrectEngine.needsLeadingSpace(beforeInput: "hello "))
        XCTAssertFalse(AutocorrectEngine.needsLeadingSpace(beforeInput: ""))
        XCTAssertFalse(AutocorrectEngine.needsLeadingSpace(beforeInput: "("))
        XCTAssertFalse(AutocorrectEngine.needsLeadingSpace(beforeInput: "\n"))
    }

    func testPunctuationEatsTrailingSwipeSpace() {
        XCTAssertTrue(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: "."))
        XCTAssertTrue(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: ","))
        XCTAssertTrue(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: "!"))
        XCTAssertTrue(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: "\n"))
        XCTAssertFalse(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: " "))
        XCTAssertFalse(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: "a"))
        XCTAssertFalse(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: "'"))
    }

    func testUniquedDropsDuplicatesAndExcluded() {
        XCTAssertEqual(
            AutocorrectEngine.uniqued(["The", "the", "then", "Then"], excluding: "the", limit: 3),
            ["then"]
        )
    }

    func testPrioritizedLexiconPutsNamesFirst() {
        let merged = AutocorrectEngine.prioritizedLexicon(
            priority: ["Matthew", "Schwartz"],
            frequency: ["the", "and", "matthew"]
        )
        XCTAssertEqual(merged.first, "matthew")
        XCTAssertEqual(merged[1], "schwartz")
        XCTAssertTrue(merged.contains("the"))
    }

    func testPreferredCasingKeepsContactCapitalization() {
        let map = AutocorrectEngine.preferredCasing(["Matthew", "the"])
        XCTAssertEqual(map["matthew"], "Matthew")
    }

    func testPunctuationSuggestionAndPeriodAttach() {
        XCTAssertTrue(AutocorrectEngine.isPunctuationSuggestion("."))
        XCTAssertTrue(AutocorrectEngine.isPunctuationSuggestion("?"))
        XCTAssertFalse(AutocorrectEngine.isPunctuationSuggestion("hello."))
        XCTAssertEqual(AutocorrectEngine.periodAttachedWord("hello."), "hello")
        XCTAssertNil(AutocorrectEngine.periodAttachedWord("hello"))
        XCTAssertEqual(
            AutocorrectEngine.idlePunctuation(beforeInput: "hello "),
            [".", "?", "!"]
        )
        XCTAssertTrue(AutocorrectEngine.idlePunctuation(beforeInput: "").isEmpty)
    }

    func testContractionsRestoreIllAndHes() {
        XCTAssertEqual(AutocorrectEngine.suggestedContraction("ill"), "I'll")
        XCTAssertEqual(AutocorrectEngine.suggestedContraction("Ill"), "I'll")
        XCTAssertEqual(AutocorrectEngine.suggestedContraction("hes"), "he's")
        XCTAssertEqual(AutocorrectEngine.suggestedContraction("Hes"), "He's")
        XCTAssertEqual(AutocorrectEngine.suggestedContraction("hell"), "he'll")
        XCTAssertNil(AutocorrectEngine.suggestedContraction("hello"))
    }

    func testForcedContractionSkipsLowercaseIll() {
        XCTAssertNil(AutocorrectEngine.forcedContraction("ill"))
        XCTAssertEqual(AutocorrectEngine.forcedContraction("Ill"), "I'll")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("hes"), "he's")
        XCTAssertNil(AutocorrectEngine.forcedContraction("hell"))
        XCTAssertNil(AutocorrectEngine.forcedContraction("Hell"))
    }

    func testCommonAmbiguousContractionsAreSuggestOnly() {
        XCTAssertEqual(AutocorrectEngine.suggestedContraction("its"), "it's")
        XCTAssertNil(AutocorrectEngine.forcedContraction("its"))
        XCTAssertNil(AutocorrectEngine.forcedContraction("Its"))
        XCTAssertEqual(AutocorrectEngine.suggestedContraction("were"), "we're")
        XCTAssertNil(AutocorrectEngine.forcedContraction("were"))
        XCTAssertEqual(AutocorrectEngine.suggestedContraction("lets"), "let's")
        XCTAssertNil(AutocorrectEngine.forcedContraction("lets"))
        XCTAssertEqual(AutocorrectEngine.suggestedContraction("well"), "we'll")
        XCTAssertNil(AutocorrectEngine.forcedContraction("well"))
    }

    func testCommonUnambiguousContractionsForceOnSpace() {
        XCTAssertEqual(AutocorrectEngine.forcedContraction("dont"), "don't")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("im"), "I'm")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("wouldve"), "would've")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("couldve"), "could've")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("shouldve"), "should've")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("theyd"), "they'd")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("youd"), "you'd")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("yall"), "y'all")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("aint"), "ain't")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("hows"), "how's")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("oclock"), "o'clock")
        XCTAssertEqual(AutocorrectEngine.forcedContraction("maam"), "ma'am")
    }

    func testIContractionsStayCapital() {
        for key in ["im", "ill", "id", "ive"] {
            let restored = AutocorrectEngine.restoreContraction(key)
            XCTAssertTrue(restored.hasPrefix("I'"), restored)
            XCTAssertEqual(
                AutocorrectEngine.capitalizedIContraction(restored.lowercased()),
                restored
            )
        }
        XCTAssertEqual(AutocorrectEngine.preferredCasing(["i'll"])["i'll"], "I'll")
        XCTAssertEqual(AutocorrectEngine.forcedPronounI("i"), "I")
        XCTAssertNil(AutocorrectEngine.forcedPronounI("I"))
        XCTAssertNil(AutocorrectEngine.forcedPronounI("if"))
    }

    func testSwipePresentationKeepsHellAndIts() {
        let hell = AutocorrectEngine.swipePresentation(for: "hell")
        XCTAssertEqual(hell.primary, "hell")
        XCTAssertEqual(hell.extra, "he'll")
        let its = AutocorrectEngine.swipePresentation(for: "its")
        XCTAssertEqual(its.primary, "its")
        XCTAssertEqual(its.extra, "it's")
        let dont = AutocorrectEngine.swipePresentation(for: "dont")
        XCTAssertEqual(dont.primary, "don't")
        XCTAssertNil(dont.extra)
        let ill = AutocorrectEngine.swipePresentation(for: "ill")
        XCTAssertEqual(ill.primary, "I'll")
        XCTAssertNil(ill.extra)
    }

    func testSplitWordsInsertsMissingSpace() {
        let known = [
            "the", "be", "to", "of", "and", "he", "there", "here",
            "together", "going", "done", "well", "am"
        ]
        XCTAssertEqual(AutocorrectEngine.splitWords("hethe", known: known), "he the")
        XCTAssertEqual(AutocorrectEngine.splitWords("hethere", known: known), "he there")
        XCTAssertEqual(AutocorrectEngine.splitWords("Hethe", known: known), "He the")
        XCTAssertEqual(AutocorrectEngine.forcedSplit("hethe", known: known), "he the")
        XCTAssertEqual(AutocorrectEngine.splitWords("imgoing", known: known), "I'm going")
        XCTAssertEqual(AutocorrectEngine.forcedSplit("imgoing", known: known), "I'm going")
        XCTAssertNil(AutocorrectEngine.splitWords("together", known: known))
        XCTAssertNil(AutocorrectEngine.splitWords("he", known: known))
        XCTAssertNil(AutocorrectEngine.splitWords("hello", known: known))
    }

    func testForcedSplitSurvivesNamesPrefixLikeProduction() {
        var names = ["Alice", "Bob"]
        names.append(contentsOf: (0..<800).map { "Name\($0)" })
        let frequency = ["the", "he", "there", "together", "going"]
        let known = names + frequency
        XCTAssertGreaterThan(names.count, 500)
        XCTAssertNil(
            AutocorrectEngine.forcedSplit("hethe", known: known),
            "merged-index ranks must not be treated as frequency ranks"
        )
        XCTAssertEqual(
            AutocorrectEngine.forcedSplit("hethe", known: known, frequencyOrder: frequency),
            "he the"
        )
        XCTAssertEqual(
            AutocorrectEngine.forcedSplit("hethere", known: known, frequencyOrder: frequency),
            "he there"
        )
        XCTAssertNil(AutocorrectEngine.forcedSplit("together", known: known, frequencyOrder: frequency))
        XCTAssertEqual(
            AutocorrectEngine.forcedSplit("imgoing", known: known, frequencyOrder: frequency),
            "I'm going"
        )
        XCTAssertNil(
            AutocorrectEngine.forcedSplit(
                "therapist",
                known: known + ["rapist"],
                frequencyOrder: frequency + ["rapist"]
            )
        )
    }

    func testPrioritizedLexiconIncludesMissingContractions() {
        let merged = AutocorrectEngine.prioritizedLexicon(
            priority: [],
            frequency: ["the", "hell", "its"]
        )
        XCTAssertTrue(merged.contains("he'll"))
        XCTAssertTrue(merged.contains("it's") || merged.contains("it's".lowercased()))
        XCTAssertTrue(merged.contains("i'll"))
    }

    func testPrefixMatchesFindsApostropheForm() {
        XCTAssertEqual(
            AutocorrectEngine.prefixMatches(prefix: "ill", in: ["i'll", "illness", "illicit"], limit: 3),
            ["i'll", "illness", "illicit"]
        )
    }

    func testSentenceCapitalizationIgnoresBareSpace() {
        XCTAssertTrue(AutocorrectEngine.shouldCapitalizeSentence(beforeInput: ""))
        XCTAssertTrue(AutocorrectEngine.shouldCapitalizeSentence(beforeInput: "Hello. "))
        XCTAssertFalse(AutocorrectEngine.shouldCapitalizeSentence(beforeInput: "hello "))
        XCTAssertFalse(AutocorrectEngine.shouldCapitalizeSentence(beforeInput: " "))
    }

    func testLatinScriptRejectsCJK() {
        XCTAssertTrue(AutocorrectEngine.isLatinScriptWord("Schwartz"))
        XCTAssertTrue(AutocorrectEngine.isLatinScriptWord("José"))
        XCTAssertFalse(AutocorrectEngine.isLatinScriptWord("東京"))
        XCTAssertFalse(AutocorrectEngine.isLatinScriptWord("hello!"))
    }

    func testLexiconSwipeDropsShortForeignWords() {
        let frequency: Set<String> = ["to", "the", "and"]
        XCTAssertFalse(AutocorrectEngine.allowLexiconInSwipe("tio", frequency: frequency))
        XCTAssertFalse(AutocorrectEngine.allowLexiconInSwipe("東京", frequency: frequency))
        XCTAssertTrue(AutocorrectEngine.allowLexiconInSwipe("to", frequency: frequency))
        XCTAssertTrue(AutocorrectEngine.allowLexiconInSwipe("Schwartz", frequency: frequency))
    }

    func testShouldAbortMultiCharDeleteRejectsClauseAndGluedBlob() {
        XCTAssertTrue(
            AutocorrectEngine.shouldAbortMultiCharDelete(
                selected: "hello there friend",
                before: "hello there friend"
            ),
            "stale sentence suffix"
        )
        XCTAssertTrue(
            AutocorrectEngine.shouldAbortMultiCharDelete(
                selected: "hellothereyo",
                before: "hellothereyo"
            ),
            "glued blob ≤12 that is the whole suffix"
        )
        XCTAssertTrue(
            AutocorrectEngine.shouldAbortMultiCharDelete(
                selected: "hellohowareyou",
                before: "hellohowareyou"
            ),
            "glued blob >12"
        )
        XCTAssertTrue(
            AutocorrectEngine.shouldAbortMultiCharDelete(
                selected: "hello",
                before: "say hellohello"
            ),
            "suffix match that is not the last token"
        )
        XCTAssertFalse(
            AutocorrectEngine.shouldAbortMultiCharDelete(
                selected: "world",
                before: "say world"
            ),
            "last whitespace-delimited token suffix"
        )
        XCTAssertFalse(
            AutocorrectEngine.shouldAbortMultiCharDelete(
                selected: "hello there",
                before: "I said "
            ),
            "real phrase highlight is not a suffix of before"
        )
        XCTAssertFalse(
            AutocorrectEngine.shouldAbortMultiCharDelete(
                selected: "congratulations",
                before: "say "
            ),
            "real long-word highlight is not a suffix of before"
        )
        XCTAssertFalse(
            AutocorrectEngine.shouldAbortMultiCharDelete(
                selected: "hi",
                before: "say hi"
            )
        )
        XCTAssertFalse(
            AutocorrectEngine.shouldAbortMultiCharDelete(
                selected: "word",
                before: "prefix "
            ),
            "a short highlight that is not the caret suffix is still a real selection"
        )
        XCTAssertFalse(
            AutocorrectEngine.shouldAbortMultiCharDelete(selected: "x", before: "ax")
        )
        XCTAssertTrue(AutocorrectEngine.shouldAbortDeleteLoop(beforeCount: 17, afterCount: 3))
        XCTAssertFalse(AutocorrectEngine.shouldAbortDeleteLoop(beforeCount: 5, afterCount: 4))
    }

    func testDocumentMutationDecisionAllowsEmptyAndDeniesClause() {
        XCTAssertEqual(
            AutocorrectEngine.documentMutationDecision(
                selected: nil,
                allowSingleCharacterSelection: true
            ),
            .allow
        )
        XCTAssertEqual(
            AutocorrectEngine.documentMutationDecision(
                selected: "",
                allowSingleCharacterSelection: true
            ),
            .allow
        )
        XCTAssertEqual(
            AutocorrectEngine.documentMutationDecision(
                selected: "x",
                allowSingleCharacterSelection: true
            ),
            .allow
        )
        XCTAssertEqual(
            AutocorrectEngine.documentMutationDecision(
                selected: "x",
                allowSingleCharacterSelection: false
            ),
            .collapseOneCharacterSelection
        )
        XCTAssertEqual(
            AutocorrectEngine.documentMutationDecision(
                selected: "hello there friend",
                allowSingleCharacterSelection: true
            ),
            .deny
        )
        XCTAssertEqual(
            AutocorrectEngine.documentMutationDecision(
                selected: "hello there friend",
                allowSingleCharacterSelection: false
            ),
            .deny
        )
    }

    func testPeriodSpaceRemovalMustStayASingleCharacter() {
        XCTAssertTrue(AutocorrectEngine.isSafePeriodSpaceRemoval(beforeCount: 6, afterCount: 5))
        XCTAssertTrue(AutocorrectEngine.isSafePeriodSpaceRemoval(beforeCount: 6, afterCount: 4))
        XCTAssertFalse(AutocorrectEngine.isSafePeriodSpaceRemoval(beforeCount: 6, afterCount: 6))
        XCTAssertFalse(AutocorrectEngine.isSafePeriodSpaceRemoval(beforeCount: 20, afterCount: 0))
        XCTAssertFalse(AutocorrectEngine.isSafePeriodSpaceRemoval(beforeCount: 6, afterCount: 7))
        XCTAssertTrue(AutocorrectEngine.shouldInsertPeriodAfterRemovingSpace(beforeInput: "hello"))
        XCTAssertTrue(AutocorrectEngine.shouldInsertPeriodAfterRemovingSpace(beforeInput: "ok2"))
        XCTAssertFalse(AutocorrectEngine.shouldInsertPeriodAfterRemovingSpace(beforeInput: "hello "))
        XCTAssertFalse(AutocorrectEngine.shouldInsertPeriodAfterRemovingSpace(beforeInput: "hello."))
        XCTAssertFalse(AutocorrectEngine.shouldInsertPeriodAfterRemovingSpace(beforeInput: ""))
    }

    func testShouldTeachSkipsKnownEnglish() {
        XCTAssertFalse(AutocorrectEngine.shouldTeach("the", known: ["the", "and"]))
        XCTAssertTrue(AutocorrectEngine.shouldTeach("Schwartz", known: ["the", "and"]))
        XCTAssertFalse(AutocorrectEngine.shouldTeach("東京", known: []))
        XCTAssertFalse(AutocorrectEngine.shouldTeach("a", known: []))
    }
}
