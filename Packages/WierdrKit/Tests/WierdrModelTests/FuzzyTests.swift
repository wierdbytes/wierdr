import Testing
@testable import WierdrModel

/// The Go to panel's matching: letters in order, the best fit scored as fzf does.
@Suite struct FuzzyTests {
    func score(_ q: String, _ t: String) -> Int? { Fuzzy.match(q, in: t)?.score }

    @Test func lettersInOrder() {
        #expect(Fuzzy.match("gt", in: "Go to")?.indices == [0, 3])
        #expect(Fuzzy.match("wdr", in: "wierdr")?.indices == [0, 4, 5])
        #expect(Fuzzy.match("rw", in: "wierdr") == nil)
        #expect(Fuzzy.match("xyz", in: "wierdr") == nil)
        #expect(Fuzzy.match("wierdrr", in: "wierdr") == nil)
    }

    @Test func emptyQueryMatchesAll() {
        #expect(Fuzzy.match("", in: "anything") == Fuzzy.Match(score: 0, indices: []))
        #expect(Fuzzy.match("   ", in: "") == Fuzzy.Match(score: 0, indices: []))
        #expect(Fuzzy.match("a", in: "") == nil)
    }

    @Test func caseAndDiacriticsDontMatter() {
        #expect(Fuzzy.match("WIER", in: "wierdr") != nil)
        #expect(Fuzzy.match("доработ", in: "Панель Go to: Доработка поиска")?.indices.first == 14)
        #expect(Fuzzy.match("елка", in: "Ёлка") != nil)
        #expect(Fuzzy.match("cafe", in: "Café") != nil)
    }

    @Test func wordsMatchInAnyOrder() {
        let m = Fuzzy.match("go panel", in: "Panel Go to")
        #expect(m?.indices == [0, 1, 2, 3, 4, 6, 7])
        #expect(Fuzzy.match("go zebra", in: "Panel Go to") == nil)
    }

    /// Runs and word starts win over the first scattered fit.
    @Test func bestFitWins() {
        #expect(Fuzzy.match("abc", in: "a_b_c abc")?.indices == [6, 7, 8])
        #expect(Fuzzy.match("pb", in: "app pushbtn")?.indices == [4, 8])
        #expect(Fuzzy.match("gt", in: "git log; Go to")?.indices == [9, 12])
    }

    @Test func ranking() throws {
        // A word's start beats its middle.
        #expect(try #require(score("wi", "wierdr")) > score("wi", "rewire")!)
        // Together beats apart.
        #expect(try #require(score("dev", "dev tools")) > score("dev", "d-e-v")!)
        // A camelCase hump counts as a word's start.
        #expect(try #require(score("gt", "goTo")) > score("gt", "gato")!)
        // The whole word beats its scattered letters.
        #expect(try #require(score("push", "pushbtn")) > score("push", "p-u-s-h")!)
    }
}
