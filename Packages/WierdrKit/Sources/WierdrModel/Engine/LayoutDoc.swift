import Foundation
import HerdrCore

// The `herdr-app` layout document as raw JSON: ids, qualification, the strict
// decoder (what herdr-app's serde types accept) and the invariants it keeps.
// docs/research/herdr-app-model.md §1–§3.

// MARK: - Ids

enum LayoutID {
    /// `lf/x` for machine `lf`, bare `x` on the connected computer (`mirror::qualify`).
    static func qualify(_ id: String, _ machine: String?) -> String {
        guard let machine, !machine.isEmpty else { return id }
        return "\(machine)/\(id)"
    }

    /// The id as that machine's own document stores it (`mirror::local`).
    static func local(_ id: String, _ machine: String?) -> String {
        guard let machine, !machine.isEmpty, id.hasPrefix(machine + "/") else { return id }
        return String(id.dropFirst(machine.count + 1))
    }

    /// The machine part of a qualified id/address (`lf` for `lf/t1`), nil when bare.
    static func machine(of id: String) -> String? {
        guard let slash = id.firstIndex(of: "/") else { return nil }
        return String(id[..<slash])
    }

    /// `prefix` + 32 lowercase hex (`Model::fresh_id`).
    static func fresh(_ prefix: String) -> String {
        prefix + String(format: "%016llx%016llx", UInt64.random(in: .min ... .max), UInt64.random(in: .min ... .max))
    }
}

// MARK: - Reading helpers

extension JSONValue {
    var layoutSpaces: [JSONValue] { self["spaces"]?.array ?? [] }
    var layoutTabs: [JSONValue] { self["tabs"]?.array ?? [] }
    var nodeID: String { self["id"]?.string ?? "" }
    var nodeType: String? { self["type"]?.string }
    var nodeChildren: [JSONValue]? {
        switch nodeType {
        case "row", "column", "stack": return self["children"]?.array
        default: return nil
        }
    }

    /// The terminal address of a terminal block.
    var paneTerminal: String? {
        guard nodeType == "block" else { return nil }
        return self["content"]?["terminal"]?.string
    }

    /// The mod name of a mod block (only when it is not a terminal block, as serde's untagged order says).
    var paneMod: String? {
        guard nodeType == "block", paneTerminal == nil else { return nil }
        return self["content"]?["mod"]?.string
    }

    /// `Node::is_pane`: a block showing a terminal or a mod.
    var isPaneNode: Bool { paneTerminal != nil || paneMod != nil }

    /// Panes in tree order.
    var paneNodes: [JSONValue] {
        if isPaneNode { return [self] }
        return (nodeChildren ?? []).flatMap(\.paneNodes)
    }

    /// Terminal addresses in tree order.
    var terminalAddresses: [String] { paneNodes.compactMap(\.paneTerminal) }

    /// Whether some node in this subtree has `id`.
    func containsNode(_ id: String) -> Bool {
        if nodeID == id { return true }
        return (nodeChildren ?? []).contains { $0.containsNode(id) }
    }

    func findNode(_ id: String) -> JSONValue? {
        if nodeID == id { return self }
        for c in nodeChildren ?? [] { if let n = c.findNode(id) { return n } }
        return nil
    }
}

/// Where things are in a raw document (indices into `spaces` / `tabs`).
struct LayoutLocation: Equatable {
    var space: Int
    var tab: Int?
}

extension JSONValue {
    func locateSpace(_ id: String) -> Int? {
        layoutSpaces.firstIndex { $0["id"]?.string == id }
    }

    func locateTab(_ id: String) -> LayoutLocation? {
        for (si, s) in layoutSpaces.enumerated() {
            if let ti = s.layoutTabs.firstIndex(where: { $0["id"]?.string == id }) { return LayoutLocation(space: si, tab: ti) }
        }
        return nil
    }

    /// The tab holding a node (pane or container).
    func locateNode(_ id: String) -> LayoutLocation? {
        for (si, s) in layoutSpaces.enumerated() {
            for (ti, t) in s.layoutTabs.enumerated() where t["root"]?.containsNode(id) == true {
                return LayoutLocation(space: si, tab: ti)
            }
        }
        return nil
    }

