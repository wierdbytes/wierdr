import Foundation
import HerdrCore
import Testing
@testable import WierdrModel

@Suite struct ParseTests {
    @Test func localAndRemoteAreQualified() {
        let local = LayoutParser.spaces(Fixture.json(Fixture.local), machine: nil)
        #expect(local.map(\.id) == ["spe3e2159554ee24c732bb21789555be18", "sp4efbad83f656de99e594082ebf2455de"])
        #expect(local[1].tabs.map(\.name) == ["", "git"])
        #expect(local[1].tabs[1].displayName == "git" && local[1].tabs[0].displayName == "1")
        #expect(local[1].tabs[0].panes == [Pane(id: "p4f77cdf632005f8b05cd79c635a7e819", terminal: "t1w", mod: nil)])
        #expect(local[1].tabs[1].root.kind == .row([PaneNode(id: "p8f00aa9f7531dd27e8244961456069c2", kind: .terminal("t41"), weight: 4)]))

        let remote = LayoutParser.spaces(Fixture.json(Fixture.remote), machine: "lf")
        #expect(remote[0].id == "lf/sp6bc8f7a059117d7f59c9102b833bdb0d")
        #expect(remote[0].machine == "lf" && remote[0].folder == "")
        #expect(remote[0].tabs[0].id == "lf/tb655f6f387d7c23704d8fb56a6de5168e")
        #expect(remote[0].tabs[0].spaceID == remote[0].id)
        #expect(remote[0].tabs[0].root.id == remote[0].tabs[0].id)
        #expect(remote[0].tabs[0].panes == [Pane(id: "lf/pb85dd291deefc9c91d2e09e614ac4af4", terminal: "lf/t1", mod: nil)])
    }

    @Test func splitTreeAndModPanes() {
        let spaces = LayoutParser.spaces(Fixture.json(Fixture.split), machine: nil)
        let root = spaces[0].tabs[0].root
        guard case .row(let kids) = root.kind else { Issue.record("not a row"); return }
        #expect(kids.count == 2 && kids[0].weight == 0.5)
        guard case .column(let col) = kids[1].kind else { Issue.record("not a column"); return }
        #expect(col.map(\.kind) == [.terminal("t2"), .mod("markdown")])
        #expect(spaces[0].tabs[0].panes.map(\.id) == ["pX", "pY", "pZ"])
    }

