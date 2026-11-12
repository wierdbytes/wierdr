import Foundation
import HerdrCore

/// Pure edits of a raw `herdr-app` document, mirroring herdr-app's model
/// commands (`src/model.rs`, `Node::split` / `Node::remove` in `src/layout.rs`).
///
/// Every function takes the freshest document and returns the edited one, or
/// nil when the intent no longer applies (its target is gone, it is already
/// done). Ids are the machine-local ones the document stores. Everything the
/// edit does not touch (unknown fields, key order, number kinds, mod panes and
/// their props) is preserved as it was.
enum LayoutEdits {
    // MARK: Builders (herdr-app's shapes: `Tab::new`, `pane`)

    static func terminalPane(id: String, address: String) -> JSONValue {
        ["id": .string(id), "type": "block", "content": ["terminal": .string(address)]]
    }

    static func tab(id: String, name: String, pane: JSONValue) -> JSONValue {
        ["id": .string(id), "name": .string(name), "root": ["id": .string(id), "type": "row", "children": [pane]]]
    }

    static func space(id: String, name: String, folder: String, tab: JSONValue) -> JSONValue {
        ["id": .string(id), "name": .string(name), "folder": .string(folder), "tabs": [tab]]
    }

    // MARK: Plumbing

    private static func spaces(_ doc: JSONValue) -> [JSONValue] { doc.layoutSpaces }

    private static func withSpaces(_ doc: JSONValue, _ body: (inout [JSONValue]) -> Bool) -> JSONValue? {
        var list = doc.layoutSpaces
        guard body(&list) else { return nil }
        var out = doc.isNull ? JSONValue.object(JSONObject()) : doc
        out["spaces"] = .array(list)
        return out
    }

    private static func withTabs(_ space: inout JSONValue, _ body: (inout [JSONValue]) -> Bool) -> Bool {
        var tabs = space.layoutTabs
        guard body(&tabs) else { return false }
        space["tabs"] = .array(tabs)
        return true
    }

    /// Flex weight of a size for splitting: weight → it, missing → 1, px → 1 (but untouched).
    enum SizeKind { case missing, weight(Double), px }

    static func sizeKind(_ node: JSONValue) -> SizeKind {
        guard let size = node["size"], !size.isNull else { return .missing }
        if size["px"]?.double != nil { return .px }  // untagged: Px is tried first
        if let w = size["weight"]?.double { return .weight(w) }
        return .missing
    }

    /// f32 arithmetic, as herdr-app's `Size::Weight { weight: f32 }` does it.
    static func weight(_ value: Float) -> JSONValue { ["weight": .double(Double(value))] }

    // MARK: Spaces

    /// `space.new`: appends a space (after `after`, when given and present).
    /// Already placed (the desktop adopted the terminal): only the name is left to set.
    static func newSpace(_ doc: JSONValue, id: String, name: String, folder: String, tabID: String,
                         paneID: String, address: String, after: String? = nil) -> JSONValue? {
        if let placed = doc.paneShowing(address) {
            guard !name.isEmpty else { return nil }
            return withSpaces(doc) { list in
                guard list[placed.location.space].nodeID == id,
                      (list[placed.location.space]["name"]?.string ?? "").isEmpty else { return false }
                list[placed.location.space]["name"] = .string(name)
                return true
            }
        }
        if doc.locateSpace(id) != nil { return nil }
        let new = space(id: id, name: name, folder: folder,
                        tab: tab(id: tabID, name: "", pane: terminalPane(id: paneID, address: address)))
        return withSpaces(doc) { list in
            if let after, let i = list.firstIndex(where: { $0.nodeID == after }) {
                list.insert(new, at: i + 1)
            } else {
                list.append(new)
            }
            return true
        }
    }

    static func renameSpace(_ doc: JSONValue, id: String, name: String) -> JSONValue? {
        guard let si = doc.locateSpace(id), doc.layoutSpaces[si]["name"]?.string ?? "" != name else { return nil }
        return withSpaces(doc) { list in
            list[si]["name"] = .string(name)
            return true
        }
    }

    /// `space.move`: puts a space just before `before` (another space of this
    /// document, i.e. of its machine), or last when `before` is nil. Nil when it
    /// is already there or either space is gone.
    static func moveSpace(_ doc: JSONValue, id: String, before: String?) -> JSONValue? {
        guard let from = doc.locateSpace(id), before != id else { return nil }
        if let before, doc.locateSpace(before) == nil { return nil }
        return withSpaces(doc) { list in
            let space = list.remove(at: from)
            let to = before.flatMap { b in list.firstIndex { $0.nodeID == b } } ?? list.count
            guard to != from else { return false }
            list.insert(space, at: to)
            return true
        }
    }

