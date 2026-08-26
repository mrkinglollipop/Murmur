import Foundation

/// Pure autocorrect helpers. No UIKit so unit tests can run without the appex.
enum AutocorrectEngine {
    struct Replacement: Equatable {
        var deleteCount: Int
        var insert: String
    }

    /// Letters and apostrophes at the end of `beforeInput`. Empty if the caret
    /// follows whitespace or punctuation.
    static func wordSpan(beforeInput: String) -> String {
        var index = beforeInput.endIndex
        while index > beforeInput.startIndex {
            let previous = beforeInput.index(before: index)
            let character = beforeInput[previous]
            if character.isLetter || character == "'" || character == "’" {
                index = previous
            } else {
                break
            }
        }
        return String(beforeInput[index...])
    }

    /// Space, return, or punctuation commits a word. Apostrophe stays in the span.
    static func isCommitText(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        if character == "'" || character == "’" { return false }
        return character.isWhitespace || character.isPunctuation || character.isNewline
    }

    static func shouldSkip(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.contains(where: \.isNumber) { return true }
        if trimmed.count >= 2, trimmed == trimmed.uppercased(), trimmed.allSatisfy(\.isLetter) {
            return true
        }
        let lowered = trimmed.lowercased()
        if lowered.contains("://") || lowered.hasPrefix("www.") { return true }
        if trimmed.contains("."), trimmed.contains(where: \.isLetter) { return true }
        return false
    }

    static func applyCase(template: String, correction: String) -> String {
        if template.count > 1, template == template.uppercased() {
            return correction.uppercased()
        }
        if let first = template.first, first.isUppercase {
            let rest = correction.dropFirst()
            return String(correction.prefix(1)).uppercased() + rest
        }
        return correction
    }

    static func replacement(span: String, correction: String) -> Replacement {
        Replacement(deleteCount: span.count, insert: applyCase(template: span, correction: correction))
    }

