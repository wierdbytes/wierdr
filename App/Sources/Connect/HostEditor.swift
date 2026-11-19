import SwiftUI

/// Add/edit a host (sheet).
struct HostEditor: View {
    @State var host: Host
    var isNew: Bool
    var onSave: (_ host: Host) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Computer") {
                    TextField("Name", text: $host.name, prompt: Text("My Mac"))
                    TextField("Address", text: $host.address, prompt: Text("mac.local or 192.168.1.10"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $portText, prompt: Text("22"))
                        .keyboardType(.numberPad)
                    TextField("User", text: $host.user, prompt: Text("mentor"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("Sign in with", selection: $host.auth) {
                        Text("Key").tag(Host.Auth.key)
                        Text("Password").tag(Host.Auth.password)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text(host.auth == .key
                         ? "Add this \(Device.kind)'s public key to ~/.ssh/authorized_keys on the computer."
                         : "Wierdr asks for the password each time it connects and doesn't keep it. Once connected, it can install this \(Device.kind)'s key there, so the next time needs none.")
                }

                if host.auth == .key {
                    PublicKeySection()
                }
            }
            .navigationTitle(isNew ? "New Host" : host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        host.port = Int(portText) ?? 22
                        host.address = host.address.trimmingCharacters(in: .whitespaces)
                        host.user = host.user.trimmingCharacters(in: .whitespaces)
                        onSave(host)
                        dismiss()
                    }
                    .disabled(host.address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { portText = host.port == 22 ? "" : String(host.port) }
        }
    }
}

/// "This iPad's key" ("This iPhone's key"): the public key with Copy and Share, or Generate.
private struct PublicKeySection: View {
    @Environment(\.services) private var services
    @State private var key: String?
    @State private var generating = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Section("This \(Device.kind)'s Key") {
            if let key {
                Text(key)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
                HStack {
                    Button {
                        UIPasteboard.general.string = key
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    ShareLink(item: key, subject: Text("Wierdr public key")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack {
                    Text(generating ? "Generating…" : "No key yet").foregroundStyle(.secondary)
                    Spacer()
                    if generating {
                        ProgressView()
                    } else {
                        Button("Generate") { generate() }
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .onAppear { key = services.publicKey() }
    }

    private func generate() {
        generating = true
        error = nil
        Task {
            do { key = try await services.generateKey() } catch { self.error = error.localizedDescription }
            generating = false
        }
    }
}
