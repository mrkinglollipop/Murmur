// Glide matcher: FlorisBoard extremity/length prune + libswipetype DTW.
//
// FlorisBoard StatisticalGlideTypingClassifier — Apache 2.0
// Copyright 2020–2026 The FlorisBoard Contributors
// https://github.com/florisboard/florisboard
// License: ios/Resources/Licenses/FlorisBoard-LICENSE.txt
// Algorithm: Étienne Desticourt / AnySoftKeyboard PR 1870.
//
// libswipetype Sakoe-Chiba DTW scorer — Apache 2.0
// Copyright 2024 libswipetype Contributors
// https://github.com/libswipetype/libswipetype
// License: ios/Resources/Licenses/libswipetype-LICENSE.txt

import CoreGraphics
import Foundation

/// Statistical glide matcher: 3-closest start/end keys, length prune,
/// Sakoe-Chiba DTW on resampled normalized paths, frequency as a multiplier.
enum SwipeTypingEngine {
    struct KeyCenter: Equatable {
        var letter: Character
        var point: CGPoint
        var frame: CGRect = .null
    }

    /// Finger travel that is a tap or a sloppy neighbor-hit, not a glide.
    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        return total
    }

    /// Two-letter neighbor hits at ~16pt were committing whole words and eating
    /// the in-progress span. Require a real glide before swipe wins over tap.
    static func isDeliberateSwipe(
        travel: CGFloat,
        uniqueLetters: Int,
        keyWidth: CGFloat
    ) -> Bool {
        let width = max(keyWidth, 8)
        guard uniqueLetters >= 2, travel > 0 else { return false }
        if uniqueLetters == 2 {
            return travel >= max(width * 2.5, 72)
        }
        return travel >= max(width * 1.55, 48)
    }

    static func consecutiveUniqueLetters(in word: String) -> [Character] {
        var result: [Character] = []
        for character in word.lowercased() where character.isLetter {
            if result.last != character {
                result.append(character)
            }
        }
        return result
    }

    static func restoreContraction(_ word: String) -> String {
        AutocorrectEngine.capitalizedIContraction(
            AutocorrectEngine.restoreContraction(word)
        )
    }

    static func nearestLetter(
        at point: CGPoint,
        keys: [KeyCenter],
        maxDistance: CGFloat
    ) -> Character? {
        let containing = keys.filter { key in
            !key.frame.isNull && key.frame.insetBy(dx: -2, dy: -2).contains(point)
        }
        if let hit = containing.min(by: {
            hypot($0.point.x - point.x, $0.point.y - point.y)
                < hypot($1.point.x - point.x, $1.point.y - point.y)
        }) {
            return hit.letter
        }
        var best: Character?
        var bestDistance = maxDistance
        for key in keys {
            let distance = hypot(key.point.x - point.x, key.point.y - point.y)
            if distance <= bestDistance {
                bestDistance = distance
                best = key.letter
            }
        }
        return best
    }

    /// Collapsed keys the finger hit or crossed, in order. Used for key glow.
    static func keySequence(
        path: [CGPoint],
        keys: [KeyCenter],
        keyWidth: CGFloat
    ) -> [Character] {
        guard !path.isEmpty, !keys.isEmpty, keyWidth > 1 else { return [] }
        var sequence: [Character] = []
        func append(_ letter: Character) {
            if sequence.last != letter {
                sequence.append(letter)
            }
        }
        let hitRadius = keyWidth * 1.65
        let passRadius = keyWidth * 0.58
        for index in 0..<path.count {
            let isEnd = index == 0 || index == path.count - 1
            let reach = isEnd ? CGFloat.greatestFiniteMagnitude : hitRadius
            if let letter = nearestLetter(at: path[index], keys: keys, maxDistance: reach) {
                append(letter)
            }
            guard index + 1 < path.count else { continue }
            let start = path[index]
            let end = path[index + 1]
            var crossings: [(CGFloat, Character)] = []
            for key in keys {
                let distance = distance(point: key.point, segmentFrom: start, to: end)
                guard distance <= passRadius else { continue }
                crossings.append((projectionT(point: key.point, segmentFrom: start, to: end), key.letter))
            }
            crossings.sort { $0.0 < $1.0 }
            for crossing in crossings {
                append(crossing.1)
            }
        }
        return sequence
    }

    /// Best matches first. Lowercase, contractions restored. Empty when unmatched.
    static func candidates(
        path: [CGPoint],
        keys: [KeyCenter],
        words: [String],
        keyWidth: CGFloat,
        limit: Int
    ) -> [String] {
        guard path.count >= 2, keys.count >= 2, keyWidth > 1, limit > 0 else { return [] }
        guard let start = path.first, let end = path.last else { return [] }
        let cache = layoutCache(keys: keys, words: words, keyWidth: keyWidth)
        let radius = cache.radius
        let startKeys = closestLetters(to: start, keys: keys, count: startExtremityCount)
        let endKeys = closestLetters(to: end, keys: keys, count: endExtremityCount)
        guard !startKeys.isEmpty, !endKeys.isEmpty else { return [] }

        var remaining: [String] = []
        remaining.reserveCapacity(64)
        var seen = Set<String>()
        for first in startKeys {
            for last in endKeys {
                guard let bucket = cache.tree[LetterPair(first: first, last: last)] else { continue }
                for word in bucket where seen.insert(word).inserted {
                    remaining.append(word)
                }
            }
        }

        let userLength = length(of: path)
        let lengthLimit = pruningLengthThreshold * radius
        remaining = remaining.filter { word in
            cache.ideals[word]?.contains { abs(userLength - $0.length) < lengthLimit } == true
        }
        guard !remaining.isEmpty else { return [] }

        let userNormalized = normalizeByBoxSide(resample(path, count: samplingPoints))
        let chord = hypot(end.x - start.x, end.y - start.y)
        let straightness = chord < 0.5 ? 2.0 : userLength / chord
        let closestStart = startKeys[0]
        let closestEnd = endKeys[0]

        struct Scored {
            var word: String
            var dtw: CGFloat
            var rank: Int
            var hitchhiker: Double
            var lengthCost: Double
        }
        var scored: [Scored] = []
        scored.reserveCapacity(min(remaining.count, 64))

        for word in remaining {
            guard let ideals = cache.ideals[word], !ideals.isEmpty else { continue }
            var best = CGFloat.greatestFiniteMagnitude
            var bestLength: CGFloat = 0
            for ideal in ideals {
                let wordNormalized = normalizeByBoxSide(resample(ideal.points, count: samplingPoints))
                let distance = dtwDistance(userNormalized, wordNormalized)
                if distance < best {
                    best = distance
                    bestLength = ideal.length
                }
            }
            guard best < .greatestFiniteMagnitude else { continue }
            let lengthDenom = max(Double(userLength), Double(radius), 1)
            scored.append(Scored(
                word: word,
                dtw: best,
                rank: cache.rank[word] ?? 5_000,
                hitchhiker: hitchhikerPenalty(
                    word: word,
                    closestStart: closestStart,
                    closestEnd: closestEnd,
                    straightness: straightness
                ),
                lengthCost: min(1, Double(abs(userLength - bestLength)) / lengthDenom)
            ))
        }

        let maxDTW = max(scored.map(\.dtw).max() ?? 1, 0.0001)
        scored.sort {
            let left = combinedCost(
                dtw: $0.dtw, maxDTW: maxDTW, rank: $0.rank,
                hitchhiker: $0.hitchhiker, lengthCost: $0.lengthCost
            )
            let right = combinedCost(
                dtw: $1.dtw, maxDTW: maxDTW, rank: $1.rank,
                hitchhiker: $1.hitchhiker, lengthCost: $1.lengthCost
            )
            if left != right { return left < right }
            return $0.word < $1.word
        }
        var unique = Set<String>()
        var result: [String] = []
        for item in scored {
            let presented = AutocorrectEngine.swipePresentation(for: item.word)
            for candidate in [presented.primary, presented.extra].compactMap({ $0 }) {
                let key = candidate.lowercased()
                guard unique.insert(key).inserted else { continue }
                result.append(candidate)
                if result.count == limit { return result }
            }
        }
        return result
    }

    static func length(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    static func downsample(_ points: [CGPoint], limit: Int) -> [CGPoint] {
        guard points.count > limit, limit > 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            points[min(points.count - 1, Int((Double(index) * step).rounded()))]
        }
    }

    static func adjacentLetters(to letter: Character) -> Set<Character> {
        let rows: [[Character]] = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
        var result: Set<Character> = [letter]
        guard let row = rows.firstIndex(where: { $0.contains(letter) }),
              let column = rows[row].firstIndex(of: letter) else { return result }
        for rowDelta in -1...1 {
            for columnDelta in -1...1 {
                let nextRow = row + rowDelta
                let nextColumn = column + columnDelta
                guard nextRow >= 0, nextRow < rows.count else { continue }
                guard nextColumn >= 0, nextColumn < rows[nextRow].count else { continue }
                result.insert(rows[nextRow][nextColumn])
            }
        }
        return result
    }

    private struct LetterPair: Hashable {
        var first: Character
        var last: Character
    }

    private struct IdealGesture {
        var points: [CGPoint]
        var length: CGFloat
    }

    private struct LayoutCache {
        var tree: [LetterPair: [String]]
        var ideals: [String: [IdealGesture]]
        var rank: [String: Int]
        var radius: CGFloat
    }

    private static let startExtremityCount = 3
    private static let endExtremityCount = 5
    private static let pruningLengthThreshold: CGFloat = 12.0
    private static let samplingPoints = 64
    private static let dtwBandwidthRatio = 0.10
    private static let frequencyWeight = 0.30

    private static var cachedSignature = 0
    private static var cachedLayout: LayoutCache?

    /// Locked unigram ranks so a learned nonce cannot beat "to" / "the".
    private static let functionWordRank: [String: Int] = {
        let words = [
            "the", "be", "to", "of", "and", "a", "in", "that", "have",
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
            "give", "day", "most", "us", "too"
        ]
        return Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
    }()

    private static func layoutCache(
        keys: [KeyCenter],
        words: [String],
        keyWidth: CGFloat
    ) -> LayoutCache {
        let signature = cacheSignature(keys: keys, words: words, keyWidth: keyWidth)
        if let cachedLayout, cachedSignature == signature {
            return cachedLayout
        }
        let lookup = Dictionary(keys.map { ($0.letter, $0) }, uniquingKeysWith: { first, _ in first })
        let radius: CGFloat = {
            if let frame = keys.first(where: { !$0.frame.isNull })?.frame {
                return min(frame.width, frame.height)
            }
            return keyWidth
        }()
        var tree: [LetterPair: [String]] = [:]
        var ideals: [String: [IdealGesture]] = [:]
        var rank: [String: Int] = [:]
        rank.reserveCapacity(min(words.count, 8_192))
        for (index, word) in words.enumerated() where rank[word] == nil {
            rank[word] = functionWordRank[word] ?? (80 + index)
            let gestures = idealGestures(for: word, lookup: lookup)
            guard let pair = letterPair(for: word, lookup: lookup), !gestures.isEmpty else { continue }
            tree[pair, default: []].append(word)
            ideals[word] = gestures
        }
        let built = LayoutCache(tree: tree, ideals: ideals, rank: rank, radius: radius)
        cachedSignature = signature
        cachedLayout = built
        return built
    }

    private static func cacheSignature(keys: [KeyCenter], words: [String], keyWidth: CGFloat) -> Int {
        var hasher = Hasher()
        hasher.combine(words.count)
        if words.count <= 64 {
            hasher.combine(words.joined(separator: "\n"))
        } else {
            hasher.combine(words.first)
            hasher.combine(words.last)
        }
        hasher.combine(keys.count)
        hasher.combine(Int((keyWidth * 10).rounded()))
        if let first = keys.first {
            hasher.combine(Int(first.point.x.rounded()))
            hasher.combine(Int(first.point.y.rounded()))
        }
        return hasher.finalize()
    }

    private static func letterPair(for word: String, lookup: [Character: KeyCenter]) -> LetterPair? {
        let letters = word.lowercased().compactMap { character -> Character? in
            character.isLetter ? character : nil
        }
        guard let first = letters.first, let last = letters.last else { return nil }
        guard lookup[first] != nil, lookup[last] != nil else { return nil }
        return LetterPair(first: first, last: last)
    }

    private static func idealGestures(
        for word: String,
        lookup: [Character: KeyCenter]
    ) -> [IdealGesture] {
        var centers: [CGPoint] = []
        var looped: [CGPoint] = []
        var previous: Character?
        var hasLoops = false
        for raw in word.lowercased() {
            guard raw.isLetter, let key = lookup[raw] else { continue }
            let center = key.point
            if previous == raw {
                hasLoops = true
                let dx = (key.frame.isNull ? 8 : key.frame.width) / 4
                let dy = (key.frame.isNull ? 10 : key.frame.height) / 4
                looped.append(CGPoint(x: center.x + dx, y: center.y + dy))
                looped.append(CGPoint(x: center.x + dx, y: center.y - dy))
                looped.append(CGPoint(x: center.x - dx, y: center.y - dy))
                looped.append(CGPoint(x: center.x - dx, y: center.y + dy))
                centers.append(center)
            } else {
                centers.append(center)
                looped.append(center)
            }
            previous = raw
        }
        guard centers.count >= 2 else { return [] }
        var result = [IdealGesture(points: centers, length: length(of: centers))]
        if hasLoops {
            result.append(IdealGesture(points: looped, length: length(of: looped)))
        }
        return result
    }

    private static func closestLetters(to point: CGPoint, keys: [KeyCenter], count: Int) -> [Character] {
        let ranked = keys
            .map { (letter: $0.letter, distance: hypot($0.point.x - point.x, $0.point.y - point.y)) }
            .sorted {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                return $0.letter < $1.letter
            }
        var letters: [Character] = []
        var seen = Set<Character>()
        for item in ranked {
            guard seen.insert(item.letter).inserted else { continue }
            letters.append(item.letter)
            if letters.count == count { break }
        }
        return letters
    }

    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard count > 0, let first = points.first else { return [] }
        if points.count == 1 || count == 1 {
            return Array(repeating: first, count: count)
        }
        let total = length(of: points)
        if total < 0.0001 {
            return Array(repeating: first, count: count)
        }
        return (0..<count).map { index in
            let target = CGFloat(index) / CGFloat(count - 1) * total
            return point(along: points, at: target)
        }
    }

    private static func point(along points: [CGPoint], at distance: CGFloat) -> CGPoint {
        guard let first = points.first else { return .zero }
        if distance <= 0 { return first }
        var walked: CGFloat = 0
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let segment = hypot(end.x - start.x, end.y - start.y)
            if walked + segment >= distance || index == points.count - 2 {
                if segment < 0.0001 { return end }
                let t = min(1, max(0, (distance - walked) / segment))
                return CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                )
            }
            walked += segment
        }
        return points.last ?? first
    }

    private static func normalizeByBoxSide(_ points: [CGPoint]) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let width = maxX - minX
        let height = maxY - minY
        let longest = max(max(width, height), 0.00001)
        let centroidX = (width / 2 + minX) / longest
        let centroidY = (height / 2 + minY) / longest
        return points.map {
            CGPoint(x: $0.x / longest - centroidX, y: $0.y / longest - centroidY)
        }
    }

    /// Lower is better. Shape is 70% of the cost; frequency only breaks close races.
    private static func combinedCost(
        dtw: CGFloat,
        maxDTW: CGFloat,
        rank: Int,
        hitchhiker: Double,
        lengthCost: Double
    ) -> Double {
        let normalizedDTW = min(1, Double(dtw / maxDTW))
        let frequency = 1.0 / (1.0 + Double(rank) / 80.0)
        return (1.0 - frequencyWeight) * normalizedDTW
            + frequencyWeight * (1.0 - frequency)
            + hitchhiker
            + 0.28 * lengthCost
    }

    /// Straight T→O crosses I. "tio" matches that path; "to" is the word.
    /// Function words with extra letters (`our` vs `or`) skip this — frequency
    /// already ranks them, and the penalty was hiding `our` behind `it`/`of`.
    private static func hitchhikerPenalty(
        word: String,
        closestStart: Character,
        closestEnd: Character,
        straightness: CGFloat
    ) -> Double {
        let letters = consecutiveUniqueLetters(in: word)
        guard letters.count >= 2 else { return 0 }
        var penalty = 0.0
        if letters[0] != closestStart {
            penalty += 0.45
        }
        if letters.count == 2, letters[0] == closestStart, letters[1] == closestEnd {
            return penalty
        }
        guard straightness < 1.28 else { return penalty }
        if functionWordRank[word] != nil { return penalty }
        return penalty + 0.55 * Double(letters.count - 2)
    }

    /// Sakoe-Chiba DTW, two-row, normalized by path length. Port of libswipetype Scorer.cpp.
    private static func dtwDistance(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
        let count = min(a.count, b.count)
        guard count > 0 else { return .greatestFiniteMagnitude }
        let band = max(1, Int(ceil(dtwBandwidthRatio * Double(count))))
        var previous = [CGFloat](repeating: .greatestFiniteMagnitude, count: count)
        var current = [CGFloat](repeating: .greatestFiniteMagnitude, count: count)
        previous[0] = hypot(a[0].x - b[0].x, a[0].y - b[0].y)
        let firstRow = min(band, count - 1)
        if firstRow >= 1 {
            for index in 1...firstRow {
                if previous[index - 1] < .greatestFiniteMagnitude {
                    previous[index] = previous[index - 1]
                        + hypot(a[0].x - b[index].x, a[0].y - b[index].y)
                }
            }
        }
        guard count > 1 else { return previous[0] }
        for row in 1..<count {
            for index in 0..<count { current[index] = .greatestFiniteMagnitude }
            let start = max(0, row - band)
            let end = min(count - 1, row + band)
            for column in start...end {
                let cost = hypot(a[row].x - b[column].x, a[row].y - b[column].y)
                var best = previous[column]
                if column > 0 {
                    best = min(best, current[column - 1])
                    best = min(best, previous[column - 1])
                }
                if best < .greatestFiniteMagnitude {
                    current[column] = cost + best
                }
            }
            swap(&previous, &current)
        }
        let raw = previous[count - 1]
        guard raw < .greatestFiniteMagnitude else { return .greatestFiniteMagnitude }
        return raw / CGFloat(count)
    }

    private static func distance(point: CGPoint, segmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let abx = end.x - start.x
        let aby = end.y - start.y
        let apx = point.x - start.x
        let apy = point.y - start.y
        let ab2 = abx * abx + aby * aby
        if ab2 < 0.0001 {
            return hypot(apx, apy)
        }
        let t = max(0, min(1, (apx * abx + apy * aby) / ab2))
        return hypot(point.x - (start.x + t * abx), point.y - (start.y + t * aby))
    }

    private static func projectionT(point: CGPoint, segmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let abx = end.x - start.x
        let aby = end.y - start.y
        let ab2 = abx * abx + aby * aby
        if ab2 < 0.0001 { return 0 }
        return max(0, min(1, ((point.x - start.x) * abx + (point.y - start.y) * aby) / ab2))
    }
}
