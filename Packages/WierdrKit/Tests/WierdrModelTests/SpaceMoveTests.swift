import Foundation
import Testing
@testable import WierdrModel

/// Reordering spaces (the iPhone's strip): the fewest `space.move`s from one order
/// to another, and the demo moving spaces here.
@MainActor @Suite struct SpaceMoveTests {
    /// `space.move` on a plain list, as `LayoutEdits.moveSpace` does it.
    func apply(_ moves: [SpaceMove], to ids: [String]) -> [String] {
        var list = ids
        for m in moves {
            list.removeAll { $0 == m.space }
            list.insert(m.space, at: m.before.flatMap { list.firstIndex(of: $0) } ?? list.count)
        }
        return list
    }

    func permutations(_ a: [String]) -> [[String]] {
        guard a.count > 1 else { return [a] }
        return a.indices.flatMap { i -> [[String]] in
            var rest = a
            let x = rest.remove(at: i)
            return permutations(rest).map { [x] + $0 }
        }
    }

    @Test func oneTabDraggedIsOneMove() {
        let ids = ["a", "b", "c", "d"]
        #expect(SpaceMove.plan(from: ids, to: ids).isEmpty)
        #expect(SpaceMove.plan(from: ids, to: ["d", "a", "b", "c"]) == [SpaceMove(space: "d", before: "a")])
        #expect(SpaceMove.plan(from: ids, to: ["b", "c", "d", "a"]) == [SpaceMove(space: "a", before: nil)])
        #expect(SpaceMove.plan(from: ids, to: ["a", "c", "b", "d"]).count == 1)
    }

    @Test func everyOrderIsReachedWithTheFewestMoves() {
        let ids = ["a", "b", "c", "d", "e"]
        for to in permutations(ids) {
            let moves = SpaceMove.plan(from: ids, to: to)
            #expect(apply(moves, to: ids) == to)
            // n − the longest run already in order (here: positions increasing).
            var best = Array(repeating: 1, count: to.count)
            for i in to.indices {
                for j in 0..<i where ids.firstIndex(of: to[j])! < ids.firstIndex(of: to[i])! { best[i] = max(best[i], best[j] + 1) }
            }
            #expect(moves.count == ids.count - best.max()!)
        }
    }

    @Test func spacesInOnlyOneOrderAreLeftOut() {
        let moves = SpaceMove.plan(from: ["a", "b", "gone", "c"], to: ["c", "new", "a", "b"])
        #expect(moves == [SpaceMove(space: "c", before: "a")])
    }

    @Test func theDemoMovesSpacesHere() async throws {
        let ws = Workspace.preview()
        #expect(ws.spaces.map(\.id) == ["sp1", "sp2", "sp3", "sp4", "lf/sp5"])
        try await ws.moveSpace("sp3", before: "sp1")
        #expect(ws.spaces.map(\.id) == ["sp3", "sp1", "sp2", "sp4", "lf/sp5"])
        // Last: after its machine's last, not after another machine's.
        try await ws.moveSpace("sp3", before: nil)
        #expect(ws.spaces.map(\.id) == ["sp1", "sp2", "sp4", "sp3", "lf/sp5"])
        try await ws.moveSpace("lf/sp5", before: nil)
        #expect(ws.spaces.map(\.id) == ["sp1", "sp2", "sp4", "sp3", "lf/sp5"])
        await #expect(throws: WorkspaceError.self) { try await ws.moveSpace("sp1", before: "lf/sp5") }
        await #expect(throws: WorkspaceError.self) { try await ws.moveSpace("nope", before: nil) }
        #expect(ws.spaces.map(\.id) == ["sp1", "sp2", "sp4", "sp3", "lf/sp5"])

        let to = ["sp4", "sp3", "sp2", "sp1"]
        for m in SpaceMove.plan(from: ws.spaces(on: nil).map(\.id), to: to) {
            try await ws.moveSpace(m.space, before: m.before)
        }
        #expect(ws.spaces.map(\.id) == to + ["lf/sp5"])
    }
}
