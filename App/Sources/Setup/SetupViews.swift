import SwiftUI
import WierdrModel

/// What the app says about wierdrd and offers to do: its state, a line on why, the
/// button (Install with Homebrew, Start, Update, Check Again). Rows of a `Form` section,
/// shared by the setup sheet and Settings → Daemon.
struct DaemonRows: View {
    var daemon: DaemonState
    var host: String

    var body: some View {
        LabeledContent("wierdrd") {
            HStack(spacing: 6) {
                if busy {
                    ProgressView()
                } else if daemon.verdict == .running && !daemon.isWorking {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
                Text(statusText)
            }
        }
        if let note {
            Label {
                Text(note.text).textSelection(.enabled)
            } icon: {
                Image(systemName: note.symbol).foregroundStyle(note.color)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if let action = offered {
            Button {
                daemon.perform(action)
            } label: {
                Label(Self.title(of: action), systemImage: Self.symbol(of: action))
            }
            .disabled(daemon.isWorking)
        } else if canCheckAgain {
            Button {
                daemon.check()
            } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
            }
            .disabled(daemon.phase == .checking)
        }
    }

    /// The terminal commands behind the offered action, for a section's footer.
    @ViewBuilder var commandsFooter: some View {
        if let action = offered ?? working {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wierdr runs this on \(host):")
                Text(Daemon.commands(for: action).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var busy: Bool {
        daemon.isWorking || (daemon.phase == .checking && daemon.status == nil)
    }

    private var working: Daemon.Action? {
        if case .working(let a) = daemon.phase { return a }
        return nil
    }

    private var offered: Daemon.Action? {
        guard !daemon.isWorking, case .offer(let a)? = daemon.verdict else { return nil }
        return a
    }

    private var canCheckAgain: Bool {
        guard !daemon.isWorking else { return false }
        switch daemon.verdict {
        case .needsBrew, .stoppedOutsideBrew: return true
        case nil: return daemon.error != nil
        default: return daemon.error != nil
        }
    }

    private var statusText: String {
        if let working {
            switch working {
            case .install: return "Installing…"
            case .start: return "Starting…"
            case .update: return "Updating…"
            }
        }
        guard let s = daemon.status else { return daemon.error == nil ? "Checking…" : "Couldn't check" }
        let version = s.version.map { " · \($0)" } ?? ""
        switch s.verdict {
        case .running: return "Running" + version
        case .unsupported: return "Not available"
        case .needsBrew, .offer(.install): return "Not installed"
        case .stoppedOutsideBrew, .offer(.start): return "Not running"
        case .offer(.update): return s.running ? "Running" + version + ", out of date" : "Out of date"
        }
    }

    private struct Note {
        var text: String
        var symbol: String
        var color: Color
    }

    private var note: Note? {
        if daemon.isWorking {
            return Note(text: "Homebrew can take a minute or two.", symbol: "clock", color: .secondary)
        }
        if let error = daemon.error {
            return Note(text: error, symbol: "exclamationmark.triangle.fill", color: .orange)
        }
        guard let s = daemon.status else { return nil }
        switch s.verdict {
        case .running, .offer(.install):
            return nil
        case .unsupported(let os):
            return Note(text: "wierdrd runs on macOS; \(host) runs \(os).", symbol: "info.circle", color: .secondary)
        case .needsBrew:
            return Note(text: "Wierdr installs it with Homebrew, which \(host) doesn't have. Install Homebrew from brew.sh, then check again.",
                        symbol: "info.circle", color: .secondary)
        case .stoppedOutsideBrew:
            return Note(text: "It's installed at \(s.path ?? "?"), not by Homebrew: start it there.",
                        symbol: "info.circle", color: .secondary)
        case .offer(.start):
            // Its log's last line only after a crash: stopped on purpose, it's just the last push.
            guard let code = s.lastExit.flatMap(Int.init), code != 0 else { return nil }
            let text = "It stopped with exit code \(code)" + (s.lastLog.map { ": \($0)" } ?? ".")
            return Note(text: text, symbol: "exclamationmark.triangle.fill", color: .orange)
        case .offer(.update):
            return Note(text: "Wierdr needs wierdrd \(Daemon.minimumVersion) or later; \(host) has \(s.version ?? "an older one").",
                        symbol: "info.circle", color: .secondary)
        }
    }

    static func title(of action: Daemon.Action) -> String {
        switch action {
        case .install: return "Install with Homebrew"
        case .start: return "Start wierdrd"
        case .update: return "Update wierdrd"
        }
    }

    static func symbol(of action: Daemon.Action) -> String {
        switch action {
        case .install: return "arrow.down.circle"
        case .start: return "play.circle"
        case .update: return "arrow.triangle.2.circlepath"
        }
    }
}

/// The agent integrations for the harnesses found on the computer, one row each (its name,
/// version and integration, whether it's in, why not, the button): rows of a `Form`
/// section, shared by the setup sheet and Settings → Agent Integrations.
struct IntegrationRows: View {
    var integrations: IntegrationsState
    var host: String

    var body: some View {
        if let status = integrations.status {
            if status.found.isEmpty {
                Text("No pi, Claude Code or Codex found on \(host).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(status.found, id: \.harness) { found in
                row(found)
            }
        } else if let error = integrations.error {
            Label { Text(error).textSelection(.enabled) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Button { integrations.check() } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                .disabled(integrations.checking)
        } else {
            LabeledContent("Agents") {
                HStack(spacing: 8) { ProgressView(); Text("Checking…") }
            }
        }
    }

    @ViewBuilder private func row(_ found: Integrations.Found) -> some View {
        let h = found.harness
        let working = integrations.working == h
        LabeledContent {
            HStack(spacing: 8) {
                if working { ProgressView() }
                Text(working ? "Installing…" : Self.status(of: found))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(h.name)
                Text([found.version, h.integration].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        if let note = note(found) {
            Label { Text(note.text).textSelection(.enabled) } icon: {
                Image(systemName: note.symbol).foregroundStyle(note.color)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if !working, case .offer(let action) = found.verdict {
            Button {
                integrations.install(h)
            } label: {
                Label(action == .enable ? "Enable \(h.integration)" : "Install \(h.integration)",
                      systemImage: action == .enable ? "checkmark.circle" : "arrow.down.circle")
            }
            .disabled(integrations.working != nil)
        }
    }

    static func status(of found: Integrations.Found) -> String {
        switch found.verdict {
        case .installed: return "Installed"
        case .offer(.enable): return "Disabled"
        case .offer(.install): return "Not installed"
        case .tooOld: return "Too old"
        case .needsPython: return "Needs python3"
        }
    }

    private struct Note {
        var text: String
        var symbol: String
        var color: Color
    }

    private func note(_ found: Integrations.Found) -> Note? {
        let h = found.harness
        if let failure = integrations.failures[h] {
            return Note(text: failure, symbol: "exclamationmark.triangle.fill", color: .orange)
        }
        if integrations.working == h {
            return Note(text: "It can take a minute.", symbol: "clock", color: .secondary)
        }
        switch found.verdict {
        case .tooOld(let needs):
            return Note(text: "\(h.integration) needs \(h.name) \(needs) or later. Update \(h.name) on \(host), then check again.",
                        symbol: "info.circle", color: .secondary)
        case .needsPython:
            return Note(text: "Its hooks need python3. Install Apple's Command Line Tools on \(host) (xcode-select --install), then check again.",
                        symbol: "info.circle", color: .secondary)
        case .offer:
            return nil
        case .installed:
            break
        }
        if integrations.justInstalled.contains(h) {
            switch h {
            case .pi:
                return Note(text: "New pi sessions load it; in a running one, /reload.", symbol: "checkmark.circle.fill", color: .green)
            case .claude:
                return Note(text: "New Claude Code sessions load it; in a running one, /reload-plugins.", symbol: "checkmark.circle.fill", color: .green)
            case .codex:
                return Note(text: "The next Codex you start asks to trust its hooks: choose Trust all. Running ones need a restart.",
                            symbol: "checkmark.circle.fill", color: .green)
            }
        }
        if h == .codex && !found.trusted {
            return Note(text: "Codex runs its hooks once you trust them: the next Codex you start asks (Trust all).",
                        symbol: "info.circle", color: .secondary)
        }
        if h == .pi && !found.old.isEmpty {
            let old = found.old.map { "npm:@wierdbytes/\($0)" }
            return Note(text: "pi-wierdr replaces \(found.old.joined(separator: " and ")): pi remove \(old.joined(separator: " "))",
                        symbol: "info.circle", color: .secondary)
        }
        return nil
    }

    /// The commands behind the offered installs, for a section's footer.
    @ViewBuilder var commandsFooter: some View {
        let offered = (integrations.status?.found ?? []).filter {
            if case .offer = $0.verdict { return integrations.working != $0.harness } else { return false }
        }
        if !offered.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wierdr runs this on \(host):")
                Text(offered.flatMap { $0.harness.commands($0.state) }.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

/// Signed in with a password: the button that installs this device's key on the host
/// (`AppModel.installKeyAndSwitch`), so the next connection needs none. Rows of the setup
/// sheet's Sign In section; Settings → Connection has the same button.
struct KeyInstallRows: View {
    var host: String
    @Environment(AppModel.self) private var app
    @State private var installing = false
    @State private var installed = false
    @State private var error: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if installed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                }
                Text(installed ? "This \(Device.kind)'s Key" : "Password")
            }
        } label: {
            Text("Signs In With")
        }
        if !installed {
            Button {
                install()
            } label: {
                HStack {
                    Label("Install This \(Device.kind)'s Key", systemImage: "key")
                    if installing { Spacer(); ProgressView() }
                }
            }
            .disabled(installing)
        }
        if let error {
            Label { Text(error).textSelection(.enabled) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func install() {
        installing = true
        error = nil
        Task {
            do {
                try await app.installKeyAndSwitch()
                installed = true
            } catch {
                self.error = error.localizedDescription
            }
            installing = false
        }
    }
}

/// After a host's first connection, when something there wants setting up (wierdrd not
/// running, an integration missing from a harness there), and after every sign-in with a
/// password (the key, on top): what each is, and its button. Settings has the same rows
/// for later (Connection, Daemon, Agent Integrations).
struct HostSetupSheet: View {
    var daemon: DaemonState
    var integrations: IntegrationsState
    var host: String
    /// This connection signed in with a password: the Sign In section (it stays once the
    /// key is in, to say so).
    var offersKey: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    var body: some View {
        let daemonRows = DaemonRows(daemon: daemon, host: host)
        let integrationRows = IntegrationRows(integrations: integrations, host: host)
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Set Up \(host)")
                            .font(.title2.bold())
                        Text("A few things on \(host) let Wierdr show more. Wierdr sets them up for you; under each section is what it runs there.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
                if offersKey {
                    Section {
                        KeyInstallRows(host: host)
                    } header: {
                        Text("Sign In")
                    } footer: {
                        Text("Wierdr asks for the password each time and doesn't keep it. With this \(Device.kind)'s key in ~/.ssh/authorized_keys on \(host), it signs in without one.")
                    }
                }
                Section {
                    daemonRows
                } header: {
                    Text("Daemon")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Wierdr needs the daemon for its extra features, such as push notifications.")
                        daemonRows.commandsFooter
                    }
                }
                Section {
                    integrationRows
                } header: {
                    Text("Agent Integrations")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("They show each agent's model, effort, context, sub-agents and subscription limits in Wierdr.")
                        integrationRows.commandsFooter
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(somethingOffered ? "Not Now" : "Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(daemon.isWorking || integrations.working != nil)
    }

    private var somethingOffered: Bool {
        app.signedInWithPassword || HostSetup.daemonWantsSetup(daemon.verdict) || integrations.status?.offers == true
    }
}

enum HostSetup {
    /// wierdrd wants the person: not installed, stopped, out of date, or no Homebrew.
    static func daemonWantsSetup(_ verdict: Daemon.Verdict?) -> Bool {
        switch verdict {
        case .offer?, .needsBrew?: return true
        default: return false
        }
    }
}

/// Shows `HostSetupSheet`: at once after a sign-in with a password (the key on top), every
/// time; and once per host after its first connection's checks, when wierdrd or an
/// integration there wants setting up. At most once per connection (this view lives as
/// long as the session: `WorkspaceView` is made anew for each).
struct SetupOffer: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(LiveConnector.self) private var connector
    @State private var shown = false
    /// Shown on this connection already (closed before the checks ended: not again).
    @State private var presented = false
    /// Read when this connection began: the key installed from the sheet keeps its section.
    @State private var withPassword: Bool?

    func body(content: Content) -> some View {
        content
            .onChange(of: checksDone, initial: true) { _, _ in consider() }
            .onChange(of: shown) { _, now in if now { presented = true } }
            .sheet(isPresented: $shown) {
                if let session = connector.active, case .live(let host) = app.mode {
                    HostSetupSheet(daemon: session.daemon, integrations: session.integrations, host: host.displayName,
                                   offersKey: withPassword ?? false)
                }
            }
    }

    private var checksDone: Bool {
        guard let s = connector.active else { return false }
        return s.daemon.firstCheckDone && s.integrations.firstCheckDone
    }

    static func key(_ host: Host.ID) -> String { "setup.checked.\(host.uuidString)" }

    private func consider() {
        guard case .live(let host) = app.mode, let session = connector.active else { return }
        if withPassword == nil { withPassword = host.auth == .password }
        // A password sign-in: the key, at once, every connection.
        if withPassword == true, !presented, !Tutorial.shared.isActive { shown = true }
        guard checksDone else { return }
        let daemon = HostSetup.daemonWantsSetup(session.daemon.verdict)
        let integrations = session.integrations.status?.offers == true
        // Nothing known yet (both probes failed): ask again on the next connection.
        guard session.daemon.verdict != nil || session.integrations.status != nil else { return }
        let key = Self.key(host.id)
        var always = false
        #if DEBUG
        // `-setup-offer always`: every connection (trying the sheet).
        always = UserDefaults.standard.string(forKey: "setup-offer") == "always"
        #endif
        guard always || !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard !presented, !Tutorial.shared.isActive, daemon || integrations || always else { return }
        shown = true
    }
}

extension View {
    /// The host setup sheet after a host's first connection (`SetupOffer`).
    func setupOffer() -> some View { modifier(SetupOffer()) }
}
