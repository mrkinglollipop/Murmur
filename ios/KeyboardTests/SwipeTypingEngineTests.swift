import XCTest

final class SwipeTypingEngineTests: XCTestCase {
    func testSloppyNeighborHitsAreNotDeliberateSwipes() {
        let width: CGFloat = 30
        XCTAssertFalse(
            SwipeTypingEngine.isDeliberateSwipe(travel: 16, uniqueLetters: 2, keyWidth: width)
        )
        XCTAssertFalse(
            SwipeTypingEngine.isDeliberateSwipe(travel: 40, uniqueLetters: 3, keyWidth: width)
        )
        XCTAssertTrue(
            SwipeTypingEngine.isDeliberateSwipe(travel: 50, uniqueLetters: 3, keyWidth: width)
        )
        XCTAssertFalse(
            SwipeTypingEngine.isDeliberateSwipe(travel: 70, uniqueLetters: 2, keyWidth: width)
        )
        XCTAssertTrue(
            SwipeTypingEngine.isDeliberateSwipe(travel: 80, uniqueLetters: 2, keyWidth: width)
        )
        XCTAssertEqual(
            SwipeTypingEngine.pathLength([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 30, y: 40)]),
            70,
            accuracy: 0.01
        )
    }

    func testConsecutiveUniqueCollapsesDoubleLetters() {
        XCTAssertEqual(
            SwipeTypingEngine.consecutiveUniqueLetters(in: "hello"),
            ["h", "e", "l", "o"]
        )
        XCTAssertEqual(
            SwipeTypingEngine.consecutiveUniqueLetters(in: "book"),
            ["b", "o", "k"]
        )
    }

    func testHelloPathPrefersHello() {
        let path = QWERTYFixture.path(through: "hello")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: [
                "the", "and", "to", "of", "hello", "help", "hell", "hero",
                "yellow", "world", "ho", "helo", "hallo", "who", "how"
            ],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "hello")
        XCTAssertTrue(ranked.count <= 3)
        XCTAssertNotEqual(ranked.first, "help")
        XCTAssertFalse(ranked.contains("the"))
    }

    func testThePathPrefersTheOverToe() {
        let path = QWERTYFixture.path(through: "the")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: ["the", "toe", "to", "he", "them", "then"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "the")
    }

    func testShortPathReturnsEmpty() {
        let h = QWERTYFixture.keys.first { $0.letter == "h" }!.point
        let ranked = SwipeTypingEngine.candidates(
            path: [h],
            keys: QWERTYFixture.keys,
            words: ["hello", "hi", "the"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertTrue(ranked.isEmpty)
    }

    func testAndPathPrefersAnd() {
        let path = QWERTYFixture.path(through: "and")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: ["and", "add", "an", "any", "aid"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "and")
    }

    func testDontPathRestoresContraction() {
        XCTAssertEqual(SwipeTypingEngine.restoreContraction("dont"), "don't")
        let path = QWERTYFixture.path(through: "dont")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: ["dont", "don", "dint", "to"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "don't")
    }

    func testNoisyHelloPathStillPrefersHello() {
        let path = QWERTYFixture.jitteredPath(through: "hello")
        let sequence = SwipeTypingEngine.keySequence(
            path: path,
            keys: QWERTYFixture.keys,
            keyWidth: QWERTYFixture.keyWidth
        )
        XCTAssertTrue(sequence.contains("h"))
        XCTAssertTrue(sequence.contains("e"))
        XCTAssertTrue(sequence.contains("l"))
        XCTAssertTrue(sequence.contains("o"))
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: [
                "the", "be", "to", "of", "and", "a", "in", "that", "have",
                "hello", "help", "hell", "hero", "ho", "helo", "yellow", "go"
            ],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "hello")
    }

    func testOvershootingLastKeyStillPrefersHello() {
        let path = QWERTYFixture.overshootPath(through: "hello")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: ["the", "to", "and", "hello", "help", "hell", "ho", "go"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "hello")
    }

    func testTimeWarpedHelloPathStillPrefersHello() {
        let path = QWERTYFixture.timeWarpedPath(through: "hello")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: [
                "the", "be", "to", "of", "and", "hello", "help", "hell",
                "hero", "ho", "helo", "yellow", "go"
            ],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "hello")
        XCTAssertFalse(ranked.contains("the"))
    }

    func testStraightToPathPrefersToOverTio() {
        let path = QWERTYFixture.path(through: "to")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: ["tio", "to", "too", "two", "go", "no"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "to")
        XCTAssertNotEqual(ranked.first, "tio")
    }

    func testBentTwoPathStillPrefersTwo() {
        let path = QWERTYFixture.path(through: "two")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: ["to", "too", "two", "tio", "who"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "two")
    }

    func testMatthewPathPrefersMatthewOverMake() {
        let path = QWERTYFixture.path(through: "matthew")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: ["make", "made", "math", "mate", "me", "matthew", "matt"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "matthew")
    }

    func testIllPathRestoresIllContraction() {
        let path = QWERTYFixture.path(through: "ill")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: ["ill", "i'll", "all", "ilk"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "I'll")
    }

    func testHellPathKeepsHellAndSuggestsContraction() {
        let path = QWERTYFixture.path(through: "hell")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: ["hell", "he'll", "hello", "help", "he"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "hell")
        XCTAssertTrue(ranked.contains("he'll"))
    }

    func testItsPathKeepsItsAndSuggestsItsContraction() {
        let path = QWERTYFixture.path(through: "its")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: ["its", "it's", "it", "is", "sit"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "its")
        XCTAssertTrue(ranked.contains("it's"))
    }

    func testFrequentWordsWinTheirOwnIdealPath() {
        let words = [
            "the", "be", "to", "of", "and", "in", "that", "have",
            "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
            "this", "but", "his", "by", "from", "they", "we", "say", "her",
            "she", "or", "an", "will", "my", "one", "all", "would", "there",
            "their", "what", "so", "up", "out", "if", "about", "who", "get",
            "which", "go", "me", "when", "make", "can", "like", "time", "no",
            "just", "him", "know", "take", "people", "into", "year", "your",
            "good", "some", "could", "them", "see", "other", "than", "then",
            "now", "look", "only", "come", "its", "over", "think", "also",
            "back", "after", "use", "two", "how", "our", "work", "first",
            "well", "way", "even", "new", "want", "because", "any", "these",
            "give", "day", "most", "us", "too",
            "hello", "help", "hell", "thanks", "please", "going", "should",
            "matthew"
        ]
        var failures: [String] = []
        for word in words {
            let letters = SwipeTypingEngine.consecutiveUniqueLetters(in: word)
            guard letters.count >= 2 else { continue }
            let ranked = SwipeTypingEngine.candidates(
                path: QWERTYFixture.path(through: word),
                keys: QWERTYFixture.keys,
                words: words,
                keyWidth: QWERTYFixture.keyWidth,
                limit: 3
            )
            if ranked.first != word {
                let got = ranked.first ?? ""
                let gotLetters = SwipeTypingEngine.consecutiveUniqueLetters(in: got)
                let sameSkeleton = gotLetters == letters
                if sameSkeleton, ranked.contains(word) { continue }
                // Colinear row: `our` vs `or`. Shorter word commits; longer stays in the bar.
                if ranked.contains(word),
                   gotLetters.count + 1 == letters.count,
                   gotLetters.first == letters.first,
                   gotLetters.last == letters.last {
                    continue
                }
                failures.append("\(word) → \(got) \(ranked)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testHelloPathDoesNotPreferBack() {
        let path = QWERTYFixture.path(through: "hello")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: [
                "back", "be", "he", "hell", "he'll", "help", "hello",
                "the", "to", "go", "me"
            ],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "hello")
        XCTAssertFalse(ranked.contains("back"))
    }

    func testHesPathRestoresHesContraction() {
        let path = QWERTYFixture.path(through: "hes")
        let ranked = SwipeTypingEngine.candidates(
            path: path,
            keys: QWERTYFixture.keys,
            words: ["hes", "he's", "his", "has"],
            keyWidth: QWERTYFixture.keyWidth,
            limit: 3
        )
        XCTAssertEqual(ranked.first, "he's")
    }
}

private enum QWERTYFixture {
    static let keyWidth: CGFloat = 30
    static let keyHeight: CGFloat = 40

    static var keys: [SwipeTypingEngine.KeyCenter] {
        let rows = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
        let offsets: [CGFloat] = [0, 15, 45]
        var result: [SwipeTypingEngine.KeyCenter] = []
        for (row, chars) in rows.enumerated() {
            for (index, character) in chars.enumerated() {
                let x = offsets[row] + CGFloat(index) * keyWidth + keyWidth / 2
                let y = CGFloat(row) * keyHeight + keyHeight / 2
                let frame = CGRect(
                    x: x - keyWidth / 2,
                    y: y - keyHeight / 2,
                    width: keyWidth,
                    height: keyHeight
                )
                result.append(.init(letter: character, point: CGPoint(x: x, y: y), frame: frame))
            }
        }
        return result
    }

    static func path(through word: String, samplesPerSegment: Int = 8) -> [CGPoint] {
        let lookup = Dictionary(uniqueKeysWithValues: keys.map { ($0.letter, $0.point) })
        let letters = SwipeTypingEngine.consecutiveUniqueLetters(in: word)
        guard let first = letters.first, var current = lookup[first] else { return [] }
        var points = [current]
        for letter in letters.dropFirst() {
            guard let next = lookup[letter] else { continue }
            for sample in 1...samplesPerSegment {
                let t = CGFloat(sample) / CGFloat(samplesPerSegment)
                points.append(CGPoint(
                    x: current.x + (next.x - current.x) * t,
                    y: current.y + (next.y - current.y) * t
                ))
            }
            current = next
        }
        return points
    }

    static func jitteredPath(through word: String) -> [CGPoint] {
        let clean = path(through: word, samplesPerSegment: 10)
        guard clean.count >= 3 else { return clean }
        return clean.enumerated().map { index, point in
            guard index > 0, index < clean.count - 1 else { return point }
            let previous = clean[index - 1]
            let next = clean[index + 1]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = hypot(dx, dy)
            guard length > 1 else { return point }
            let magnitude: CGFloat = index.isMultiple(of: 2) ? 11 : -9
            return CGPoint(
                x: point.x + (-dy / length) * magnitude,
                y: point.y + (dx / length) * magnitude
            )
        }
    }

    static func overshootPath(through word: String) -> [CGPoint] {
        var points = path(through: word)
        guard let last = word.lowercased().filter(\.isLetter).last,
              let extra = SwipeTypingEngine.adjacentLetters(to: last)
                .subtracting([last])
                .sorted()
                .first,
              let from = points.last,
              let to = keys.first(where: { $0.letter == extra })?.point
        else { return points }
        for sample in 1...5 {
            let t = CGFloat(sample) / 5
            points.append(CGPoint(
                x: from.x + (to.x - from.x) * t,
                y: from.y + (to.y - from.y) * t
            ))
        }
        return points
    }

    /// Dense on the first half, sparse on the last — the case pointwise
    /// correspondence loses and DTW is supposed to win.
    static func timeWarpedPath(through word: String) -> [CGPoint] {
        let lookup = Dictionary(uniqueKeysWithValues: keys.map { ($0.letter, $0.point) })
        let letters = SwipeTypingEngine.consecutiveUniqueLetters(in: word)
        guard let first = letters.first, var current = lookup[first] else { return [] }
        var points = [current]
        let lastIndex = letters.count - 1
        for (offset, letter) in letters.dropFirst().enumerated() {
            guard let next = lookup[letter] else { continue }
            let samples = offset + 1 == lastIndex ? 3 : 24
            for sample in 1...samples {
                let t = CGFloat(sample) / CGFloat(samples)
                points.append(CGPoint(
                    x: current.x + (next.x - current.x) * t,
                    y: current.y + (next.y - current.y) * t
                ))
            }
            current = next
        }
        return points
    }
}
