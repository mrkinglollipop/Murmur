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

    func testPreparedDictationInsertJoinsTakesWithoutGlue() {
        XCTAssertEqual(
            AutocorrectEngine.preparedDictationInsert(
                transcript: "hello there",
                beforeInput: "",
                trailingSpace: true
            ),
            "hello there "
        )
        XCTAssertEqual(
            AutocorrectEngine.preparedDictationInsert(
                transcript: "more words",
                beforeInput: "hello there",
                trailingSpace: true
            ),
            " more words "
        )
        XCTAssertEqual(
            AutocorrectEngine.preparedDictationInsert(
                transcript: "more words",
                beforeInput: "hello there ",
                trailingSpace: true
            ),
            "more words "
        )
        XCTAssertEqual(
            AutocorrectEngine.preparedDictationInsert(
                transcript: "  more words  ",
                beforeInput: "hello.",
                trailingSpace: true
            ),
            " more words "
        )
        XCTAssertEqual(
            AutocorrectEngine.preparedDictationInsert(
                transcript: "hello",
                beforeInput: "(",
                trailingSpace: true
            ),
            "hello "
        )
        XCTAssertEqual(
            AutocorrectEngine.preparedDictationInsert(
                transcript: "hello",
                beforeInput: "\n",
                trailingSpace: true
            ),
            "hello "
        )
        XCTAssertEqual(
            AutocorrectEngine.preparedDictationInsert(
                transcript: "   ",
                beforeInput: "hello",
                trailingSpace: true
            ),
            ""
        )
        XCTAssertEqual(
            AutocorrectEngine.preparedDictationInsert(
                transcript: "hello",
                beforeInput: "hi",
                trailingSpace: false
            ),
            " hello"
        )
    }

    func testPunctuationEatsTrailingSwipeSpace() {
        XCTAssertTrue(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: "."))
        XCTAssertTrue(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: ","))
        XCTAssertTrue(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: "!"))
        XCTAssertTrue(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: "\n"))
        // A typed space must NOT eat the auto space — that deleteBackward
        // after a bulk insert wiped a dictated sentence (2026-08-25).
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

    // MARK: - Hidden-selection loss recovery (2026-08-25 sentence wipe)

    /// Clean insert: after == before + inserted → nothing lost.
    func testLostTextAfterInsertCleanInsertIsNil() {
        XCTAssertNil(AutocorrectEngine.lostTextAfterInsert(
            before: "The whole sentence", after: "The whole sentence ", inserted: " "))
    }

    /// The host replaced a hidden selection with the insert: the swallowed
    /// span is exactly the gap between the surviving prefix and `before`.
    func testLostTextAfterInsertReturnsSwallowedSelection() {
        XCTAssertEqual(
            AutocorrectEngine.lostTextAfterInsert(
                before: "Hi. The whole sentence", after: "Hi. ", inserted: " "),
            " The whole sentence"
        )
    }

    /// Context window slid (front chars dropped): prefix relation breaks —
    /// never "restore" from a slid window.
    func testLostTextAfterInsertWindowSlideIsNil() {
        XCTAssertNil(AutocorrectEngine.lostTextAfterInsert(
            before: "abcdef", after: "bcdef ", inserted: " "))
        XCTAssertNil(AutocorrectEngine.lostTextAfterInsert(
            before: "abc", after: "xyz ", inserted: " "))
    }

    /// Insert missing from the tail (host did something else entirely): nil.
    func testLostTextAfterInsertMissingInsertIsNil() {
        XCTAssertNil(AutocorrectEngine.lostTextAfterInsert(
            before: "abc", after: "ab", inserted: " "))
        XCTAssertNil(AutocorrectEngine.lostTextAfterInsert(
            before: "abc", after: "abc x", inserted: " "))
    }

    /// A normal single delete (1 char, or 2 with a combining mark) is clean.
    func testLostTailAfterSingleDeleteCleanIsNil() {
        XCTAssertNil(AutocorrectEngine.lostTailAfterSingleDelete(before: "word ", after: "word"))
        XCTAssertNil(AutocorrectEngine.lostTailAfterSingleDelete(before: "word ", after: "wor"))
    }

    /// deleteBackward took a hidden tail selection: restore everything except
    /// the one character the user asked to remove.
    func testLostTailAfterSingleDeleteRestoresAllButIntended() {
        XCTAssertEqual(
            AutocorrectEngine.lostTailAfterSingleDelete(
                before: "Hi. The whole sentence ", after: "Hi. "),
            "The whole sentence"
        )
    }

    /// Loss that is not a tail (remainder is not a prefix): unrecoverable, nil.
    func testLostTailAfterSingleDeleteNonTailIsNil() {
        XCTAssertNil(AutocorrectEngine.lostTailAfterSingleDelete(
            before: "abcdefgh", after: "efgh"))
    }

    /// A typed space never eats the auto trailing space: that deleteBackward
    /// right after a bulk dictation insert is what wiped a sentence on hosts
    /// that treat the insert as one deletable clump. The doubled space is
    /// handled by the non-deleting period walk instead.
    func testTypedSpaceDoesNotEatAutoTrailingSpace() {
        XCTAssertFalse(AutocorrectEngine.shouldEatTrailingSwipeSpace(beforeInserting: " "))
    }

    /// Ground-truth restore: a wipe leaves shared prefix + big silent loss +
    /// at most a few typed chars. Gradual deletes and sends never match.
    func testWipeRestorePlan() {
        // Phantom wipe: sentence gone, a typed period survives at the tail.
        let plan = AutocorrectEngine.wipeRestorePlan(
            previous: "Hi. The whole dictated sentence sits here  ",
            current: "Hi. .",
            afterContext: ""
        )
        XCTAssertEqual(plan?.lost, "The whole dictated sentence sits here  ")
        XCTAssertEqual(plan?.walkBack, 1)
        // Whole-field wipe leaving only the typed space.
        let whole = AutocorrectEngine.wipeRestorePlan(
            previous: "The whole dictated sentence sits here ",
            current: " ",
            afterContext: ""
        )
        XCTAssertEqual(whole?.lost, "The whole dictated sentence sits here ")
        XCTAssertEqual(whole?.walkBack, 1)
        // Send / cleared field: never restore into empty by default.
        XCTAssertNil(AutocorrectEngine.wipeRestorePlan(
            previous: "The whole dictated sentence sits here ", current: "", afterContext: ""))
        // Total wipe inside the keystroke risk window: restore is allowed.
        let total = AutocorrectEngine.wipeRestorePlan(
            previous: "The whole dictated sentence sits here ",
            current: "",
            afterContext: "",
            allowEmptyCurrent: true
        )
        XCTAssertEqual(total?.lost, "The whole dictated sentence sits here ")
        XCTAssertEqual(total?.walkBack, 0)
        // Normal typing grows the context.
        XCTAssertNil(AutocorrectEngine.wipeRestorePlan(
            previous: "hello there my friend okay", current: "hello there my friend okayx", afterContext: ""))
        // Single backspace: loss below threshold.
        XCTAssertNil(AutocorrectEngine.wipeRestorePlan(
            previous: "hello there my friend okay", current: "hello there my friend oka", afterContext: ""))
        // Field switch to a longer different field: extra too large.
        XCTAssertNil(AutocorrectEngine.wipeRestorePlan(
            previous: "the entire dictated sentence lives here",
            current: "completely different field contents", afterContext: ""))
    }

    /// Tapping earlier in the text shrinks the before-context exactly like a
    /// wipe — but the "lost" text still sits after the caret. Never restore
    /// when anything follows the caret (the paste-on-click regression).
    func testWipeRestorePlanNeverFiresMidText() {
        XCTAssertNil(AutocorrectEngine.wipeRestorePlan(
            previous: "Hi. The whole dictated sentence sits here ",
            current: "Hi. The",
            afterContext: " whole dictated sentence sits here "
        ))
    }

    /// A reported highlight whose text lives inside the recent dictation
    /// insert is the host's phantom pending-region selection, never deletable.
    func testIsLikelyHostHighlight() {
        let take = "the whole dictated sentence with several words "
        XCTAssertTrue(AutocorrectEngine.isLikelyHostHighlight(
            selected: "several words ", recentBulkInsert: take))
        XCTAssertTrue(AutocorrectEngine.isLikelyHostHighlight(
            selected: take, recentBulkInsert: take))
        XCTAssertFalse(AutocorrectEngine.isLikelyHostHighlight(
            selected: "unrelated text", recentBulkInsert: take))
        XCTAssertFalse(AutocorrectEngine.isLikelyHostHighlight(
            selected: "several words", recentBulkInsert: nil))
        XCTAssertFalse(AutocorrectEngine.isLikelyHostHighlight(
            selected: " a ", recentBulkInsert: take), "1-char trimmed needle too weak")
    }

    /// Bulk inserts go in as word-boundary chunks that rejoin exactly.
    func testBulkInsertChunksRejoinExactly() {
        let text = String(repeating: "hello world ", count: 12)  // 144 chars
        let chunks = AutocorrectEngine.bulkInsertChunks(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks.dropLast() {
            XCTAssertTrue(chunk.hasSuffix(" "), "chunks cut only after spaces")
        }
    }

    func testBulkInsertChunksShortAndEdgeCases() {
        XCTAssertEqual(AutocorrectEngine.bulkInsertChunks("short text "), ["short text "])
        XCTAssertEqual(AutocorrectEngine.bulkInsertChunks(""), [])
        let blob = String(repeating: "x", count: 120)  // no spaces: one chunk
        XCTAssertEqual(AutocorrectEngine.bulkInsertChunks(blob), [blob])
    }

    /// Non-deleting double-space-period: trailing-space run to step over.
    func testDoubleSpacePeriodWalk() {
        XCTAssertEqual(AutocorrectEngine.doubleSpacePeriodWalk(beforeInput: "word "), 1)
        XCTAssertEqual(AutocorrectEngine.doubleSpacePeriodWalk(beforeInput: "sentence  "), 2)
        XCTAssertEqual(AutocorrectEngine.doubleSpacePeriodWalk(beforeInput: "ok2 "), 1)
        XCTAssertNil(AutocorrectEngine.doubleSpacePeriodWalk(beforeInput: "word   "))
        XCTAssertNil(AutocorrectEngine.doubleSpacePeriodWalk(beforeInput: "word"))
        XCTAssertNil(AutocorrectEngine.doubleSpacePeriodWalk(beforeInput: "word. "))
        XCTAssertNil(AutocorrectEngine.doubleSpacePeriodWalk(beforeInput: " "))
        XCTAssertNil(AutocorrectEngine.doubleSpacePeriodWalk(beforeInput: ""))
    }
}