    /// `space.close`: removes it; returns the terminal addresses it held.
    static func removeSpace(_ doc: JSONValue, id: String) -> (doc: JSONValue, removed: [String])? {
        guard let si = doc.locateSpace(id) else { return nil }
        let removed = doc.layoutSpaces[si].layoutTabs.flatMap { $0["root"]?.terminalAddresses ?? [] }
        guard let out = withSpaces(doc, { list in list.remove(at: si); return true }) else { return nil }
        return (out, removed)
    }

    // MARK: Tabs

    /// `tab.new`: a tab with one terminal pane, after `after` (else at the end).
    /// Already placed: only the tab name is left to set.
    static func newTab(_ doc: JSONValue, space spaceID: String, after: String?, id: String, name: String,
                       paneID: String, address: String) -> JSONValue? {
        if let placed = doc.paneShowing(address) {
            guard !name.isEmpty, let ti = placed.location.tab else { return nil }
            return withSpaces(doc) { list in
                withTabs(&list[placed.location.space]) { tabs in
                    guard tabs[ti].nodeID == id, (tabs[ti]["name"]?.string ?? "").isEmpty else { return false }
                    tabs[ti]["name"] = .string(name)
                    return true
                }
            }
        }
        guard let si = doc.locateSpace(spaceID), doc.locateTab(id) == nil else { return nil }
        let new = tab(id: id, name: name, pane: terminalPane(id: paneID, address: address))
        return withSpaces(doc) { list in
            withTabs(&list[si]) { tabs in
                if let after, let i = tabs.firstIndex(where: { $0.nodeID == after }) {
                    tabs.insert(new, at: i + 1)
                } else {
                    tabs.append(new)
                }
                return true
            }
        }
    }

    static func renameTab(_ doc: JSONValue, id: String, name: String) -> JSONValue? {
        guard let loc = doc.locateTab(id), let ti = loc.tab,
              doc.layoutSpaces[loc.space].layoutTabs[ti]["name"]?.string ?? "" != name else { return nil }
        return withSpaces(doc) { list in
            withTabs(&list[loc.space]) { tabs in
                tabs[ti]["name"] = .string(name)
                return true
            }
        }
    }

    /// Moves a tab within its space to 0-based `index` (clamped).
    static func moveTab(_ doc: JSONValue, id: String, to index: Int) -> JSONValue? {
        guard let loc = doc.locateTab(id), let from = loc.tab else { return nil }
        let count = doc.layoutSpaces[loc.space].layoutTabs.count
        let to = max(0, min(index, count - 1))
        guard to != from else { return nil }
        return withSpaces(doc) { list in
            withTabs(&list[loc.space]) { tabs in
                let t = tabs.remove(at: from)
                tabs.insert(t, at: to)
                return true
            }
        }
    }

    /// `tab.close`: the space's only tab closes the space.
    static func removeTab(_ doc: JSONValue, id: String) -> (doc: JSONValue, removed: [String])? {
        guard let loc = doc.locateTab(id), let ti = loc.tab else { return nil }
        let space = doc.layoutSpaces[loc.space]
        if space.layoutTabs.count == 1 { return removeSpace(doc, id: space.nodeID) }
        let removed = space.layoutTabs[ti]["root"]?.terminalAddresses ?? []
        guard let out = withSpaces(doc, { list in
            withTabs(&list[loc.space]) { tabs in tabs.remove(at: ti); return true }
        }) else { return nil }
        return (out, removed)
    }

    // MARK: Panes

    /// `pane.split`: puts a new terminal pane beside `target` along `axis`
    /// (`"row"` = right, `"column"` = down). Already placed: nothing to do.
    static func split(_ doc: JSONValue, target: String, axis: String, paneID: String, containerID: String,
                      address: String) -> JSONValue? {
        if doc.paneShowing(address) != nil { return nil }
        guard let loc = doc.locateNode(target), let ti = loc.tab,
              doc.layoutSpaces[loc.space].layoutTabs[ti]["root"]?.findNode(target)?.isPaneNode == true else { return nil }
        return withSpaces(doc) { list in
            withTabs(&list[loc.space]) { tabs in
                guard var root = tabs[ti]["root"] else { return false }
                guard splitNode(&root, target: target, axis: axis,
                                new: terminalPane(id: paneID, address: address), containerID: containerID) else { return false }
                tabs[ti]["root"] = root
                return true
            }
        }
    }