    /// Hosts lie about `documentContextBeforeInput`. Never `deleteBackward` a
    /// span the caret does not actually end with. Never eat a phrase: the
    /// non-space core must be a single token.
    static func canReplaceSpan(_ span: String, inBeforeInput context: String) -> Bool {
        guard !span.isEmpty, context.hasSuffix(span) else { return false }
        let word = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return false }
        return !word.contains(where: \.isWhitespace)
    }

    /// Some hosts omit spaces, so a sentence looks like one token
    /// (`hellohowareyou`). Anything longer than a short word in a
    /// whitespace-free context is treated as that lie — all-or-nothing.
    static let maxPlausibleWordLength = 12
    static let maxDeleteLoop = 40

    /// `span.count` if a loop-delete is safe, otherwise `0`. Never a partial
    /// count: deleting fewer characters then inserting a correction garbles.
    /// Long words are allowed when the context has a real space (`say
    /// congratulations`). Newlines are not spaces: `Hi\nhellohowareyou` is
    /// still a glued blob. A whitespace-free context longer than a short
    /// word is the host stripping spaces — all-or-nothing.
    static func allowedDeleteCount(span: String, inBeforeInput context: String) -> Int {
        guard canReplaceSpan(span, inBeforeInput: context) else { return 0 }
        if span.count > maxDeleteLoop { return 0 }
        let word = span.trimmingCharacters(in: .whitespacesAndNewlines)
        if word.count > maxPlausibleWordLength {
            let contextHasSpace = context.contains { $0 == " " || $0 == "\t" }
            if !contextHasSpace { return 0 }
        }
        return span.count
    }

    /// Stop looping if the host ate a chunk (word-delete or a hidden
    /// selection) or the context did not shrink.
    static func shouldAbortDeleteLoop(beforeCount: Int, afterCount: Int) -> Bool {
        if afterCount >= beforeCount { return true }
        return (beforeCount - afterCount) > 2
    }

    /// After `insertText(inserted)` the context should read `before + inserted`.
    /// Hosts can hold a selection they REPORT as empty; `insertText` then
    /// replaces it invisibly (2026-08-25: a double-space erased a whole
    /// dictated sentence with no guard firing). When the post-insert context
    /// ends with the insert but its base is a strict prefix of `before`, the
    /// gap is exactly what the host swallowed — return it so the caller can
    /// put it back. The lost span keeps its boundary whitespace: inserting
    /// `lost + inserted` after removing `inserted` reproduces
    /// `before + inserted` exactly. Nil means the insert looks clean (or the
    /// context window slid, which breaks the prefix relation and must not
    /// trigger a restore).
    static func lostTextAfterInsert(before: String, after: String, inserted: String) -> String? {
        guard !inserted.isEmpty, after.hasSuffix(inserted) else { return nil }
        let afterBase = String(after.dropLast(inserted.count))
        guard afterBase.count < before.count else { return nil }
        guard before.hasPrefix(afterBase) else { return nil }
        let lost = String(before.dropFirst(afterBase.count))
        return lost.isEmpty ? nil : lost
    }

    /// After ONE `deleteBackward`, more than the final character (plus
    /// combining-mark slack) vanished and the remainder is a prefix of
    /// `before`: the host deleted a hidden tail selection. Everything except
    /// the one character the user actually asked to remove is restorable.
    static func lostTailAfterSingleDelete(before: String, after: String) -> String? {
        guard before.count - after.count > 2 else { return nil }
        guard before.hasPrefix(after) else { return nil }
        let lost = String(before.dropFirst(after.count).dropLast(1))
        return lost.isEmpty ? nil : lost
    }

    enum DocumentMutationDecision: Equatable {
        case allow
        case deny
        case collapseOneCharacterSelection
    }

    /// `insertText` / `deleteBackward` replace the whole selection. A
    /// selected clause plus a keystroke wipes the sentence. Collapse is
    /// only a 1-char caret nudge when overwrite is disallowed — never a
    /// multi-char wipe. Side effect stays in KeyboardViewController.
    static func documentMutationDecision(
        selected: String?,
        allowSingleCharacterSelection: Bool
    ) -> DocumentMutationDecision {
        guard let selected, !selected.isEmpty else { return .allow }
        if selected.count == 1 {
            return allowSingleCharacterSelection ? .allow : .collapseOneCharacterSelection
        }
        return .deny
    }

    /// UIKit: a real highlight sits after `documentContextBeforeInput`, so
    /// `before.hasSuffix(selected)` is false — allow (phrase, long word, or
    /// short word). A host lie leaves the caret at the end with stale
    /// `selectedText` still in `before` (`hasSuffix`). Abort those suffix
    /// lies when `selected` is a sentence/phrase (whitespace), long glue
    /// (`count > maxPlausibleWordLength`), or a glued blob that is not the
    /// last whitespace-delimited token (`hellothereyo`). Allow the last
    /// token when count ≤ 12 (`world` in `say world`) so Delete can remove
    /// a host-reported last word.
    static func shouldAbortMultiCharDelete(selected: String, before: String) -> Bool {
        guard selected.count > 1 else { return false }
        guard before.hasSuffix(selected) else { return false }
        if selected.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return true
        }
        if selected.count > maxPlausibleWordLength {
            return true
        }
        guard before.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return true
        }
        let lastToken = before.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).last
            .map(String.init)
        return lastToken != selected
    }

    /// Double-space → period only when the caret follows `letter/digit` + space.
    static func shouldReplaceDoubleSpaceWithPeriod(beforeInput: String) -> Bool {
        guard beforeInput.last == " ",
              let preceding = beforeInput.dropLast().last else { return false }
        return preceding.isLetter || preceding.isNumber
    }

    /// After deleting the trailing space for `. `, the host must have removed
    /// only that space (or a single combining mark). A bigger drop means a
    /// hidden selection or word-delete already ate the sentence.
    static func isSafePeriodSpaceRemoval(beforeCount: Int, afterCount: Int) -> Bool {
        let removed = beforeCount - afterCount
        return removed >= 1 && removed <= 2
    }

    /// Remaining context after a safe space-delete must still end on a word.
    static func shouldInsertPeriodAfterRemovingSpace(beforeInput: String) -> Bool {
        guard let last = beforeInput.last else { return false }
        return last.isLetter || last.isNumber
    }

    /// High-confidence mistypes only. Fuzzy `UITextChecker` guesses stay in the bar.
    static let commonTypos: [String: String] = [
        "teh": "the",
        "adn": "and",
        "taht": "that",
        "hte": "the",
        "recieve": "receive",
        "seperate": "separate",
        "occured": "occurred",
        "definately": "definitely",
        "untill": "until",
        "wich": "which",
        "whihc": "which",
        "thier": "their",
        "woudl": "would",
        "jsut": "just",
        "becuase": "because"
    ]

    static func forcedTypo(_ span: String) -> String? {
        guard let correction = commonTypos[span.lowercased()] else { return nil }
        return applyCase(template: span, correction: correction)
    }

    /// Damerau-Levenshtein (insert/delete/substitute/transpose).
    static func damerauLevenshtein(_ a: String, _ b: String) -> Int {
        let source = Array(a)
        let target = Array(b)
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }
        var table = Array(
            repeating: Array(repeating: 0, count: target.count + 1),
            count: source.count + 1
        )
        for i in 0...source.count { table[i][0] = i }
        for j in 0...target.count { table[0][j] = j }
        for i in 1...source.count {
            for j in 1...target.count {
                let cost = source[i - 1] == target[j - 1] ? 0 : 1
                table[i][j] = min(
                    table[i - 1][j] + 1,
                    table[i][j - 1] + 1,
                    table[i - 1][j - 1] + cost
                )
                if i > 1, j > 1,
                   source[i - 1] == target[j - 2],
                   source[i - 2] == target[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[source.count][target.count]
    }

    /// Force a spell guess only when it is a one-edit common word, not a name.
    static func shouldForceSpelling(
        span: String,
        guess: String,
        frequencyOrder: [String],
        names: Set<String>
    ) -> Bool {
        let typed = span.lowercased()
        let want = guess.lowercased()
        guard typed.count >= 3, typed != want else { return false }
        if names.contains(typed) { return false }
        let frequency = Set(frequencyOrder)
        if frequency.contains(typed) { return false }
        guard frequency.contains(want) else { return false }
        return damerauLevenshtein(typed, want) <= 1
    }

    static func stripApostrophes(_ word: String) -> String {
        word.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
    }

    /// `ill` → `I'll`, `hes` → `he's`. Unknown words return unchanged.
    static func restoreContraction(_ word: String) -> String {
        let key = stripApostrophes(word).lowercased()
        return contractions[key] ?? word
    }

    /// Offer the apostrophe form while typing `ill` / `hes`.
    static func suggestedContraction(_ span: String) -> String? {
        let restored = restoreContraction(span)
        let same = stripApostrophes(restored).lowercased()
            == stripApostrophes(span).lowercased()
        guard same, restored.lowercased() != span.lowercased() else { return nil }
        return capitalizedIContraction(applyCase(template: span, correction: restored))
    }

    /// English `I` contractions are always capital (`I'll`, not `i'll`).
    static func capitalizedIContraction(_ word: String) -> String {
        let lower = word.lowercased()
        guard lower.hasPrefix("i'") else { return word }
        return "I" + word.dropFirst()
    }

    /// Spacebar replacement. Skip real words (`ill`, `hell`, `its`) unless noted.
    static func forcedContraction(_ span: String) -> String? {
        guard let restored = suggestedContraction(span) else { return nil }
        let stripped = stripApostrophes(span).lowercased()
        if suggestOnly.contains(stripped) { return nil }
        if forceWhenCapitalized.contains(stripped) {
            guard let first = span.first, first.isUppercase else { return nil }
        }
        return restored
    }

    /// Mid-sentence pronoun. `"i "` → `"I"`. Already-capital `I` is left alone.
    static func forcedPronounI(_ span: String) -> String? {
        span == "i" ? "I" : nil
    }

    /// Swipe commit: keep real words (`hell`, `its`); put the contraction in slot 2.
    static func swipePresentation(for word: String) -> (primary: String, extra: String?) {
        let restored = capitalizedIContraction(restoreContraction(word))
        let key = stripApostrophes(word).lowercased()
        if suggestOnly.contains(key), restored.lowercased() != word.lowercased() {
            return (word, restored)
        }
        return (restored, nil)
    }

    /// `hethe` → `he the`, `imgoing` → `I'm going`. Nil when the span is already a word.
    ///
    /// `frequencyOrder` is unigram rank (first occurrence). Pass the frequency
    /// list, not a names-prefixed merge — merged indices push `he`/`the` past
    /// the force threshold.
    static func splitWords(
        _ span: String,
        known: [String],
        frequencyOrder: [String]? = nil
    ) -> String? {
        splitResult(span, known: known, frequencyOrder: frequencyOrder)?.text
    }

    /// Spacebar split when both pieces are common (`hethe` → `he the`).
    static func forcedSplit(
        _ span: String,
        known: [String],
        frequencyOrder: [String]? = nil
    ) -> String? {
        guard let result = splitResult(span, known: known, frequencyOrder: frequencyOrder),
              result.highConfidence else { return nil }
        return result.text
    }

    private struct WordSplit {
        var text: String
        var highConfidence: Bool
    }

    private static func splitResult(
        _ span: String,
        known: [String],
        frequencyOrder: [String]?
    ) -> WordSplit? {
        let lower = span.lowercased()
        guard lower.count >= 4, lower.count <= 22 else { return nil }
        guard lower.allSatisfy(\.isLetter) else { return nil }
        var knownSet = Set<String>()
        knownSet.reserveCapacity(min(known.count, 8_192))
        for word in known {
            knownSet.insert(word.lowercased())
        }
        if knownSet.contains(lower) { return nil }

        var rank: [String: Int] = [:]
        rank.reserveCapacity(min(known.count, 8_192))
        let order = frequencyOrder ?? known
        for (index, word) in order.enumerated() {
            let key = word.lowercased()
            if rank[key] == nil { rank[key] = index }
        }
        for key in knownSet where rank[key] == nil {
            rank[key] = 8_000
        }

        var best: (score: Int, left: String, right: String, leftRank: Int, rightRank: Int)?
        for leftLen in 1..<(lower.count - 1) {
            let splitIndex = lower.index(lower.startIndex, offsetBy: leftLen)
            let left = String(lower[..<splitIndex])
            let right = String(lower[splitIndex...])
            if left.count == 1, left != "a", left != "i" { continue }
            guard right.count >= 2 else { continue }
            guard let leftHit = resolveSplitPart(left, rank: rank) else { continue }
            guard let rightHit = resolveSplitPart(right, rank: rank) else { continue }
            let score = leftHit.rank + rightHit.rank
            if best == nil || score < best!.score {
                best = (score, leftHit.display, rightHit.display, leftHit.rank, rightHit.rank)
            }
        }
        guard let best else { return nil }
        let text = applyCase(template: span, correction: "\(best.left) \(best.right)")
        return WordSplit(
            text: text,
            highConfidence: isForcedSplit(
                left: best.left,
                right: best.right,
                leftRank: best.leftRank,
                rightRank: best.rightRank,
                score: best.score
            )
        )
    }

    /// Spacebar split only for missed-space glues (`he the`, `I'm going`), not
    /// `the rapist` hiding inside a real word UITextChecker missed.
    private static let splitAnchors: Set<String> = [
        "a", "i", "to", "in", "on", "at", "of", "if", "or", "be", "he", "we", "me",
        "my", "do", "no", "so", "up", "an", "as", "it", "is", "am", "the", "and",
        "for", "not", "but", "you", "she", "his", "her", "was", "are", "had",
        "has", "have", "this", "that", "with", "from", "they", "them", "then",
        "there", "here", "what", "when", "your", "will", "just", "going"
    ]

    private static func isForcedSplit(
        left: String,
        right: String,
        leftRank: Int,
        rightRank: Int,
        score: Int
    ) -> Bool {
        guard score < 500 else { return false }
        let leftKey = stripApostrophes(left).lowercased()
        let rightKey = stripApostrophes(right).lowercased()
        let leftIsContraction = contractions[leftKey] != nil
            || left.contains("'")
            || left.contains("’")
        let leftOk = splitAnchors.contains(leftKey) || leftIsContraction
        guard leftOk else { return false }
        if splitAnchors.contains(rightKey) { return true }
        if leftIsContraction { return rightRank < 400 }
        if leftKey == "the" || leftKey == "a" || leftKey == "an" { return false }
        return rightRank < 80
    }

    private static func resolveSplitPart(
        _ part: String,
        rank: [String: Int]
    ) -> (display: String, rank: Int)? {
        if let index = rank[part] {
            return (part, index)
        }
        if suggestOnly.contains(part) { return nil }
        if let restored = contractions[part], restored.lowercased() != part {
            return (capitalizedIContraction(restored), 120)
        }
        return nil
    }

    /// Sentence autocap. Whitespace-only context is not a new sentence.
    static func shouldCapitalizeSentence(beforeInput: String) -> Bool {
        if beforeInput.isEmpty { return true }
        if beforeInput.last == "\n" { return true }
        let trimmed = beforeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return ".!?".contains(last)
    }

    private static let forceWhenCapitalized: Set<String> = ["ill", "id"]
    /// Real words. Suggest the apostrophe form; never replace on space or swipe.
    private static let suggestOnly: Set<String> = [
        "hell", "well", "wed", "shed", "shell", "its", "were", "lets"
    ]

    static let contractions: [String: String] = [
        "dont": "don't",
        "cant": "can't",
        "wont": "won't",
        "isnt": "isn't",
        "arent": "aren't",
        "wasnt": "wasn't",
        "werent": "weren't",
        "didnt": "didn't",
        "doesnt": "doesn't",
        "havent": "haven't",
        "hasnt": "hasn't",
        "hadnt": "hadn't",
        "wouldnt": "wouldn't",
        "couldnt": "couldn't",
        "shouldnt": "shouldn't",
        "mustnt": "mustn't",
        "thats": "that's",
        "whats": "what's",
        "whos": "who's",
        "hows": "how's",
        "whens": "when's",
        "whys": "why's",
        "theyre": "they're",
        "youre": "you're",
        "youve": "you've",
        "youll": "you'll",
        "youd": "you'd",
        "theyll": "they'll",
        "theyd": "they'd",
        "thatll": "that'll",
        "itll": "it'll",
        "im": "I'm",
        "ive": "I've",
        "id": "I'd",
        "ill": "I'll",
        "lets": "let's",
        "theres": "there's",
        "heres": "here's",
        "wheres": "where's",
        "hes": "he's",
        "shes": "she's",
        "hell": "he'll",
        "shell": "she'll",
        "well": "we'll",
        "weve": "we've",
        "theyve": "they've",
        "hed": "he'd",
        "wed": "we'd",
        "itd": "it'd",
        "thatd": "that'd",
        "whod": "who'd",
        "whatd": "what'd",
        "whered": "where'd",
        "howd": "how'd",
        "thered": "there'd",
        "its": "it's",
        "were": "we're",
        "aint": "ain't",
        "yall": "y'all",
        "wouldve": "would've",
        "couldve": "could've",
        "shouldve": "should've",
        "mustve": "must've",
        "mightve": "might've",
        "oclock": "o'clock",
        "maam": "ma'am"
    ]

    static func uniqued(_ words: [String], excluding: String, limit: Int) -> [String] {
        let skip = excluding.lowercased()
        var seen = Set<String>()
        var result: [String] = []
        for word in words {
            let key = word.lowercased()
            guard key != skip, seen.insert(key).inserted else { continue }
            result.append(word)
            if result.count == limit { break }
        }
        return result
    }

    /// Basic Latin + Latin-1 letters and apostrophes. Drops CJK/Arabic/etc.
    static func isLatinScriptWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            if scalar == "'" || scalar == "’" { return true }
            guard CharacterSet.letters.contains(scalar) else { return false }
            return scalar.value < 0x0250
                || (0x0300...0x036F).contains(scalar.value)
        }
    }

    /// Contacts/shortcuts in the swipe list: English frequency, or a longer name.
    static func allowLexiconInSwipe(_ word: String, frequency: Set<String>) -> Bool {
        guard isLatinScriptWord(word) else { return false }
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if frequency.contains(key) { return true }
        return key.count >= 4
    }

    /// Persist a keyboard-taught word. Frequency-list English is already known.
    static func shouldTeach(_ raw: String, known: [String]) -> Bool {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.count >= 2 else { return false }
        guard isLatinScriptWord(word) else { return false }
        guard !shouldSkip(word) else { return false }
        let key = word.lowercased()
        return !known.contains { $0.lowercased() == key }
    }

    /// User/lexicon/learned words first so names beat the frequency tail.
    static func prioritizedLexicon(priority: [String], frequency: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ raw: String) {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.count >= 2 || word.lowercased() == "a" || word.lowercased() == "i" else { return }
            let key = word.lowercased()
            guard key.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return }
            guard seen.insert(key).inserted else { return }
            result.append(key)
        }
        for word in priority { add(word) }
        for word in frequency { add(word) }
        for contraction in contractions.values { add(contraction) }
        return result
    }

    static func preferredCasing(_ words: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for raw in words {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            let key = word.lowercased()
            if map[key] == nil { map[key] = capitalizedIContraction(word) }
        }
        return map
    }

    static func isPunctuationSuggestion(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        return ".,?!;:".contains(character)
    }

    static func periodAttachedWord(_ suggestion: String) -> String? {
        guard suggestion.hasSuffix("."), suggestion.count > 1 else { return nil }
        let stem = String(suggestion.dropLast())
        guard stem.contains(where: \.isLetter) else { return nil }
        guard stem.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return nil }
        return stem
    }

    static func idlePunctuation(beforeInput: String) -> [String] {
        let committed = committedSpan(beforeInput: beforeInput)
        guard !committed.word.isEmpty else { return [] }
        return [".", "?", "!"]
    }

    static func prefixMatches(prefix: String, in list: [String], limit: Int) -> [String] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return [] }
        let strippedNeedle = stripApostrophes(needle)
        var result: [String] = []
        for word in list {
            let lowered = word.lowercased()
            guard lowered != needle else { continue }
            let stripped = stripApostrophes(lowered)
            if lowered.hasPrefix(needle) || stripped.hasPrefix(strippedNeedle) {
                result.append(word)
                if result.count == limit { break }
            }
        }
        return result
    }

    /// Insert a space before a swipe word when the caret follows a letter or closer.
    static func needsLeadingSpace(beforeInput: String) -> Bool {
        guard let last = beforeInput.last else { return false }
        if last.isWhitespace || last.isNewline { return false }
        return !"([{\"'“‘".contains(last)
    }

    /// Join dictation takes without glue. Leading space when the caret follows
    /// a word; trailing space so the next take still separates if the host
    /// reports an empty `documentContextBeforeInput` after bounce-back.
    static func preparedDictationInsert(
        transcript: String,
        beforeInput: String,
        trailingSpace: Bool
    ) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        var output = text
        if needsLeadingSpace(beforeInput: beforeInput) {
            output = " " + output
        }
        if trailingSpace, output.last?.isWhitespace != true {
            output += " "
        }
        return output
    }

    /// Ground-truth wipe detection at `textDidChange` time — the one callback
    /// where the host cannot misreport state. `previous`/`current` are
    /// `documentContextBeforeInput` snapshots around a host sync. A
    /// phantom-selection wipe leaves: shared prefix + (≥ `minLoss` chars
    /// silently gone) + at most a few freshly typed characters. Returns the
    /// text to reinsert and how many current tail characters to walk back
    /// over first. Empty `current` is a send/clear — never restore into it.
    /// Gradual user deletion (one char per sync) never reaches `minLoss`.
    static func wipeRestorePlan(
        previous: String,
        current: String,
        minLoss: Int = 20
    ) -> (lost: String, walkBack: Int)? {
        guard !current.isEmpty else { return nil }
        let previousChars = Array(previous)
        let currentChars = Array(current)
        var shared = 0
        while shared < previousChars.count,
              shared < currentChars.count,
              previousChars[shared] == currentChars[shared] {
            shared += 1
        }
        let lost = previousChars.count - shared
        let extra = currentChars.count - shared
        guard lost >= minLoss, extra <= 4 else { return nil }
        return (String(previousChars[shared...]), extra)
    }

    /// A reported multi-char "highlight" whose text occurs inside the recent
    /// bulk insert is the host's phantom selection of its own pending region
    /// (Messages held the last inserted chunk selected, 2026-08-26) — not a
    /// user highlight, and must never be deleted or replaced. Trimmed
    /// containment so boundary whitespace can't hide the match.
    static func isLikelyHostHighlight(selected: String, recentBulkInsert: String?) -> Bool {
        guard let recent = recentBulkInsert, !recent.isEmpty else { return false }
        let needle = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return false }
        return recent.contains(needle)
    }

    /// Word-boundary chunks (~48 chars) for bulk inserts. One big insertText
    /// can become a single pending region that a host silently replaces
    /// wholesale on the next keystroke (Messages, 2026-08-26 sentence wipe);
    /// smaller runs cap any such region at one chunk. Chunks cut only after
    /// a space, and joining them reproduces `text` exactly.
    static func bulkInsertChunks(_ text: String, targetLength: Int = 48) -> [String] {
        guard !text.isEmpty else { return [] }
        guard text.count > targetLength else { return [text] }
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= targetLength, character == " " {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Period, comma, and friends replace the automatic trailing space after a swipe.
    static func shouldEatTrailingSwipeSpace(beforeInserting text: String) -> Bool {
        if text == "\n" { return true }
        guard text.count == 1, let character = text.first else { return false }
        // A typed space must NOT eat the auto trailing space: that fired a
        // deleteBackward right after a bulk dictation insert, and hosts that
        // treat the fresh insert as one deletable clump took the whole
        // sentence with it (2026-08-25, second wipe). Double-space-period
        // handles the doubled space via doubleSpacePeriodWalk instead.
        return ".,!?;:)]}…".contains(character)
    }

    /// Non-deleting double-space-period. Returns how many trailing spaces
    /// (1 or 2) the caret must step back over before inserting "." — nil when
    /// the context doesn't end in letter/digit + 1–2 spaces. The space paths
    /// may never call `deleteBackward`: hosts can hold selections they report
    /// as empty and treat a fresh bulk insert as one deletable clump — both
    /// 2026-08-25 sentence wipes rode a delete on this path. Walking the
    /// caret and inserting cannot lose text on any host.
    static func doubleSpacePeriodWalk(beforeInput: String) -> Int? {
        var spaces = 0
        var index = beforeInput.endIndex
        while index > beforeInput.startIndex, spaces < 3 {
            let previous = beforeInput.index(before: index)
            guard beforeInput[previous] == " " else { break }
            spaces += 1
            index = previous
        }
        guard (1...2).contains(spaces), index > beforeInput.startIndex else { return nil }
        let anchor = beforeInput[beforeInput.index(before: index)]
        return (anchor.isLetter || anchor.isNumber) ? spaces : nil
    }

    /// Word immediately before trailing whitespace. Empty if the caret follows punctuation.
    static func committedSpan(beforeInput: String) -> (word: String, trailing: String) {
        var end = beforeInput.endIndex
        while end > beforeInput.startIndex {
            let previous = beforeInput.index(before: end)
            if beforeInput[previous].isWhitespace {
                end = previous
            } else {
                break
            }
        }
        let trailing = String(beforeInput[end...])
        let word = wordSpan(beforeInput: String(beforeInput[..<end]))
        return (word, trailing)
    }
}
