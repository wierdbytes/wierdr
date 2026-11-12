import Crypto
import Foundation
import Testing
@testable import WierdrPush
import WierdrActivity
import WierdrModel

typealias State = AgentsActivityAttributes.ContentState
typealias Agent = AgentsActivityAttributes.Agent

private func agent(_ id: String, _ status: AgentStatusWord, title: String? = nil) -> Agent {
    Agent(id: id, title: title ?? "task \(id)", space: "wierdr", status: status, since: 1_700_000_000,
          model: "Opus 5.5", icon: "program.claude")
}

private func state(_ agents: [Agent], idle: Int = 0) -> State {
    State(blocked: agents.filter { $0.status == .blocked }.count, done: agents.filter { $0.status == .done }.count,
          working: agents.filter { $0.status == .working }.count, idle: idle, agents: agents, at: 0)
}

private let phone = PushRegistry.Device(name: "iPhone", bundle: "pw.xff.wierdr", env: "development",
                                        startToken: "aa11", updated: 0)
private let lane = Lane(bundle: "pw.xff.wierdr", env: .development)
private let channels = [lane.key: "CHAN=="]

@Suite struct PlannerTests {
    func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + s) }

    @Test func startsWhenAnAgentWorksAndOnlyWithAChannel() {
        var p = Planner()
        let working = state([agent("t1", .working)])
        #expect(p.step(now: at(0), summary: state([], idle: 2), host: "mac", devices: ["d": phone], channels: channels) == [])
        #expect(p.step(now: at(1), summary: working, host: "mac", devices: ["d": phone], channels: [:]) == [])
        let actions = p.step(now: at(2), summary: working, host: "mac", devices: ["d": phone], channels: channels)
        guard case let .start(l, channel, device, token, s, alert)? = actions.first, actions.count == 1 else {
            Issue.record("\(actions)"); return
        }
        #expect(l == lane); #expect(channel == "CHAN=="); #expect(device == "d")
        #expect(token == "aa11"); #expect(s == working)
        #expect(alert == .init(title: "mac", body: "1 working", sound: false))
        // Nothing new: nothing to send.
        #expect(p.step(now: at(3), summary: working, host: "mac", devices: ["d": phone], channels: channels) == [])
    }

    @Test func statusChangesGoAtOnceOtherChangesAreCoalesced() {
        var p = Planner()
        _ = p.step(now: at(0), summary: state([agent("t1", .working)]), host: "mac", devices: ["d": phone], channels: channels)
        let two = state([agent("t1", .working), agent("t2", .working)])
        #expect(p.step(now: at(1), summary: two, host: "mac", devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: two, priority: 10, alert: nil)])
        let renamed = state([agent("t1", .working, title: "Renamed"), agent("t2", .working)])
        #expect(p.step(now: at(2), summary: renamed, host: "mac", devices: ["d": phone], channels: channels) == [],
                "a title only: within minInterval, wait")
        #expect(p.step(now: at(6), summary: renamed, host: "mac", devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: renamed, priority: 5, alert: nil)])
        let blocked = state([agent("t2", .blocked, title: "Allow rm?"), agent("t1", .working, title: "Renamed")])
        #expect(p.step(now: at(7), summary: blocked, host: "mac", devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: blocked, priority: 10,
                            alert: .init(title: "Needs you", body: "Allow rm? — wierdr", sound: true))])
        let done = state([agent("t2", .blocked, title: "Allow rm?"), agent("t1", .done, title: "Fix it")])
        #expect(p.step(now: at(8), summary: done, host: "mac", devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: done, priority: 10,
                            alert: .init(title: "Done", body: "Fix it — wierdr", sound: false))])
    }

    @Test func shownAgesAreRefreshedOnceAMinute() {
        var p = Planner()
        var a = agent("t1", .working)
        a.since = at(0).timeIntervalSince1970
        let s = state([a])
        _ = p.step(now: at(0), summary: s, host: "mac", devices: ["d": phone], channels: channels)
        #expect(p.step(now: at(59), summary: s, host: "mac", devices: ["d": phone], channels: channels) == [], "0s…59s")
        #expect(p.step(now: at(60), summary: s, host: "mac", devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: s, priority: 5, alert: nil)], "1m")
        #expect(p.step(now: at(100), summary: s, host: "mac", devices: ["d": phone], channels: channels) == [])
        #expect(p.step(now: at(120), summary: s, host: "mac", devices: ["d": phone], channels: channels).count == 1, "2m")
    }

    @Test func aStartForDoneAgentsOnlyWaitsAMoment() {
        var p = Planner()
        let done = state([agent("t1", .done)])
        #expect(p.step(now: at(0), summary: done, host: "mac", devices: ["d": phone], channels: channels) == [])
        // Looked at elsewhere right away: nothing started.
        #expect(p.step(now: at(2), summary: state([], idle: 1), host: "mac", devices: ["d": phone], channels: channels) == [])
        #expect(p.step(now: at(3), summary: done, host: "mac", devices: ["d": phone], channels: channels) == [])
        let started = p.step(now: at(8), summary: done, host: "mac", devices: ["d": phone], channels: channels)
        guard case .start? = started.first else { Issue.record("\(started)"); return }
        // A working agent starts at once.
        var q = Planner()
        #expect(q.step(now: at(0), summary: state([agent("t1", .working)]), host: "mac", devices: ["d": phone],
                       channels: channels).count == 1)
    }

    @Test func heartbeatMovesTheStaleDate() {
        var p = Planner()
        let s = state([agent("t1", .working)])
        _ = p.step(now: at(0), summary: s, host: "mac", devices: ["d": phone], channels: channels)
        #expect(p.step(now: at(599), summary: s, host: "mac", devices: ["d": phone], channels: channels) == [])
        #expect(p.step(now: at(600), summary: s, host: "mac", devices: ["d": phone], channels: channels).count == 1)
    }

    @Test func showsNothingActiveAtOnceAndEndsAfterTwoHours() {
        var p = Planner()
        let wait = p.settings.endDelay
        #expect(wait == 2 * 3600)
        _ = p.step(now: at(0), summary: state([agent("t1", .working)]), host: "mac", devices: ["d": phone], channels: channels)
        _ = p.step(now: at(10), summary: state([agent("t1", .done)]), host: "mac", devices: ["d": phone], channels: channels)
        // Seen on another client: the devices show it at once (priority 10)…
        let idle = state([], idle: 1)
        #expect(p.step(now: at(20), summary: idle, host: "mac", devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: idle, priority: 10, alert: nil)])
        #expect(p.step(now: at(30), summary: idle, host: "mac", devices: ["d": phone], channels: channels) == [])
        // …an agent set to work within the hold is an update, no start (no alert, no buzz).
        let working = state([agent("t1", .working)])
        #expect(p.step(now: at(1800), summary: working, host: "mac", devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: working, priority: 10, alert: nil)])
        _ = p.step(now: at(1900), summary: idle, host: "mac", devices: ["d": phone], channels: channels)
        #expect(p.step(now: at(1900 + wait - 1), summary: idle, host: "mac", devices: ["d": phone],
                       channels: channels).allSatisfy { if case .end = $0 { false } else { true } })
        #expect(p.step(now: at(1900 + wait), summary: idle, host: "mac", devices: ["d": phone], channels: channels)
                == [.end(lane: lane, channel: "CHAN==", state: idle)])
        #expect(p.running.isEmpty)
    }

    @Test func anIdleActivityNearEightHoursJustEnds() {
        var p = Planner()
        _ = p.step(now: at(0), summary: state([agent("t1", .working)]), host: "mac", devices: ["d": phone], channels: channels)
        let idle = state([], idle: 1)
        _ = p.step(now: at(7 * 3600), summary: idle, host: "mac", devices: ["d": phone], channels: channels)
        #expect(p.step(now: at(7.75 * 3600), summary: idle, host: "mac", devices: ["d": phone],
                       channels: [lane.key: "NEW=="]) == [.end(lane: lane, channel: "CHAN==", state: idle)])
        #expect(p.running.isEmpty)
    }

    @Test func aNewDeviceJoinsAndAGoneOneEndsIt() {
        var p = Planner()
        let s = state([agent("t1", .working)])
        _ = p.step(now: at(0), summary: s, host: "mac", devices: ["d": phone], channels: channels)
        var pad = phone
        pad.startToken = "bb22"
        let actions = p.step(now: at(1), summary: s, host: "mac", devices: ["d": phone, "e": pad], channels: channels)
        #expect(actions == [.start(lane: lane, channel: "CHAN==", device: "e", token: "bb22", state: s,
                                        alert: .init(title: "mac", body: "1 working", sound: false))])
        #expect(p.step(now: at(2), summary: s, host: "mac", devices: [:], channels: channels) == [.end(lane: lane, channel: "CHAN==", state: s)])
    }

    @Test func startsAgainOnADeviceThatLostIt() {
        var p = Planner()
        let s = state([agent("t1", .working)])
        _ = p.step(now: at(0), summary: s, host: "mac", devices: ["d": phone], channels: channels)
        var gone = phone
        gone.hasActivity = false
        // Written while the start was on its way: not yet.
        gone.updated = at(5).timeIntervalSince1970
        #expect(p.step(now: at(6), summary: s, host: "mac", devices: ["d": gone], channels: channels).isEmpty)
        // Written well after it: start it there again, once.
        gone.updated = at(60).timeIntervalSince1970
        #expect(p.step(now: at(61), summary: s, host: "mac", devices: ["d": gone], channels: channels)
                == [.start(lane: lane, channel: "CHAN==", device: "d", token: "aa11", state: s,
                           alert: .init(title: "mac", body: "1 working", sound: false))])
        #expect(p.step(now: at(62), summary: s, host: "mac", devices: ["d": gone], channels: channels).isEmpty)
        // It's there now.
        gone.hasActivity = true
        gone.updated = at(70).timeIntervalSince1970
        #expect(p.step(now: at(71), summary: s, host: "mac", devices: ["d": gone], channels: channels).isEmpty)
    }

    @Test func restartsBeforeEightHours() {
        var p = Planner()
        let s = state([agent("t1", .working)])
        _ = p.step(now: at(0), summary: s, host: "mac", devices: ["d": phone], channels: channels)
        // No fresh channel yet: it goes on (a heartbeat), the restart waits.
        #expect(p.step(now: at(7.75 * 3600), summary: s, host: "mac", devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: s, priority: 5, alert: nil)])
        let actions = p.step(now: at(7.75 * 3600), summary: s, host: "mac", devices: ["d": phone],
                             channels: [lane.key: "NEW=="])
        #expect(actions.count == 2)
        guard case let .end(_, old, _) = actions[0], case let .start(_, new, _, _, _, _) = actions[1] else {
            Issue.record("\(actions)"); return
        }
        #expect(old == "CHAN==")
        #expect(new == "NEW==")
        #expect(p.running[lane.key]?.startedAt == at(7.75 * 3600).timeIntervalSince1970)
    }

    @Test func aFailedUpdateIsSentAgain() {
        var p = Planner()
        let s = state([agent("t1", .working)])
        _ = p.step(now: at(0), summary: s, host: "mac", devices: ["d": phone], channels: channels)
        p.resend(lane: lane)
        #expect(p.step(now: at(10), summary: s, host: "mac", devices: ["d": phone], channels: channels) == [.update(lane: lane, channel: "CHAN==", state: s, priority: 5, alert: nil)])
    }
}

