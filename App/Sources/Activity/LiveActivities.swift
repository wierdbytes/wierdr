import ActivityKit
import Foundation
import HerdrCore
import Observation
import UIKit
import WierdrActivity

/// The app's part in the agents Live Activity, which `wierdr-push` on the Mac
/// starts, updates and ends through APNs: this device's push-to-start token goes
/// into the connected computer's `wierdr-push` document (`PushRegistry`) each time
/// a session goes live and whenever the token or the person's Live Activities
/// setting changes; a second activity (a start that crossed an end) is ended.
@MainActor
@Observable
final class LiveActivities {
    static let shared = LiveActivities()

    enum Registration: Equatable {
        /// Not connected yet, or no token yet.
        case waiting
        /// Live Activities are off for Wierdr (Settings) or not on this device.
        case off
        case registered(host: String)
        case failed(String)
    }

    private(set) var registration: Registration = .waiting
    /// Push-to-start token, hex (nil until ActivityKit hands one out).
    private(set) var token: String?
    private(set) var enabled = ActivityAuthorizationInfo().areActivitiesEnabled

    @ObservationIgnored private var core: CoreConnection?
    @ObservationIgnored private var host: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var publishing: Task<Void, Never>?

    private init() {}

    /// Starts listening for tokens, the setting and activities (once, at launch).
    func start() {
        // iPadOS shows no Live Activities of apps like this one.
        guard !started, UIDevice.current.userInterfaceIdiom == .phone else { return }
        started = true
        Task { [weak self] in
            for await data in Activity<AgentsActivityAttributes>.pushToStartTokenUpdates {
                guard let self else { return }
                self.token = data.hexString
                self.publish()
            }
        }
        Task { [weak self] in
            for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
                guard let self else { return }
                self.enabled = enabled
                self.publish()
            }
        }
        Task { [weak self] in
            for await _ in Activity<AgentsActivityAttributes>.activityUpdates { self?.tidy() }
        }
        tidy()
    }

    /// A session went live on `host`: register there.
    func connected(_ core: CoreConnection, host: String) {
        guard started else { return }
        self.core = core
        self.host = host
        publish()
    }

    /// The session closed: nothing to write to until the next one.
    func disconnected() {
        publishing?.cancel()
        core = nil
        host = nil
        if case .registered = registration { return }
        registration = .waiting
    }

    /// Writes (or removes) this device's entry in the connected computer's
    /// `wierdr-push` document; compare-and-swap, a few tries.
    private func publish() {
        guard let core, let host else { return }
        guard let id = UIDevice.current.identifierForVendor?.uuidString else { return }
        let entry: PushRegistry.Device? = enabled ? token.map {
            PushRegistry.Device(name: UIDevice.current.name, bundle: Bundle.main.bundleIdentifier ?? "pw.xff.wierdr",
                                env: Self.apnsEnvironment, startToken: $0, updated: Date().timeIntervalSince1970)
        } : nil
        if enabled && entry == nil { registration = .waiting; return }
        publishing?.cancel()
        publishing = Task { [weak self] in
            do {
                try await Self.write(entry, id: id, on: core)
                guard !Task.isCancelled else { return }
                self?.registration = entry == nil ? .off : .registered(host: host)
            } catch {
                guard !Task.isCancelled else { return }
                self?.registration = .failed(error.localizedDescription)
            }
        }
    }

    private static func write(_ entry: PushRegistry.Device?, id: String, on core: CoreConnection) async throws {
        for _ in 0..<5 {
            let doc = try await core.getDoc(PushRegistry.documentName)
            var registry = doc.value == .null ? PushRegistry() : PushRegistry.decode(try doc.value.data())
            if let entry, let old = registry.devices[id], old.same(as: entry) { return }
            if entry == nil && registry.devices[id] == nil { return }
            registry.devices[id] = entry
            do {
                try await core.setDoc(PushRegistry.documentName, value: try JSONValue(data: registry.encoded()),
                                      version: doc.version)
                return
            } catch is DocConflict {
                try await Task.sleep(for: .milliseconds(Int.random(in: 100...400)))
            }
        }
        throw SessionError.failed("The \(PushRegistry.documentName) document kept changing")
    }

    /// One activity at a time: older ones go at once.
    private func tidy() {
        let live = Activity<AgentsActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        for old in live.dropLast() {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The APNs environment of this build's signature (`aps-environment` in the
    /// embedded profile): `development` for Xcode and ad-hoc debugging builds.
    static let apnsEnvironment: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)
                as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let env = entitlements["aps-environment"] as? String else { return "development" }
        return env
    }()
}

extension AppModel {
    /// A tap on an agent in the Live Activity (`wierdr://agent?t=…`): its pane, once
    /// the workspace has it (a cold start connects first; gives up after 15 s).
    func openAgent(_ address: String) async {
        for _ in 0..<150 {
            if let s = session, let at = s.workspace.pane(showing: address) {
                s.focus(pane: at.pane.id)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
