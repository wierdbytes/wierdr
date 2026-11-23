import SwiftUI

/// The start screen: saved hosts, add/edit/delete, connect, demo.
struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: Host?
    @State private var deleting: Host?
    /// What's typed into the password prompt (cleared as it goes).
    @State private var password = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                .listRowBackground(Color.clear)

                if let error = app.connectionError {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Couldn't connect").font(.headline)
                                Text(error).font(.subheadline).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        HStack {
                            Button("Retry") { Task { await app.retry() } }
                                .buttonStyle(.borderedProminent)
                            Button("Dismiss") { app.connectionError = nil }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                Section {
                    if app.hosts.hosts.isEmpty {
                        Text("Add the computer that runs Herdr. Wierdr connects to it over SSH and runs `hc connect` there.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(app.hosts.hosts) { host in
                        HostRow(host: host, connecting: app.connecting == host.id, busy: app.connecting != nil) {
                            Task { await app.connect(to: host) }
                        }
                        .contextMenu {
                            Button { editing = host } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { deleting = host } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions {
                            Button(role: .destructive) { deleting = host } label: { Label("Delete", systemImage: "trash") }
                            Button { editing = host } label: { Label("Edit", systemImage: "pencil") }
                        }
                    }
                    .onMove { app.hosts.move(from: $0, to: $1) }
                    Button {
                        editing = Host()
                    } label: {
                        Label("Add Host", systemImage: "plus")
                            // The row's width: what the tour points at.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .tutorialAnchor(.addHost)
                } header: {
                    Text("Hosts")
                }

                Section {
                    Button {
                        app.startDemo()
                    } label: {
                        Label("Try the Demo", systemImage: "play.rectangle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .disabled(app.connecting != nil)
                    .tutorialAnchor(.tryDemo)
                    Button {
                        Tutorial.shared.start()
                    } label: {
                        Label("Take the Tour", systemImage: "hand.point.up.left")
                    }
                    .disabled(app.connecting != nil || Tutorial.shared.isActive)
                } footer: {
                    Text("Explore Wierdr with sample spaces and agents, no computer needed. The tour shows you around on them.")
                }
            }
            .listStyle(.insetGrouped)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = Host() } label: { Label("Add Host", systemImage: "plus") }
                        .keyboardShortcut("n", modifiers: .command)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !app.hosts.hosts.isEmpty { EditButton() }
                }
            }
            .sheet(item: $editing) { host in
                HostEditor(host: host, isNew: !app.hosts.hosts.contains { $0.id == host.id }) { saved in
                    app.save(saved)
                }
            }
            .onChange(of: app.addHostRequested, initial: true) { _, requested in
                guard requested else { return }
                app.addHostRequested = false
                editing = Host()
            }
            // A password host: asked for each connection, never kept.
            .alert("Password for \(app.passwordRequest?.target ?? "")", isPresented: passwordShown, presenting: app.passwordRequest) { host in
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button("Cancel", role: .cancel) { password = "" }
                Button("Connect") {
                    let typed = password
                    password = ""
                    Task { await app.connect(to: host, password: typed) }
                }
            } message: { _ in
                Text("Wierdr doesn't keep it: it asks each time it connects.")
            }
            .confirmationDialog("Delete \u{201C}\(deleting?.displayName ?? "")\u{201D}?", isPresented: deleteShown, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let h = deleting { app.delete(h) } }
            } message: {
                Text("Its screen layout is removed from this \(Device.kind).")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .accessibilityHidden(true)
            Text("Wierdr")
                .font(.largeTitle.bold())
            Text("Your Herdr spaces, tabs and agents on \(Device.kind).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var passwordShown: Binding<Bool> {
        Binding(get: { app.passwordRequest != nil }, set: { if !$0 { app.passwordRequest = nil } })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

private struct HostRow: View {
    var host: Host
    var connecting: Bool
    var busy: Bool
    var connect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(.body.weight(.medium))
                Text(host.target)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.8)
            }
            Spacer()
            if connecting {
                ProgressView().padding(.trailing, 8)
                Text("Connecting…").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Connect", connect)
    }
}