    /// The pane showing a terminal address (first match, as `pane_of`).
    func paneShowing(_ address: String) -> (location: LayoutLocation, pane: String)? {
        for (si, s) in layoutSpaces.enumerated() {
            for (ti, t) in s.layoutTabs.enumerated() {
                if let p = t["root"]?.paneNodes.first(where: { $0.paneTerminal == address }) {
                    return (LayoutLocation(space: si, tab: ti), p.nodeID)
                }
            }
        }
        return nil
    }
}

// MARK: - Strict decoder

struct LayoutDocError: Error, CustomStringConvertible, Equatable {
    var message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}

/// Mirrors what herdr-app's serde types (`mirror::Document`, `layout::Node`)
/// accept. A document this rejects would make the desktop show "Layout
/// unavailable" for that machine.
enum LayoutValidator {
    /// Throws when herdr-app could not decode `doc` (`null` is fine: no spaces).
    static func decode(_ doc: JSONValue) throws {
        switch doc {
        case .null: return
        case .object(let o):
            if let spaces = o["spaces"] {
                guard case .array(let list) = spaces else { throw LayoutDocError("spaces is not an array") }
                for (i, s) in list.enumerated() { try space(s, "spaces[\(i)]") }
            }
        default:
            throw LayoutDocError("the document is not an object")
        }
    }

    private static func string(_ o: JSONObject, _ key: String, _ path: String) throws {
        if let v = o[key], v.string == nil { throw LayoutDocError("\(path).\(key) is not a string") }
    }

    private static func optionalString(_ o: JSONObject, _ key: String, _ path: String) throws {
        if let v = o[key], !v.isNull, v.string == nil { throw LayoutDocError("\(path).\(key) is not a string") }
    }

    private static func optionalNumber(_ o: JSONObject, _ key: String, _ path: String) throws {
        if let v = o[key], !v.isNull, v.double == nil { throw LayoutDocError("\(path).\(key) is not a number") }
    }

    private static func space(_ v: JSONValue, _ path: String) throws {
        guard case .object(let o) = v else { throw LayoutDocError("\(path) is not an object") }
        for key in ["id", "name", "folder"] { try string(o, key, path) }
        if let tabs = o["tabs"] {
            guard case .array(let list) = tabs else { throw LayoutDocError("\(path).tabs is not an array") }
            for (i, t) in list.enumerated() { try tab(t, "\(path).tabs[\(i)]") }
        }
    }

    private static func tab(_ v: JSONValue, _ path: String) throws {
        guard case .object(let o) = v else { throw LayoutDocError("\(path) is not an object") }
        for key in ["id", "name"] { try string(o, key, path) }
        if let root = o["root"] { try node(root, "\(path).root") }
    }

    static func node(_ v: JSONValue, _ path: String) throws {
        guard case .object(let o) = v else { throw LayoutDocError("\(path) is not an object") }
        try string(o, "id", path)
        guard let type = o["type"]?.string else { throw LayoutDocError("\(path) has no type") }
        switch type {
        case "block":
            guard let c = o["content"] else { throw LayoutDocError("\(path) is a block without content") }
            try content(c, "\(path).content")
        case "row", "column", "stack":
            guard case .array(let children)? = o["children"] else { throw LayoutDocError("\(path) has no children array") }
            for (i, c) in children.enumerated() { try node(c, "\(path).children[\(i)]") }
            if type == "stack" { try optionalString(o, "active", path) }
        default:
            throw LayoutDocError("\(path) has an unknown type \(type)")
        }
        if let size = o["size"], !size.isNull {
            // Untagged `Size`: {px: f32} or {weight: f32}.
            let px = size["px"].map { $0.double != nil } ?? false
            let weight = size["weight"].map { $0.double != nil } ?? false
            guard size.object != nil, px || weight else { throw LayoutDocError("\(path).size is neither {px} nor {weight}") }
        }
        try optionalNumber(o, "min", path)
        try optionalNumber(o, "max", path)
        try optionalString(o, "title", path)
        if let hidden = o["hidden"], hidden.bool == nil { throw LayoutDocError("\(path).hidden is not a bool") }
        if let floating = o["floating"], floating.array == nil { throw LayoutDocError("\(path).floating is not an array") }
        if let cloned = o["cloned_from"], !cloned.isNull {
            guard cloned["name"]?.string != nil, cloned["version"]?.string != nil else {
                throw LayoutDocError("\(path).cloned_from is malformed")
            }
        }
    }

