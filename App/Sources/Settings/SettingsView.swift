import SwiftUI

/// Native settings sheet: appearance, terminal font size, connection, about.
struct SettingsView: View {
    var hostName: String?
    var isDemo: Bool
    var onDisconnect: () -> Void

    @AppStorage("appearance") private var appearance: AppearanceOverride = .system
    @AppStorage(TerminalFonts.sizeKey) private var fontSize = Double(TerminalFonts.defaultSize)
    @AppStorage(ScrollCoast.enabledKey) private var scrollInertia = true
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Environment(LiveConnector.self) private var connector
    @State private var keyStatus: String?
    @State private var installing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppearanceOverride.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Dark", value: "Atom One Dark")
                    LabeledContent("Light", value: "Paper")
                }
                Section {
                    Stepper(value: $fontSize, in: Double(TerminalFonts.sizeRange.lowerBound)...Double(TerminalFonts.sizeRange.upperBound), step: 1) {
                        LabeledContent("Font Size", value: "\(Int(fontSize)) pt")
                    }
                    Text("The quick brown fox jumps over the lazy dog")
                        .font(.mono(fontSize))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Toggle("Scroll Inertia in Programs", isOn: $scrollInertia)
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("After a flick, scrolling in pi, Claude Code, vim or less keeps going and slows down. The shell’s history always does.")
                }
                Section("Connection") {
                    LabeledContent("Connected to", value: isDemo ? "Demo" : (hostName ?? "—"))
                    if case .live(let host) = app.mode, host.auth == .password {
                        Button {
                            installing = true
                            Task {
                                do {
                                    try await app.installKeyAndSwitch()
                                    keyStatus = "Key installed. Next time Wierdr logs in with it, no password needed."
                                } catch {
                                    keyStatus = error.localizedDescription
                                }
                                installing = false
                            }
                        } label: {
                            HStack {
                                Text("Install This \(Device.kind)\u{2019}s Key on \(host.displayName)")
                                if installing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(installing)
                    }
                    if let keyStatus { Text(keyStatus).font(.footnote).foregroundStyle(.secondary) }
                    Button(isDemo ? "Leave Demo" : "Disconnect", role: .destructive) {
                        dismiss()
                        onDisconnect()
                    }
                }
                if !isDemo, let session = connector.active {
                    DaemonSection(daemon: session.daemon, host: hostName ?? "this computer")
                    IntegrationsSection(integrations: session.integrations, host: hostName ?? "this computer")
                }
                Section {
                    Button("Take the Tour") {
                        dismiss()
                        Tutorial.shared.restart()
                    }
                } footer: {
                    Text(isDemo
                         ? "From the host list, on the demo: you try each thing yourself."
                         : "From the host list, on the demo: you try each thing yourself. It disconnects you from \(hostName ?? "this computer") for the time.")
                }
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    NavigationLink("Acknowledgements") { LicensesView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

/// Settings → Daemon: wierdrd on the connected computer (its state, and Install, Start or
/// Update with Homebrew: `DaemonRows`), and on the iPhone where the agents Live Activity
/// stands (registered with that computer, whose wierdrd drives it, or why not). More of
/// what wierdrd does will come here.
private struct DaemonSection: View {
    var daemon: DaemonState
    var host: String
    private var activities: LiveActivities { .shared }

    var body: some View {
        let rows = DaemonRows(daemon: daemon, host: host)
        Section {
            rows
            if Device.isPhone {
                switch activities.registration {
                case .registered(let host):
                    LabeledContent("Live Activity", value: "On \(host)")
                case .off:
                    LabeledContent("Live Activity", value: "Off")
                    Button("Turn On in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                case .waiting:
                    LabeledContent("Live Activity", value: "Waiting")
                case .failed(let message):
                    LabeledContent("Live Activity", value: "Not registered")
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Daemon")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Wierdr needs the daemon for its extra features, such as push notifications.")
                rows.commandsFooter
            }
        }
        .onAppear { if daemon.phase == .checked && !daemon.isWorking { daemon.check() } }
    }
}

/// Settings → Agent Integrations: the harnesses on the connected computer (pi, Claude Code,
/// Codex) and Wierdr's integration in each, with Install (`IntegrationRows`).
private struct IntegrationsSection: View {
    var integrations: IntegrationsState
    var host: String

    var body: some View {
        let rows = IntegrationRows(integrations: integrations, host: host)
        Section {
            rows
        } header: {
            Text("Agent Integrations")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("They show each agent's model, effort, context, sub-agents and subscription limits in Wierdr.")
                rows.commandsFooter
            }
        }
        .onAppear { if integrations.working == nil && !integrations.checking { integrations.check() } }
    }
}

/// Third-party notices (bundled fonts, icons).
struct LicensesView: View {
    private struct Entry: Identifiable {
        var id: String { name }
        var name: String
        var detail: String
        var file: String?
    }

    private let entries = [
        Entry(name: "Geist", detail: "SIL Open Font License 1.1", file: "OFL-Geist"),
        Entry(name: "JetBrains Mono", detail: "SIL Open Font License 1.1", file: "OFL-JetBrainsMono"),
        Entry(name: "Symbols Nerd Font", detail: "MIT License", file: "LICENSE-SymbolsNerdFont"),
        Entry(name: "Lucide icons", detail: "ISC License", file: nil),
        Entry(name: "LobeHub icons", detail: "MIT License", file: nil),
        Entry(name: "Simple Icons", detail: "CC0 1.0", file: nil),
        Entry(name: "SwiftTerm", detail: "MIT License", file: nil),
        Entry(name: "SwiftNIO, SwiftNIO SSH, swift-crypto", detail: "Apache License 2.0", file: nil),
    ]

    var body: some View {
        List(entries) { entry in
            if let file = entry.file, let url = Bundle.main.url(forResource: file, withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                NavigationLink {
                    ScrollView { Text(text).font(.footnote.monospaced()).padding() }
                        .navigationTitle(entry.name)
                } label: {
                    LabeledContent(entry.name, value: entry.detail)
                }
            } else {
                LabeledContent(entry.name, value: entry.detail)
            }
        }
        .navigationTitle("Acknowledgements")
    }
}