    /// `Node::split`.
    static func splitNode(_ root: inout JSONValue, target: String, axis: String, new: JSONValue, containerID: String) -> Bool {
        if let parent = parentID(of: target, in: root),
           root.findNode(parent)?.nodeType == axis {
            return mutate(&root, parent) { p in
                guard var c = p["children"]?.array, let i = c.firstIndex(where: { $0.nodeID == target }) else { return }
                let share: Float
                switch sizeKind(c[i]) {
                case .weight(let w): share = Float(w)
                case .missing, .px: share = 1
                }
                if case .px = sizeKind(c[i]) {} else { c[i]["size"] = weight(share / 2) }
                var n = new
                n["size"] = weight(share / 2)
                c.insert(n, at: i + 1)
                p["children"] = .array(c)
            }
        }
        return mutate(&root, target) { t in
            var old = t
            let slot = old["size"]
            old["size"] = nil
            var wrapper: JSONValue = ["id": .string(containerID), "type": .string(axis), "children": [old, new]]
            if let slot { wrapper["size"] = slot }
            t = wrapper
        }
    }

    /// `pane.close` / dead-pane cleanup: removes a pane (its tab when it was the
    /// last, its space when that was the last tab). With `expecting`, only if the
    /// pane still shows that terminal address.
    static func removePane(_ doc: JSONValue, id: String, expecting: String? = nil) -> (doc: JSONValue, removed: [String])? {
        guard let loc = doc.locateNode(id), let ti = loc.tab,
              let root = doc.layoutSpaces[loc.space].layoutTabs[ti]["root"],
              let pane = root.findNode(id), pane.isPaneNode, root.nodeID != id else { return nil }
        if let expecting, pane.paneTerminal != expecting { return nil }
        var newRoot = root
        guard removeNode(&newRoot, id) != nil else { return nil }
        if newRoot.paneNodes.isEmpty {
            guard let r = removeTab(doc, id: doc.layoutSpaces[loc.space].layoutTabs[ti].nodeID) else { return nil }
            return r
        }
        guard let out = withSpaces(doc, { list in
            withTabs(&list[loc.space]) { tabs in tabs[ti]["root"] = newRoot; return true }
        }) else { return nil }
        return (out, pane.paneTerminal.map { [$0] } ?? [])
    }

    /// `Node::remove`: remove + collapse (the root itself never collapses).
    @discardableResult
    static func removeNode(_ root: inout JSONValue, _ id: String) -> JSONValue? {
        guard let removed = removeInner(&root, id) else { return nil }
        collapse(&root)
        return removed
    }

    private static func removeInner(_ node: inout JSONValue, _ id: String) -> JSONValue? {
        guard var c = node.nodeChildren else { return nil }
        if let i = c.firstIndex(where: { $0.nodeID == id }) {
            let removed = c.remove(at: i)
            if node.nodeType == "row" || node.nodeType == "column" {
                // Its share goes back to the neighbor it was split from (before it, else the next).
                func share(_ n: JSONValue) -> Float? {
                    switch sizeKind(n) {
                    case .weight(let w): return Float(w)
                    case .missing: return 1
                    case .px: return nil
                    }
                }
                let j = max(i - 1, 0)
                if let gone = share(removed), c.indices.contains(j), let w = share(c[j]) {
                    c[j]["size"] = weight(w + gone)
                }
            }
            if node.nodeType == "stack", node["active"]?.string == id {
                if let next = (c.indices.contains(i) ? c[i] : c.last) { node["active"] = .string(next.nodeID) } else { node["active"] = nil }
            }
            node["children"] = .array(c)
            return removed
        }
        for k in c.indices {
            if let r = removeInner(&c[k], id) {
                node["children"] = .array(c)
                return r
            }
        }
        return nil
    }

    private static func isLine(_ n: JSONValue) -> Bool { n.nodeType == "row" || n.nodeType == "column" }

    /// Empty rows/columns vanish; ones left with one child give way to it (it takes their size).
    static func collapse(_ node: inout JSONValue) {
        guard var c = node.nodeChildren else { return }
        let before = c
        for k in c.indices { collapse(&c[k]) }
        if node.nodeType != "stack" {
            c.removeAll { isLine($0) && ($0.nodeChildren?.isEmpty ?? false) }
            for k in c.indices where isLine(c[k]) && c[k].nodeChildren?.count == 1 {
                let size = c[k]["size"]
                var only = c[k].nodeChildren![0]
                only["size"] = size
                c[k] = only
            }
        }
        if c != before { node["children"] = .array(c) }
    }

    // MARK: Tree helpers

    static func parentID(of id: String, in node: JSONValue) -> String? {
        for c in node.nodeChildren ?? [] {
            if c.nodeID == id { return node.nodeID }
            if let p = parentID(of: id, in: c) { return p }
        }
        return nil
    }

    /// Applies `f` to the first node with `id` (depth first). False when there is none.
    @discardableResult
    static func mutate(_ node: inout JSONValue, _ id: String, _ f: (inout JSONValue) -> Void) -> Bool {
        if node.nodeID == id {
            f(&node)
            return true
        }
        guard var c = node.nodeChildren else { return false }
        for k in c.indices where mutate(&c[k], id, f) {
            node["children"] = .array(c)
            return true
        }
        return false
    }
}