@Suite struct PayloadTests {
    @Test func startPayloadDecodesAsActivityKitWould() throws {
        let s = state([agent("lf/t1", .blocked, title: "Allow rm?"), agent("t2", .working)], idle: 3)
        let data = ActivityPayload.start(attributes: .init(host: "mentoair"), state: s, channel: "CHAN==",
                                         alert: .init(title: "mentoair", body: "1 needs you", sound: true),
                                         stale: Date(timeIntervalSince1970: 2000), now: Date(timeIntervalSince1970: 1000))
        let aps = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["aps"] as? [String: Any])
        #expect(aps["event"] as? String == "start")
        #expect(aps["timestamp"] as? Int == 1000)
        #expect(aps["stale-date"] as? Int == 2000)
        #expect(aps["input-push-channel"] as? String == "CHAN==")
        #expect(aps["attributes-type"] as? String == "AgentsActivityAttributes")
        #expect((aps["alert"] as? [String: Any])?["sound"] as? String == "default")
        #expect(aps["input-push-token"] == nil)
        let state = try JSONSerialization.data(withJSONObject: aps["content-state"]!)
        #expect(try JSONDecoder().decode(State.self, from: state) == s)
        let attrs = try JSONSerialization.data(withJSONObject: aps["attributes"]!)
        #expect(try JSONDecoder().decode(AgentsActivityAttributes.self, from: attrs).host == "mentoair")
    }

    @Test func fittingKeepsPushesSmall() {
        let long = String(repeating: "x", count: 900)
        let s = state((0..<5).map { agent("t\($0)", .working, title: long) })
        let fit = ActivityPayload.fitting(s)
        #expect(fit.agents.count < 5)
        #expect(fit.working == 5, "counts stay")
        let data = ActivityPayload.update(state: fit, alert: nil, stale: Date(), now: Date())
        #expect(data.count < 4096)
    }
}