    /// Untagged `Content`, tried in serde's order: terminal, mod, tab/context, agent.
    private static func content(_ v: JSONValue, _ path: String) throws {
        guard v.object != nil else { throw LayoutDocError("\(path) is not an object") }
        if v["terminal"]?.string != nil { return }
        if v["mod"]?.string != nil { return }
        if (v["tab"] ?? v["context"])?.string != nil { return }
        if v["agent"]?.string != nil { return }
        throw LayoutDocError("\(path) is neither a terminal, a mod, a tab nor an agent")
    }

    // MARK: Invariants (§3.5.4)

    /// Everything wrong with `doc` by herdr-app's own rules, as stable strings.
    static func violations(_ doc: JSONValue) -> Set<String> {
        var out = Set<String>()
        var spaceIDs = Set<String>(), tabIDs = Set<String>(), nodeIDs = Set<String>(), addresses = Set<String>()
        for s in doc.layoutSpaces {
            let sid = s.nodeID
            if sid.isEmpty { out.insert("a space without id") }
            if !spaceIDs.insert(sid).inserted { out.insert("duplicate space \(sid)") }
            if s.layoutTabs.isEmpty { out.insert("space \(sid) has no tabs") }
            for t in s.layoutTabs {
                let tid = t.nodeID
                if tid.isEmpty { out.insert("a tab without id in \(sid)") }
                if !tabIDs.insert(tid).inserted { out.insert("duplicate tab \(tid)") }
                guard let root = t["root"] else { out.insert("tab \(tid) has no root"); continue }
                if root.nodeID != tid { out.insert("tab \(tid) root id differs") }
                if root.nodeType != "row" { out.insert("tab \(tid) root is not a row") }
                if root.paneNodes.isEmpty { out.insert("tab \(tid) has no panes") }
                func walk(_ n: JSONValue, isRoot: Bool) {
                    if !isRoot {
                        let id = n.nodeID
                        if id.isEmpty { out.insert("a node without id in \(tid)") }
                        if !nodeIDs.insert(id).inserted { out.insert("duplicate node \(id)") }
                        if (n.nodeType == "row" || n.nodeType == "column"), (n.nodeChildren?.count ?? 0) < 2 {
                            out.insert("container \(id) has fewer than 2 children")
                        }
                    }
                    if let a = n.paneTerminal {
                        if a.isEmpty || a.contains("/") { out.insert("bad terminal address \(a)") }
                        if !addresses.insert(a).inserted { out.insert("terminal \(a) in two panes") }
                    }
                    for c in n.nodeChildren ?? [] { walk(c, isRoot: false) }
                }
                walk(root, isRoot: true)
            }
        }
        return out
    }

    /// The gate before every `doc.set`: decodable by herdr-app, not null, under
    /// 1 MiB, and breaking no invariant the base document kept.
    static func checkWrite(_ new: JSONValue, base: JSONValue) throws {
        guard case .object = new else { throw LayoutDocError("refusing to write a document that is not an object") }
        try decode(new)
        let size = (try? new.data().count) ?? Int.max
        guard size < 1 << 20 else { throw LayoutDocError("the document would exceed 1 MiB") }
        let before = (try? decode(base)) != nil ? violations(base) : []
        let introduced = violations(new).subtracting(before)
        if !introduced.isEmpty {
            throw LayoutDocError("refusing to write a broken layout: \(introduced.sorted().joined(separator: "; "))")
        }
    }
}
