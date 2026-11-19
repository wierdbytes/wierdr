import Foundation
import Observation
import HerdrCore
import WierdrModel

/// The agent harnesses on the connected computer and Wierdr's integrations in them, as this
/// session knows them (`Integrations` in WierdrModel: the probe through the login shell's
/// PATH, the harnesses' own install commands, through herdr-core's `machine.exec`). Checked
/// each time the connection goes live; installed from the setup sheet or Settings.
@MainActor
@Observable
final class IntegrationsState {
    /// The last probe's (kept while installing, and when a probe fails).
    private(set) var status: Integrations.Status?
    private(set) var checking = false
    /// The harness whose integration is being installed (one at a time: npm, git).
    private(set) var working: Integrations.Harness?
    /// Why the probe failed.
    private(set) var error: String?
    /// Why an install failed, per harness.
    private(set) var failures: [Integrations.Harness: String] = [:]
    /// Installed (or enabled) from here on this session: says how it takes effect.
    private(set) var justInstalled: Set<Integrations.Harness> = []
    private(set) var firstCheckDone = false

    @ObservationIgnored private var core: CoreConnection?
    @ObservationIgnored private var generation = 0

    func connected(_ core: CoreConnection) {
        self.core = core
        check()
    }

    func disconnected() {
        core = nil
        generation += 1
        working = nil
        checking = false
    }

    func check() {
        guard let core, working == nil else { return }
        generation += 1
        let g = generation
        checking = true
        Task {
            do {
                let s = try await Integrations.probe(on: core)
                guard g == generation else { return }
                status = s
                error = nil
            } catch {
                guard g == generation else { return }
                self.error = HostSession.describe(error)
            }
            checking = false
            firstCheckDone = true
        }
    }

    /// Installs the integration in `harness`, then checks again.
    func install(_ harness: Integrations.Harness) {
        guard let core, working == nil, let found = status?[harness] else { return }
        generation += 1
        let g = generation
        working = harness
        failures[harness] = nil
        Task {
            do {
                try await Integrations.perform(for: found, on: core)
                let s = try await Integrations.probe(on: core)
                guard g == generation else { return }
                status = s
                if s[harness]?.state == .installed {
                    justInstalled.insert(harness)
                } else {
                    failures[harness] = "\(harness.name) finished, but \(harness.integration) isn't in."
                }
            } catch {
                guard g == generation else { return }
                failures[harness] = HostSession.describe(error)
            }
            working = nil
        }
    }
}
