#if DEBUG
import ActivityKit
import Foundation
import WierdrActivity

/// `-live-activity-demo YES` (DEBUG): starts the agents Live Activity locally with
/// sample agents, to look at it in the simulator without `wierdrd` and APNs.
/// `-live-activity-demo end` ends every one.
@MainActor
enum LiveActivityDemo {
    static func run() async {
        guard let mode = UserDefaults.standard.string(forKey: "live-activity-demo") else { return }
        for a in Activity<AgentsActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        guard mode != "end" else { return }
        let now = Date().timeIntervalSince1970
        typealias Agent = AgentsActivityAttributes.Agent
        let state = AgentsActivityAttributes.ContentState(
            blocked: 1, done: 1, working: 3, idle: 2,
            agents: [
                Agent(id: "t5w", title: "Allow `rm -rf build`?", space: "wierdr", spaceColor: "#22a99a",
                      status: .blocked, since: now - 95, model: "Opus 5.5", icon: "program.claude", tint: false),
                Agent(id: "t1t", title: "Live Activity for agents", space: "wierdr", spaceColor: "#22a99a",
                      status: .done, since: now - 300, model: "Opus 5.5", icon: "program.pi"),
                Agent(id: "t2m", title: "Refactor the sidebar rows", space: "herdr-app", spaceColor: "#c678dd",
                      status: .working, since: now - (3 * 86_400 + 4 * 3600), model: "GPT-6.1", icon: "program.codex", tint: false),
                Agent(id: "lf/t1", title: "Nightly backup check", space: "infra", spaceColor: "#e5c07b",
                      machine: "lf", status: .working, since: now - 42, model: "Sonnet 5", icon: "program.claude",
                      tint: false),
                Agent(id: "t41", title: "cv", space: "cv", status: .working, since: now - 3700, model: "Opus 5.5",
                      icon: "program.pi"),
            ],
            at: now)
        do {
            _ = try Activity.request(attributes: AgentsActivityAttributes(host: "mentoair"),
                                     content: .init(state: state, staleDate: nil), pushType: nil)
        } catch {
            print("[debug] live activity: \(error)")
        }
    }
}
#endif
