import Foundation

/// One `space.move` (`Workspace.moveSpace`): a space put just before another of
/// its machine's, or after the last of them (`before == nil`).
public struct SpaceMove: Equatable, Sendable {
    public var space: String
    public var before: String?

    public init(space: String, before: String?) {
        self.space = space
        self.before = before
    }

    /// The fewest moves that take one machine's spaces from order `from` to order
    /// `to`, made one after another: the longest run of spaces already in the right
    /// order stays, and from the end, each other one goes just before the one after
    /// it in `to` (the last one, last). Spaces in only one of the two are left out.
    public static func plan(from: [String], to: [String]) -> [SpaceMove] {
        let common = Set(from).intersection(to)
        let target = to.filter(common.contains)
        var place: [String: Int] = [:]
        for (i, id) in from.filter(common.contains).enumerated() { place[id] = i }
        let kept = longestIncreasing(target.map { place[$0] ?? 0 })
        var moves: [SpaceMove] = []
        for i in target.indices.reversed() where !kept.contains(i) {
            moves.append(SpaceMove(space: target[i], before: i + 1 < target.count ? target[i + 1] : nil))
        }
        return moves
    }

    /// The indices of a longest strictly increasing subsequence of `values`.
    private static func longestIncreasing(_ values: [Int]) -> Set<Int> {
        guard !values.isEmpty else { return [] }
        var length = Array(repeating: 1, count: values.count)
        var previous = Array(repeating: -1, count: values.count)
        for i in values.indices {
            for j in 0..<i where values[j] < values[i] && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                previous[i] = j
            }
        }
        var i = length.indices.max { length[$0] < length[$1] } ?? 0
        var out: Set<Int> = []
        while i >= 0 {
            out.insert(i)
            i = previous[i]
        }
        return out
    }
}
