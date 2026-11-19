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
            HStack(spacing: 8) {
                if busy { ProgressView() }
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
        if daemon.justSetUp, daemon.verdict == .running {
            return Note(text: "wierdrd runs on \(host). It starts again at login.", symbol: "checkmark.circle.fill", color: .green)
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

/// After the first connection to a host whose wierdrd isn't running: what it is and the
/// button that sets it up. Settings → Daemon has the same rows for later.
struct DaemonSetupSheet: View {
    var daemon: DaemonState
    var host: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rows = DaemonRows(daemon: daemon, host: host)
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Set Up wierdrd")
                            .font(.title2.bold())
                        Text("wierdrd is Wierdr's helper on \(host). It runs in the background and sends your agents to the iPhone's Lock Screen and Dynamic Island, even while Wierdr is closed.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
                Section {
                    rows
                } footer: {
                    rows.commandsFooter
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if daemon.verdict != .running { Button("Not Now") { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if daemon.verdict == .running { Button("Done") { dismiss() } }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(daemon.isWorking)
    }
}

/// Shows `DaemonSetupSheet` once per host: after its first connection, when wierdrd
/// there wants setting up (not installed, stopped, out of date, or no Homebrew).
struct DaemonOffer: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(LiveConnector.self) private var connector
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onChange(of: connector.active?.daemon.firstCheckDone, initial: true) { _, _ in consider() }
            .sheet(isPresented: $shown) {
                if let daemon = connector.active?.daemon, case .live(let host) = app.mode {
                    DaemonSetupSheet(daemon: daemon, host: host.displayName)
                }
            }
    }

    static func key(_ host: Host.ID) -> String { "daemon.checked.\(host.uuidString)" }

    private func consider() {
        guard case .live(let host) = app.mode, let daemon = connector.active?.daemon, daemon.firstCheckDone,
              let verdict = daemon.verdict else { return }
        let key = Self.key(host.id)
        var always = false
        #if DEBUG
        // `-daemon-offer always`: every connection (trying the sheet).
        always = UserDefaults.standard.string(forKey: "daemon-offer") == "always"
        #endif
        guard always || !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard !Tutorial.shared.isActive else { return }
        switch verdict {
        case .offer, .needsBrew: shown = true
        case .running, .unsupported, .stoppedOutsideBrew: break
        }
    }
}

extension View {
    /// The wierdrd setup sheet after a host's first connection (`DaemonOffer`).
    func daemonOffer() -> some View { modifier(DaemonOffer()) }
}
