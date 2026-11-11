import Foundation
import HerdrCore

/// A machine's raw document as public value types, with ids and addresses
/// qualified the way herdr-app qualifies them (`Document::replace`).
/// Names, colors, statuses and git facts are filled in by the engine.
enum LayoutParser {
    static func spaces(_ doc: JSONValue, machine: String?) -> [Space] {
        doc.layoutSpaces.map { s in
            let sid = LayoutID.qualify(s.nodeID, machine)
            let tabs = s.layoutTabs.enumerated().map { i, t in
                let tid = LayoutID.qualify(t.nodeID, machine)
                let children = (t["root"]?.nodeChildren ?? []).compactMap { node($0, machine: machine) }
                return Tab(id: tid, spaceID: sid, name: t["name"]?.string ?? "", index: i,
                           root: PaneNode(id: tid, kind: .row(children)))
            }
            let name = s["name"]?.string ?? ""
            return Space(id: sid, machine: machine, name: name, displayName: name, folder: s["folder"]?.string ?? "", tabs: tabs)
        }
    }

    static func node(_ v: JSONValue, machine: String?) -> PaneNode? {
        let id = LayoutID.qualify(v.nodeID, machine)
        let weight: Double
        switch LayoutEdits.sizeKind(v) {
        case .weight(let w): weight = w
        case .missing, .px: weight = 1
        }
        switch v.nodeType {
        case "block":
            if let a = v.paneTerminal { return PaneNode(id: id, kind: .terminal(LayoutID.qualify(a, machine)), weight: weight) }
            if let m = v.paneMod { return PaneNode(id: id, kind: .mod(m), weight: weight) }
            return nil
        case "row", "stack":
            return PaneNode(id: id, kind: .row((v.nodeChildren ?? []).compactMap { node($0, machine: machine) }), weight: weight)
        case "column":
            return PaneNode(id: id, kind: .column((v.nodeChildren ?? []).compactMap { node($0, machine: machine) }), weight: weight)
        default:
            return nil
        }
    }
}
