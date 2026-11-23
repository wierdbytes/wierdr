import Foundation

/// fzf-style fuzzy matching (the agents panel's search): the query's letters in order in
/// the text, not necessarily together. Of the ways they fit, the best scoring:
/// each letter scores, more at the start of a word (after a space, then after
/// `/-_.:` and the like, then at a camelCase hump or a digit) and the first
/// letter twice that; letters that follow one another keep the bonus of their
/// run's start (at least 4); a gap costs 3, and 1 for each more letter it skips.
/// Case and diacritics don't matter (ё is е). Words of the query (split by
/// spaces) must each match, in any order; their scores add up.
public enum Fuzzy {
    public struct Match: Hashable, Sendable {
        public var score: Int
        /// The matched characters' offsets in the text (`Character`s), ascending.
        public var indices: [Int]

        public init(score: Int, indices: [Int]) { self.score = score; self.indices = indices }
    }

    /// The best match of `query` in `text`, nil when some word of the query isn't in it.
    /// An empty query matches everything with no score.
    public static func match(_ query: String, in text: String) -> Match? {
        let words = query.split(whereSeparator: \.isWhitespace).map { $0.map(fold) }
        guard !words.isEmpty else { return Match(score: 0, indices: []) }
        let chars = Array(text)
        let folded = chars.map(fold)
        let bonus = bonuses(chars)
        var score = 0
        var indices = Set<Int>()
        for word in words {
            guard let m = best(word, in: folded, bonus: bonus) else { return nil }
            score += m.score
            indices.formUnion(m.indices)
        }
        return Match(score: score, indices: indices.sorted())
    }

    // MARK: Scores (fzf's)

    static let scoreMatch = 16
    static let gapStart = 3
    static let gapExtension = 1
    static let bonusWhite = 10
    static let bonusDelimiter = 9
    static let bonusNonWord = 8
    static let bonusCamel = 7
    static let bonusConsecutive = 4
    static let firstCharMultiplier = 2

    private static let delimiters: Set<Character> = ["/", "\\", "-", "_", ".", ":", ",", ";", "|", "@", "#"]

    /// Each character's bonus as a word's start.
    static func bonuses(_ chars: [Character]) -> [Int] {
        chars.indices.map { j in
            let c = chars[j]
            guard c.isLetter || c.isNumber else { return 0 }
            guard j > 0 else { return bonusWhite }
            let p = chars[j - 1]
            if p.isWhitespace { return bonusWhite }
            if delimiters.contains(p) { return bonusDelimiter }
            if !(p.isLetter || p.isNumber) { return bonusNonWord }
            if p.isLowercase && c.isUppercase { return bonusCamel }
            if !p.isNumber && c.isNumber { return bonusCamel }
            return 0
        }
    }

    /// One character for comparing: lowercased, without diacritics.
    static func fold(_ c: Character) -> Character {
        if let a = c.asciiValue {
            return (65...90).contains(a) ? Character(UnicodeScalar(a + 32)) : c
        }
        let s = String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return s.count == 1 ? s.first! : c
    }

    /// The best alignment of one word: `m[i][j]` the best score with the word's
    /// letter `i` at `j`; from the previous letter right before it (a run, its
    /// start's bonus kept) or after a gap (the best of the earlier places, the
    /// gap's cost growing with each step).
    private static func best(_ word: [Character], in text: [Character], bonus: [Int]) -> Match? {
        let m = word.count, n = text.count
        guard m > 0, m <= n, isSubsequence(word, of: text) else { return nil }
        let none = Int.min / 4
        var score = Array(repeating: Array(repeating: none, count: n), count: m)
        // The bonus of the run each placement ends (a run keeps its start's).
        var runBonus = Array(repeating: Array(repeating: 0, count: n), count: m)
        // Where the previous letter is (-1: none).
        var from = Array(repeating: Array(repeating: -1, count: n), count: m)
        for j in 0..<n where text[j] == word[0] {
            score[0][j] = scoreMatch + bonus[j] * firstCharMultiplier
            runBonus[0][j] = bonus[j]
        }
        for i in 1..<m {
            // The best previous placement k ≤ j - 2 with its gap's cost to j.
            var gapBest = none, gapFrom = -1
            for j in 1..<n {
                if gapBest > none { gapBest -= gapExtension }
                if j >= 2, score[i - 1][j - 2] > none {
                    let c = score[i - 1][j - 2] - gapStart
                    if c > gapBest { gapBest = c; gapFrom = j - 2 }
                }
                guard text[j] == word[i] else { continue }
                var best = none, bestFrom = -1, bestRun = 0
                if gapBest > none {
                    best = gapBest + scoreMatch + bonus[j]
                    bestFrom = gapFrom
                    bestRun = bonus[j]
                }
                let prev = score[i - 1][j - 1]
                if prev > none {
                    let run = runBonus[i - 1][j - 1]
                    let c = prev + scoreMatch + max(run, bonusConsecutive, bonus[j])
                    if c >= best { best = c; bestFrom = j - 1; bestRun = max(run, bonus[j]) }
                }
                score[i][j] = best
                from[i][j] = bestFrom
                runBonus[i][j] = bestRun
            }
        }
        // The best end (the earliest of equals), then back through `from`.
        var end = -1
        for j in 0..<n where score[m - 1][j] > none && (end < 0 || score[m - 1][j] > score[m - 1][end]) { end = j }
        guard end >= 0 else { return nil }
        var indices = Array(repeating: 0, count: m)
        var j = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            indices[i] = j
            j = from[i][j]
        }
        return Match(score: score[m - 1][end], indices: indices)
    }

    private static func isSubsequence(_ word: [Character], of text: [Character]) -> Bool {
        var i = 0
        for c in text where i < word.count && c == word[i] { i += 1 }
        return i == word.count
    }
}