@Suite struct SignerTests {
    @Test func jWTIsSignedWithTheKey() throws {
        let key = P256.Signing.PrivateKey()
        let signer = try APNsSigner(p8: key.pemRepresentation, keyID: "KEY123", teamID: "TEAM456")
        let token = signer.token(now: Date(timeIntervalSince1970: 1_700_000_000))
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        func decode(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)!
        }
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: String]
        #expect(header == ["alg": "ES256", "kid": "KEY123"])
        let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any]
        #expect(claims?["iss"] as? String == "TEAM456")
        #expect(claims?["iat"] as? Int == 1_700_000_000)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        #expect(key.publicKey.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8)))
        // Reused within the hour.
        #expect(signer.token(now: Date(timeIntervalSince1970: 1_700_000_000 + 600)) == token)
    }
}

@Suite struct SummaryTests {
    @Test func inboxBecomesCountsAndUrgentRows() {
        let claude = Program(key: "claude", name: "Claude Code", iconAsset: "program.claude", tint: false, isAgent: true)
        func term(_ a: String, _ s: AgentStatus, msg: String? = nil) -> TerminalInfo {
            TerminalInfo(address: a, program: claude, status: s, message: msg,
                         statusChangedAt: Date(timeIntervalSince1970: 1_700_000_000.4))
        }
        let space = Space(id: "sp1", machine: nil, name: "", displayName: "wierdr", folder: "/x", tabs: [], color: "#123456")
        func item(_ t: TerminalInfo) -> InboxItem {
            InboxItem(row: SidebarRow(kind: .agent, paneID: "p" + t.address, tabID: "tb1", terminal: t), space: space)
        }
        let inbox = [
            InboxGroup(status: .blocked, items: [item(term("t1", .blocked, msg: "• Allow rm?"))]),
            InboxGroup(status: .working, items: [item(term("t2", .working))]),
            InboxGroup(status: .idle, items: [item(term("t3", .idle)), item(term("t4", .idle))]),
        ]
        let s = ActivitySummary.state(of: inbox, tab: { _ in nil }, now: Date(timeIntervalSince1970: 5))
        let counts: [Int] = [s.blocked, s.done, s.working, s.idle]
        #expect(counts == [1, 0, 1, 2])
        #expect(s.agents.map { $0.id } == ["t1", "t2"], "no idle rows")
        #expect(s.agents[0].title == "Allow rm?")
        #expect(s.agents[0].status == .blocked)
        #expect(s.agents[1].title == "Claude Code")
        #expect(s.agents[1].since == 1_700_000_000)
        #expect(s.agents[1].spaceColor == "#123456")
        #expect(!s.agents[1].tint)
        #expect(ActivitySummary.line(s) == "1 needs you · 1 working")
        #expect(s.top == .blocked)
    }
}

