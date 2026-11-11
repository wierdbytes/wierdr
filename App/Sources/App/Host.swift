import Foundation
import Observation

/// A computer running herdr-core that Wierdr connects to over SSH.
struct Host: Identifiable, Codable, Hashable, Sendable {
    enum Auth: String, Codable, Hashable, Sendable, CaseIterable {
        /// This iPad's Ed25519 key (generated on device, kept in the Keychain by HerdrSSH).
        case key
        /// A password (kept in the Keychain; never in hosts.json).
        case password
    }

    var id: UUID = UUID()
    var name: String = ""
    var address: String = ""
    var port: Int = 22
    var user: String = ""
    var auth: Auth = .key

    /// `user@address` (`:port` when not 22).
    var target: String {
        let base = user.isEmpty ? address : "\(user)@\(address)"
        return port == 22 ? base : "\(base):\(port)"
    }

    var displayName: String { name.isEmpty ? address : name }
}

/// Saved hosts, persisted as JSON in Application Support (`hosts.json`).
@MainActor
@Observable
final class HostStore {
    private(set) var hosts: [Host] = []
    @ObservationIgnored private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.url = dir.appendingPathComponent("hosts.json")
        }
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        hosts = (try? JSONDecoder().decode([Host].self, from: data)) ?? []
    }

    func save(_ host: Host) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host } else { hosts.append(host) }
        persist()
    }

    func delete(_ id: Host.ID) {
        hosts.removeAll { $0.id == id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        hosts.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hosts) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
