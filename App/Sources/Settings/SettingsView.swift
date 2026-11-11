import SwiftUI

/// Native settings sheet: appearance, terminal font size, connection, about.
struct SettingsView: View {
    var hostName: String?
    var isDemo: Bool
    var onDisconnect: () -> Void

    @AppStorage("appearance") private var appearance: AppearanceOverride = .system
    @AppStorage("terminalFontSize") private var fontSize: Double = 14
    @Environment(\.dismiss) private var dismiss

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
                Section("Terminal") {
                    Stepper(value: $fontSize, in: 9...24, step: 1) {
                        LabeledContent("Font Size", value: "\(Int(fontSize)) pt")
                    }
                    Text("The quick brown fox jumps over the lazy dog")
                        .font(.mono(fontSize))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Section("Connection") {
                    LabeledContent("Connected to", value: isDemo ? "Demo" : (hostName ?? "—"))
                    Button(isDemo ? "Leave Demo" : "Disconnect", role: .destructive) {
                        dismiss()
                        onDisconnect()
                    }
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