@Suite struct SharedTypeTests {
    @Test func agentLinkRoundTrip() {
        let url = AgentLink.url(address: "lf/t1")
        #expect(url.scheme == "wierdr")
        #expect(AgentLink.address(in: url) == "lf/t1")
        #expect(AgentLink.address(in: URL(string: "wierdr://agent")!) == nil)
        #expect(AgentLink.address(in: URL(string: "https://agent?t=x")!) == nil)
    }

    @Test func agesReadAsInTheSidebarButTheFirstMinute() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func ago(_ s: Double) -> Date { now.addingTimeInterval(-s) }
        #expect(AgentAge.label(since: ago(42), now: now) == "42s")
        #expect(AgentAge.coarse(since: ago(42), now: now) == "<1m")
        #expect(AgentAge.coarse(since: ago(21 * 60 + 45), now: now) == "21m")
        #expect(AgentAge.coarse(since: ago(110 * 60), now: now) == "1h")
        #expect(AgentAge.coarse(since: ago(3 * 86_400 + 5), now: now) == "3d")
        #expect(AgentAge.coarse(since: nil, now: now) == nil)
    }

    @Test func registryUsesSnakeCaseAndSurvivesGarbage() throws {
        let r = PushRegistry(devices: ["d": phone])
        let json = String(decoding: r.encoded(), as: UTF8.self)
        #expect(json.contains("\"start_token\":\"aa11\""), "\(json)")
        #expect(PushRegistry.decode(r.encoded()) == r)
        #expect(PushRegistry.decode(Data("null".utf8)) == PushRegistry())
        #expect(PushRegistry.decode(nil) == PushRegistry())
    }
}
