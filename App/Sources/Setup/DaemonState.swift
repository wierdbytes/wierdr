import Foundation
import Observation
import HerdrCore
import WierdrModel

/// wierdrd on the connected computer, as this session knows it (`Daemon` in WierdrModel:
/// the probe and the Homebrew actions, through herdr-core's `machine.exec`). Checked each
/// time the connection goes live; set up from the sheet after the first connection to a
/// host (`SetupOffer`, `HostSetupSheet`) or from Settings → Daemon. See docs/wierdrd.md.
@MainActor
@Observable
final class DaemonState {
    enum Phase: Equatable {
        case checking
        case checked
        case working(Daemon.Action)
    }

    private(set) var phase: Phase = .checking
    /// The last probe's (kept while an action runs, and when a probe fails).
    private(set) var status: Daemon.Status?
    /// Why the last probe or action failed, for the person.
    private(set) var error: String?
    /// The last action went through and wierdrd runs.
    private(set) var justSetUp = false
    /// The first probe on this session is done (successfully or not).
    private(set) var firstCheckDone = false

    @ObservationIgnored private var core: CoreConnection?
    @ObservationIgnored private var generation = 0

    var verdict: Daemon.Verdict? { status?.verdict }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    /// A connection went live: check there.
    func connected(_ core: CoreConnection) {
        self.core = core
        check()
    }

    func disconnected() {
        core = nil
        generation += 1
        if isWorking { phase = .checked }
    }

    /// Probes again (Check Again; each new connection).
    func check() {
        guard let core, !isWorking else { return }
        generation += 1
        let g = generation
        phase = .checking
        Task {
            do {
                let s = try await Daemon.probe(on: core)
                guard g == generation else { return }
                status = s
                error = nil
                if s.running == false { justSetUp = false }
            } catch {
                guard g == generation else { return }
                self.error = HostSession.describe(error)
            }
            phase = .checked
            firstCheckDone = true
        }
    }

    /// Runs `action` with Homebrew there, then checks until wierdrd runs (its service takes
    /// a moment to start) or says why it doesn't.
    func perform(_ action: Daemon.Action) {
        guard let core, let brew = status?.brew, !isWorking else { return }
        generation += 1
        let g = generation
        phase = .working(action)
        error = nil
        justSetUp = false
        Task {
            do {
                try await Daemon.perform(action, brew: brew, on: core)
                var s = try await Daemon.probe(on: core)
                for _ in 0..<10 where !s.running {
                    try await Task.sleep(for: .milliseconds(500))
                    s = try await Daemon.probe(on: core)
                }
                guard g == generation else { return }
                status = s
                if s.running {
                    justSetUp = true
                } else {
                    error = "Homebrew finished, but wierdrd isn't running"
                        + (s.lastExit.flatMap(Int.init).map { " (it exited with \($0))" } ?? "")
                        + (s.lastLog.map { ": \($0)" } ?? ".")
                }
            } catch {
                guard g == generation else { return }
                self.error = HostSession.describe(error)
            }
            phase = .checked
        }
    }
}
