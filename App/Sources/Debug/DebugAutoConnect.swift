#if DEBUG
import Foundation
import HerdrSSH

/// Simulator test hooks (DEBUG only), set with `SIMCTL_CHILD_…` env vars:
/// - `WIERDR_IMPORT_KEY=/tmp/wierdr-sshd/client_ed25519`: use that key as this device's identity.
/// - `WIERDR_AUTOCONNECT=user@127.0.0.1:2222`: save that host and connect at launch.
/// - `WIERDR_TRUST_HOSTKEY=1`: accept host keys without asking.
/// - `WIERDR_SELECT_SPACE=<name>`: select that space after connecting.
@MainActor
enum DebugHooks {
    static var type: (String, String) -> Void = { _, _ in }
    static func type(_ text: String, into address: String) { type(text, address) }
}

@MainActor
enum DebugAutoConnect {
    static func run(_ app: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        if let path = env["WIERDR_IMPORT_KEY"], let text = try? String(contentsOfFile: path, encoding: .utf8) {
            do { _ = try AppStores.keys.importIdentity(openSSHPrivateKey: text) } catch { print("[debug] import key: \(error)") }
        }
        guard let target = env["WIERDR_AUTOCONNECT"], app.mode == .none else { return }
        let parts = target.split(separator: "@", maxSplits: 1).map(String.init)
        let (userPart, hostPart) = parts.count == 2 ? (parts[0], parts[1]) : ("", target)
        let hp = hostPart.split(separator: ":")
        var host = app.hosts.hosts.first { $0.name == "debug" } ?? Host()
        host.name = "debug"
        host.address = String(hp[0])
        host.port = hp.count > 1 ? Int(hp[1]) ?? 22 : 22
        host.user = userPart
        host.auth = .key
        app.save(host, password: nil)
        await app.connect(to: host)
        if let e = app.connectionError { print("[debug] connect failed: \(e)") }
        // `WIERDR_SELECT_SPACE=<name>`: show that space first (avoids resizing other terminals while testing).
        if let name = env["WIERDR_SELECT_SPACE"], let s = app.session,
           let space = s.workspace.spaces.first(where: { $0.displayName == name }),
           let pane = space.tabs.first?.panes.first {
            s.focus(pane: pane.id, reveal: false)
        }
        // `WIERDR_DEBUG_STEPS="newSpace;sleep 4;renameSpace x;newTab;split right;split down;closeSpace"`
        if let steps = env["WIERDR_DEBUG_STEPS"], let s = app.session {
            for step in steps.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                print("[debug] step: \(step)")
                let word = step.split(separator: " ", maxSplits: 1).map(String.init)
                let arg = word.count > 1 ? word[1] : ""
                switch word.first ?? "" {
                case "sleep": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
                case "newSpace": s.newSpace()
                case "newTab": s.newTab()
                case "split": s.split(arg == "down" ? .down : .right)
                case "renameSpace":
                    if let id = s.activeSpace?.id { s.commit(.init(target: .space(id), title: "", text: arg)) }
                case "renameTab":
                    if let id = s.activeTab?.id { s.commit(.init(target: .tab(id), title: "", text: arg)) }
                case "zoom": s.toggleZoom()
                case "closePane": if let id = s.focusedPane?.id { s.confirm(.init(target: .pane(id), title: "", message: "")) }
                case "closeTab": if let id = s.activeTab?.id { s.confirm(.init(target: .tab(id), title: "", message: "")) }
                case "closeSpace": if let id = s.activeSpace?.id { s.confirm(.init(target: .space(id), title: "", message: "")) }
                case "selectSpace": if let sp = s.workspace.spaces.first(where: { $0.displayName == arg }),
                                       let p = sp.tabs.first?.panes.first { s.focus(pane: p.id, reveal: false) }
                case "type":
                    if let addr = s.focusedPane?.terminal {
                        // through the terminal session (same path as the keyboard)
                        DebugHooks.type(arg.replacingOccurrences(of: "\\n", with: "\r"), into: addr)
                    }
                default: print("[debug] unknown step \(step)")
                }
            }
            print("[debug] steps done")
        }
    }
}
#endif
