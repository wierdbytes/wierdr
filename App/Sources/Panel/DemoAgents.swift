import SwiftUI
import WierdrModel

/// The demo's agents answering, so its message field and keys do something: a message
/// sent (`ComposerBar`) shows in the drawn terminal as the person's prompt, the agent
/// works for a moment and finishes with a canned answer (`DemoTerminalView` draws both);
/// a shell prints that the demo runs nothing. On an agent that asks (blocked), the key
/// panel's ⏎, y, 1 or 2 allow and esc, n or 3 decline (`PhoneKeyPanel`), and it goes
/// back to work. No herdr-core behind it: the workspace changes here only
/// (`Workspace.changeLocally`), its seen rule too (`markSeen`: done turns idle on screen).
@MainActor
@Observable
final class DemoAgents {
    struct Exchange: Equatable {
        var prompt: String
        /// Nil while the agent works on it.
        var reply: String?
    }

    /// What was sent to each terminal, oldest first.
    private(set) var exchanges: [String: [Exchange]] = [:]

    @ObservationIgnored private let workspace: Workspace

    /// How long an agent works on a message or an answer.
    static let workTime: Duration = .seconds(3)

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// A message from the field (the text as it would be pasted, then Return).
    func send(_ text: String, to address: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let t = workspace.terminal(address) else { return }
        Tutorial.shared.reportMessage()
        guard t.isAgent else {
            let command = text.split(separator: " ").first.map(String.init) ?? text
            exchanges[address, default: []].append(Exchange(
                prompt: text, reply: "demo: nothing runs here, connect your Mac to run \(command)"))
            return
        }
        let i = exchanges[address, default: []].count
        exchanges[address, default: []].append(Exchange(prompt: text))
        work(address) { [weak self] in
            self?.exchanges[address]?[i].reply = Self.reply(to: t)
        }
    }

    /// A key from the key panel: an answer, when the agent asks something.
    func press(_ key: TerminalSession.Key, on address: String) {
        guard let t = workspace.terminal(address), t.status == .blocked else { return }
        let allow: Bool
        switch key {
        case .enter, .text("y"), .text("Y"), .text("1"), .text("2"): allow = true
        case .escape, .text("n"), .text("N"), .text("3"): allow = false
        default: return
        }
        work(address, doing: allow ? Self.allowed(t.message) : "Going on without it")
    }

    /// The agent works (`doing`: its new message) and, after a moment, is done with a new turn.
    private func work(_ address: String, doing: String? = nil, then answered: @escaping () -> Void = {}) {
        workspace.changeLocally(address) { t in
            t.status = .working
            t.state = "working"
            t.statusChangedAt = Date()
            if let doing { t.message = doing }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.workTime)
            guard let self else { return }
            answered()
            self.workspace.changeLocally(address) { t in
                t.turn += 1
                t.status = .done
                t.state = "idle"
                t.statusChangedAt = Date()
            }
        }
    }

    private static func reply(to t: TerminalInfo) -> String {
        "This is the demo, so nothing ran. With your Mac connected, your message goes to \(t.program.name) as if typed there, and you watch it work here."
    }

    /// "Allow reading ~/.ssh/config?" → "Reading ~/.ssh/config".
    private static func allowed(_ question: String?) -> String {
        guard var q = question?.trimmingCharacters(in: .whitespaces), q.hasPrefix("Allow ") else { return "Going on" }
        q.removeFirst("Allow ".count)
        if q.hasSuffix("?") { q.removeLast() }
        return q.prefix(1).uppercased() + q.dropFirst()
    }
}