    @Test func ids() {
        #expect(LayoutID.qualify("sp1", "lf") == "lf/sp1" && LayoutID.qualify("sp1", nil) == "sp1")
        #expect(LayoutID.local("lf/t1", "lf") == "t1" && LayoutID.local("t1", "lf") == "t1")
        #expect(LayoutID.machine(of: "lf/t1") == "lf" && LayoutID.machine(of: "t1") == nil)
        let id = LayoutID.fresh("sp")
        #expect(id.count == 34 && id.hasPrefix("sp") && id.dropFirst(2).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}

@Suite struct ValidatorTests {
    @Test func acceptsRealDocuments() throws {
        for s in [Fixture.local, Fixture.remote, Fixture.split] {
            try LayoutValidator.decode(Fixture.json(s))
            #expect(LayoutValidator.violations(Fixture.json(s)).isEmpty)
        }
        try LayoutValidator.decode(.null)
        try LayoutValidator.decode(Fixture.json("{}"))
    }

    @Test(arguments: [
        #"{"spaces":[{"id":"sp","name":null,"tabs":[]}]}"#,          // null where a string goes
        #"{"spaces":{"id":"sp"}}"#,                                      // spaces not an array
        #"[1,2]"#,                                                       // not an object
        #"{"spaces":[{"id":"sp","tabs":[{"id":"tb","root":{"id":"tb","children":[]}}]}]}"#,  // no type
        #"{"spaces":[{"id":"sp","tabs":[{"id":"tb","root":{"id":"tb","type":"grid","children":[]}}]}]}"#,
        #"{"spaces":[{"id":"sp","tabs":[{"id":"tb","root":{"id":"tb","type":"row","children":[{"id":"p","type":"block","content":{"file":"x"}}]}}]}]}"#,
        #"{"spaces":[{"id":"sp","tabs":[{"id":"tb","root":{"id":"tb","type":"row","children":[{"id":"p","type":"block"}]}}]}]}"#,
        #"{"spaces":[{"id":"sp","tabs":[{"id":"tb","root":{"id":"tb","type":"row","children":[{"id":"p","type":"block","size":{"flex":1},"content":{"terminal":"t1"}}]}}]}]}"#,
        #"{"spaces":[{"id":"sp","tabs":[{"id":"tb","root":{"id":"tb","type":"row","children":[{"id":"p","type":"block","size":{"weight":"1"},"content":{"terminal":"t1"}}]}}]}]}"#,
        #"{"spaces":[{"id":"sp","tabs":[{"id":"tb","root":{"id":"tb","type":"row","children":[{"id":"p","type":"block","hidden":null,"content":{"terminal":"t1"}}]}}]}]}"#,
        #"{"spaces":[{"id":"sp","tabs":[{"id":5}]}]}"#,
    ])
    func rejectsWhatTheDesktopCannotDecode(_ text: String) {
        #expect(throws: LayoutDocError.self) { try LayoutValidator.decode(Fixture.json(text)) }
    }

    @Test func writeGate() throws {
        let base = Fixture.json(Fixture.split)
        // Never null, never a broken invariant we introduce.
        #expect(throws: LayoutDocError.self) { try LayoutValidator.checkWrite(.null, base: base) }
        var dup = base
        dup["spaces"] = .array(base.layoutSpaces + [base.layoutSpaces[1]])
        #expect(throws: LayoutDocError.self) { try LayoutValidator.checkWrite(dup, base: base) }
        var twice = LayoutEdits.newSpace(base, id: "spN", name: "", folder: "", tabID: "tbN", paneID: "pNew", address: "t9")!
        twice = Fixture.json(twice.jsonString().replacingOccurrences(of: #""terminal":"t9""#, with: #""terminal":"t1""#))
        #expect(throws: LayoutDocError.self) { try LayoutValidator.checkWrite(twice, base: base) }
        let emptyTab = Fixture.json(base.jsonString().replacingOccurrences(of: #"{"id":"pW","type":"block","content":{"terminal":"t3"}}"#, with: ""))
        #expect(throws: LayoutDocError.self) { try LayoutValidator.checkWrite(emptyTab, base: base) }
        let qualified = Fixture.json(base.jsonString().replacingOccurrences(of: #""terminal":"t4""#, with: #""terminal":"lf/t4""#))
        #expect(throws: LayoutDocError.self) { try LayoutValidator.checkWrite(qualified, base: base) }
        // A violation the document already had does not block an unrelated edit.
        let old = Fixture.json(#"{"spaces":[{"id":"sp","name":"","folder":"","tabs":[{"id":"tb","name":"","root":{"id":"tb","type":"row","children":[{"id":"c","type":"column","children":[{"id":"p","type":"block","content":{"terminal":"t1"}}]}]}}]}]}"#)
        try LayoutValidator.checkWrite(LayoutEdits.renameSpace(old, id: "sp", name: "x")!, base: old)
    }
}

@Suite struct EditTests {
    let doc = Fixture.json(Fixture.split)

    @Test func newSpaceAppendsAndKeepsEverythingElse() throws {
        let out = try #require(LayoutEdits.newSpace(doc, id: "spN", name: "New", folder: "/w", tabID: "tbN", paneID: "pN", address: "t9"))
        let expected = Fixture.json(#"{"id":"spN","name":"New","folder":"/w","tabs":[{"id":"tbN","name":"","root":{"id":"tbN","type":"row","children":[{"id":"pN","type":"block","content":{"terminal":"t9"}}]}}]}"#)
        #expect(out.layoutSpaces.count == 3 && out.layoutSpaces[2] == expected)
        #expect(Array(out.layoutSpaces.prefix(2)) == doc.layoutSpaces)
        try LayoutValidator.checkWrite(out, base: doc)
        // Into an empty (never written) document.
        let fresh = try #require(LayoutEdits.newSpace(.null, id: "spN", name: "", folder: "", tabID: "tbN", paneID: "pN", address: "t9"))
        #expect(fresh.layoutSpaces.count == 1)
        // After a given space.
        let after = try #require(LayoutEdits.newSpace(doc, id: "spN", name: "", folder: "", tabID: "tbN", paneID: "pN", address: "t9", after: "spA"))
        #expect(after.layoutSpaces.map(\.nodeID) == ["spA", "spN", "spB"])
        // First.
        let first = try #require(LayoutEdits.newSpace(doc, id: "spN", name: "", folder: "", tabID: "tbN", paneID: "pN", address: "t9", first: true))
        #expect(first.layoutSpaces.map(\.nodeID) == ["spN", "spA", "spB"])
        try LayoutValidator.checkWrite(first, base: doc)
    }

    @Test func newSpaceAlreadyAdoptedOnlySetsTheName() throws {
        // The desktop adopted t4 into spB (unnamed): only our name is left to apply.
        let out = try #require(LayoutEdits.newSpace(doc, id: "spB", name: "Mine", folder: "", tabID: "tbC", paneID: "pQ", address: "t4"))
        #expect(out.layoutSpaces[1]["name"] == "Mine")
        #expect(out.layoutSpaces.count == 2)
        #expect(LayoutEdits.newSpace(doc, id: "spB", name: "", folder: "", tabID: "tbC", paneID: "pQ", address: "t4") == nil)
        // Wanted first: moved there too; a terminal shown in another space than ours: left alone.
        let first = try #require(LayoutEdits.newSpace(doc, id: "spB", name: "", folder: "", tabID: "tbC", paneID: "pQ", address: "t4", first: true))
        #expect(first.layoutSpaces.map(\.nodeID) == ["spB", "spA"])
        try LayoutValidator.checkWrite(first, base: doc)
        #expect(LayoutEdits.newSpace(doc, id: "spA", name: "", folder: "", tabID: "tbC", paneID: "pQ", address: "t4", first: true) == nil)
    }

    @Test func newTabAfterAndAtEnd() throws {
        let after = try #require(LayoutEdits.newTab(doc, space: "spA", after: "tbA", id: "tbN", name: "n", paneID: "pN", address: "t9"))
        #expect(after.layoutSpaces[0].layoutTabs.map(\.nodeID) == ["tbA", "tbN", "tbB"])
        #expect(after.layoutSpaces[0].layoutTabs[1] == LayoutEdits.tab(id: "tbN", name: "n", pane: LayoutEdits.terminalPane(id: "pN", address: "t9")))
        let end = try #require(LayoutEdits.newTab(doc, space: "spA", after: nil, id: "tbN", name: "", paneID: "pN", address: "t9"))
        #expect(end.layoutSpaces[0].layoutTabs.map(\.nodeID) == ["tbA", "tbB", "tbN"])
        #expect(LayoutEdits.newTab(doc, space: "spGone", after: nil, id: "tbN", name: "", paneID: "pN", address: "t9") == nil)
        try LayoutValidator.checkWrite(after, base: doc)
    }

    @Test func splitSameAxisHalvesTheShare() throws {
        // pX (weight 0.5) in the root row, split right: both get 0.25, new one right after it.
        let out = try #require(LayoutEdits.split(doc, target: "pX", axis: "row", paneID: "pN", containerID: "sN", address: "t9"))
        let kids = out.layoutSpaces[0].layoutTabs[0]["root"]!.nodeChildren!
        #expect(kids.map(\.nodeID) == ["pX", "pN", "sC"])
        #expect(kids[0]["size"] == ["weight": 0.25] && kids[1]["size"] == ["weight": 0.25])
        #expect(kids[1] == Fixture.json(#"{"id":"pN","type":"block","content":{"terminal":"t9"},"size":{"weight":0.25}}"#))
        // Missing size counts as 1 → 0.5 / 0.5 (pW alone in tbB's root row).
        let w = try #require(LayoutEdits.split(doc, target: "pW", axis: "row", paneID: "pN", containerID: "sN", address: "t9"))
        let wk = w.layoutSpaces[0].layoutTabs[1]["root"]!.nodeChildren!
        #expect(wk.map { $0["size"] } == [["weight": 0.5], ["weight": 0.5]])
        // Same axis inside a column: pY splits down.
        let y = try #require(LayoutEdits.split(doc, target: "pY", axis: "column", paneID: "pN", containerID: "sN", address: "t9"))
        let col = y.layoutSpaces[0].layoutTabs[0]["root"]!.nodeChildren![1]
        #expect(col.nodeChildren!.map(\.nodeID) == ["pY", "pN", "pZ"])
        try LayoutValidator.checkWrite(out, base: doc)
    }

    @Test func splitCrossAxisWrapsTheTarget() throws {
        // pX in a row, split down: a column container takes pX's slot and size.
        let out = try #require(LayoutEdits.split(doc, target: "pX", axis: "column", paneID: "pN", containerID: "sN", address: "t9"))
        let kids = out.layoutSpaces[0].layoutTabs[0]["root"]!.nodeChildren!
        let expected = Fixture.json(#"""
            {"id":"sN","type":"column","children":[
              {"id":"pX","type":"block","content":{"terminal":"t1"}},
              {"id":"pN","type":"block","content":{"terminal":"t9"}}],
             "size":{"weight":0.5}}
            """#)
        #expect(kids[0] == expected)
        #expect(kids[1] == doc.layoutSpaces[0].layoutTabs[0]["root"]!.nodeChildren![1])
        // Already placed (adopted meanwhile): nothing to do.
        #expect(LayoutEdits.split(doc, target: "pX", axis: "column", paneID: "pN", containerID: "sN", address: "t2") == nil)
        #expect(LayoutEdits.split(doc, target: "pGone", axis: "row", paneID: "pN", containerID: "sN", address: "t9") == nil)
        try LayoutValidator.checkWrite(out, base: doc)
    }

    @Test func removeGivesTheShareBackAndCollapses() throws {
        // pY out of column sC: sC is left with pZ alone → pZ takes sC's place and size.
        let r = try #require(LayoutEdits.removePane(doc, id: "pY"))
        #expect(r.removed == ["t2"])
        let kids = r.doc.layoutSpaces[0].layoutTabs[0]["root"]!.nodeChildren!
        #expect(kids.map(\.nodeID) == ["pX", "pZ"])
        #expect(kids[1] == Fixture.json(#"{"id":"pZ","type":"block","content":{"mod":"markdown","props":{"file":"README.md"}},"size":{"weight":0.5}}"#))
        // pX out of the root row: its share goes to the next sibling (it was first); the root never collapses.
        let x = try #require(LayoutEdits.removePane(doc, id: "pX"))
        let root = x.doc.layoutSpaces[0].layoutTabs[0]["root"]!
        #expect(root.nodeChildren!.map(\.nodeID) == ["sC"])
        #expect(root.nodeChildren![0]["size"] == ["weight": 1.0])
        try LayoutValidator.checkWrite(x.doc, base: doc)
        // Share to the previous sibling: three weighted panes.
        let three = Fixture.json(#"{"spaces":[{"id":"s","name":"","folder":"","tabs":[{"id":"t","name":"","root":{"id":"t","type":"row","children":[{"id":"a","type":"block","size":{"weight":0.25},"content":{"terminal":"t1"}},{"id":"b","type":"block","size":{"weight":0.25},"content":{"terminal":"t2"}},{"id":"c","type":"block","content":{"terminal":"t3"}}]}}]}]}"#)
        let rb = try #require(LayoutEdits.removePane(three, id: "b"))
        #expect(rb.doc.layoutSpaces[0].layoutTabs[0]["root"]!.nodeChildren!.map { $0["size"] } == [["weight": 0.5], nil])
        // px-sized neighbors are left alone.
        let px = Fixture.json(three.jsonString().replacingOccurrences(of: #"{"weight":0.25},"content":{"terminal":"t1"}"#, with: #"{"px":200},"content":{"terminal":"t1"}"#))
        let rpx = try #require(LayoutEdits.removePane(px, id: "b"))
        #expect(rpx.doc.layoutSpaces[0].layoutTabs[0]["root"]!.nodeChildren![0]["size"] == ["px": 200])
    }

    @Test func lastPaneClosesTabAndLastTabClosesSpace() throws {
        let tab = try #require(LayoutEdits.removePane(doc, id: "pW"))
        #expect(tab.removed == ["t3"])
        #expect(tab.doc.layoutSpaces[0].layoutTabs.map(\.nodeID) == ["tbA"])
        let space = try #require(LayoutEdits.removePane(doc, id: "pV"))
        #expect(space.removed == ["t4"])
        #expect(space.doc.layoutSpaces.map(\.nodeID) == ["spA"])
        let closeTab = try #require(LayoutEdits.removeTab(doc, id: "tbA"))
        #expect(closeTab.removed == ["t1", "t2"])
        let closeLastTab = try #require(LayoutEdits.removeTab(doc, id: "tbC"))
        #expect(closeLastTab.doc.layoutSpaces.count == 1)
        let closeSpace = try #require(LayoutEdits.removeSpace(doc, id: "spA"))
        #expect(closeSpace.removed == ["t1", "t2", "t3"])
        // Dead-pane cleanup only removes a pane still showing that terminal.
        #expect(LayoutEdits.removePane(doc, id: "pW", expecting: "t9") == nil)
        #expect(LayoutEdits.removePane(doc, id: "pGone") == nil)
        #expect(LayoutEdits.removePane(doc, id: "tbA") == nil)  // the root is not a pane
    }

    @Test func renameAndMove() throws {
        let r = try #require(LayoutEdits.renameSpace(doc, id: "spB", name: "Named"))
        #expect(r.layoutSpaces[1]["name"] == "Named")
        #expect(LayoutEdits.renameSpace(doc, id: "spA", name: "A") == nil)  // no-op
        let t = try #require(LayoutEdits.renameTab(doc, id: "tbB", name: ""))
        #expect(t.layoutSpaces[0].layoutTabs[1]["name"] == "")
        let m = try #require(LayoutEdits.moveTab(doc, id: "tbB", to: 0))
        #expect(m.layoutSpaces[0].layoutTabs.map(\.nodeID) == ["tbB", "tbA"])
        #expect(LayoutEdits.moveTab(doc, id: "tbA", to: 0) == nil)
        #expect(LayoutEdits.moveTab(doc, id: "tbA", to: 99)?.layoutSpaces[0].layoutTabs.map(\.nodeID) == ["tbB", "tbA"])
    }

    @Test func moveSpace() throws {
        let up = try #require(LayoutEdits.moveSpace(doc, id: "spB", before: "spA"))
        #expect(up.layoutSpaces.map(\.nodeID) == ["spB", "spA"])
        #expect(up.layoutSpaces[0] == doc.layoutSpaces[1])  // the space itself is untouched
        let last = try #require(LayoutEdits.moveSpace(doc, id: "spA", before: nil))
        #expect(last.layoutSpaces.map(\.nodeID) == ["spB", "spA"])
        // Already there, onto itself, or a space gone meanwhile: nothing to write.
        #expect(LayoutEdits.moveSpace(doc, id: "spA", before: "spB") == nil)
        #expect(LayoutEdits.moveSpace(doc, id: "spB", before: nil) == nil)
        #expect(LayoutEdits.moveSpace(doc, id: "spA", before: "spA") == nil)
        #expect(LayoutEdits.moveSpace(doc, id: "spA", before: "spGone") == nil)
        #expect(LayoutEdits.moveSpace(doc, id: "spGone", before: nil) == nil)
    }

    @Test func surgicalEditsPreserveUnknownFieldsOrderAndNumbers() throws {
        let local = Fixture.json(Fixture.local)
        let out = try #require(LayoutEdits.renameTab(local, id: "tbf10bf70073a2821aaec1c28eafa96dd2", name: "x"))
        // Unknown space field, the exact f32-widened weight and the key order survive.
        #expect(out.layoutSpaces[1]["x-future"] == ["keep": true])
        let text = out.jsonString()
        #expect(text.contains(#""size":{"weight":0.9999997615814208}"#))
        #expect(text.contains(#""size":{"weight":4.0}"#))
        #expect(text.hasPrefix(#"{"spaces":[{"folder":"/Users/mentor/me/dev/wierd-memory","id":"spe3e2159554ee24c732bb21789555be18","name":"","#))
        #expect(out.layoutSpaces[0] == local.layoutSpaces[0])
        // f32 halving of an f32-widened weight stays exact.
        let s = try #require(LayoutEdits.split(local, target: "p4f77cdf632005f8b05cd79c635a7e819", axis: "row", paneID: "pN", containerID: "sN", address: "t9"))
        let w = s.layoutSpaces[1].layoutTabs[0]["root"]!.nodeChildren![0]["size"]!["weight"]!.double!
        #expect(w == Double(Float(0.9999997615814208) / 2))
    }
}
