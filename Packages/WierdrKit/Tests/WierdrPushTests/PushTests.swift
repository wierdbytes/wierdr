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
        #expect(p.step(now: at(0), summary: state([], idle: 2), devices: ["d": phone], channels: channels) == [])
        #expect(p.step(now: at(1), summary: working, devices: ["d": phone], channels: [:]) == [])
        let actions = p.step(now: at(2), summary: working, devices: ["d": phone], channels: channels)
        guard case let .start(l, channel, device, token, s, alert)? = actions.first, actions.count == 1 else {
            Issue.record("\(actions)"); return
        }
        #expect(l == lane); #expect(channel == "CHAN=="); #expect(device == "d")
        #expect(token == "aa11"); #expect(s == working)
        #expect(alert == .init(title: "Wierdr", body: "1 working", sound: false))
        // Nothing new: nothing to send.
        #expect(p.step(now: at(3), summary: working, devices: ["d": phone], channels: channels) == [])
    }

    @Test func statusChangesGoAtOnceOtherChangesAreCoalesced() {
        var p = Planner()
        _ = p.step(now: at(0), summary: state([agent("t1", .working)]), devices: ["d": phone], channels: channels)
        let two = state([agent("t1", .working), agent("t2", .working)])
        #expect(p.step(now: at(1), summary: two, devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: two, priority: 10, alert: nil)])
        let renamed = state([agent("t1", .working, title: "Renamed"), agent("t2", .working)])
        #expect(p.step(now: at(2), summary: renamed, devices: ["d": phone], channels: channels) == [],
                "a title only: within minInterval, wait")
        #expect(p.step(now: at(6), summary: renamed, devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: renamed, priority: 5, alert: nil)])
        let blocked = state([agent("t2", .blocked, title: "Allow rm?"), agent("t1", .working, title: "Renamed")])
        #expect(p.step(now: at(7), summary: blocked, devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: blocked, priority: 10,
                            alert: .init(title: "Needs you", body: "1 needs you · 1 working", sound: true))])
        let done = state([agent("t2", .blocked, title: "Allow rm?"), agent("t1", .done, title: "Fix it")])
        #expect(p.step(now: at(8), summary: done, devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: done, priority: 10,
                            alert: .init(title: "Done", body: "1 needs you · 1 done", sound: false))])
    }

    @Test func aStartForDoneAgentsOnlyWaitsAMoment() {
        var p = Planner()
        let done = state([agent("t1", .done)])
        #expect(p.step(now: at(0), summary: done, devices: ["d": phone], channels: channels) == [])
        // Looked at elsewhere right away: nothing started.
        #expect(p.step(now: at(2), summary: state([], idle: 1), devices: ["d": phone], channels: channels) == [])
        #expect(p.step(now: at(3), summary: done, devices: ["d": phone], channels: channels) == [])
        let started = p.step(now: at(8), summary: done, devices: ["d": phone], channels: channels)
        guard case .start? = started.first else { Issue.record("\(started)"); return }
        // A working agent starts at once.
        var q = Planner()
        #expect(q.step(now: at(0), summary: state([agent("t1", .working)]), devices: ["d": phone],
                       channels: channels).count == 1)
    }

    @Test func heartbeatMovesTheStaleDate() {
        var p = Planner()
        let s = state([agent("t1", .working)])
        _ = p.step(now: at(0), summary: s, devices: ["d": phone], channels: channels)
        #expect(p.step(now: at(599), summary: s, devices: ["d": phone], channels: channels) == [])
        #expect(p.step(now: at(600), summary: s, devices: ["d": phone], channels: channels).count == 1)
    }

    @Test func showsNothingActiveAtOnceAndEndsAfterTwoHours() {
        var p = Planner()
        let wait = p.settings.endDelay
        #expect(wait == 2 * 3600)
        _ = p.step(now: at(0), summary: state([agent("t1", .working)]), devices: ["d": phone], channels: channels)
        _ = p.step(now: at(10), summary: state([agent("t1", .done)]), devices: ["d": phone], channels: channels)
        // Seen on another client: the devices show it at once (priority 10)…
        let idle = state([], idle: 1)
        #expect(p.step(now: at(20), summary: idle, devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: idle, priority: 10, alert: nil)])
        #expect(p.step(now: at(30), summary: idle, devices: ["d": phone], channels: channels) == [])
        // …an agent set to work within the hold is an update, no start (no alert, no buzz).
        let working = state([agent("t1", .working)])
        #expect(p.step(now: at(1800), summary: working, devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: working, priority: 10, alert: nil)])
        _ = p.step(now: at(1900), summary: idle, devices: ["d": phone], channels: channels)
        #expect(p.step(now: at(1900 + wait - 1), summary: idle, devices: ["d": phone],
                       channels: channels).allSatisfy { if case .end = $0 { false } else { true } })
        #expect(p.step(now: at(1900 + wait), summary: idle, devices: ["d": phone], channels: channels)
                == [.end(lane: lane, channel: "CHAN==", state: idle)])
        #expect(p.running.isEmpty)
    }

    @Test func anIdleActivityNearEightHoursJustEnds() {
        var p = Planner()
        _ = p.step(now: at(0), summary: state([agent("t1", .working)]), devices: ["d": phone], channels: channels)
        let idle = state([], idle: 1)
        _ = p.step(now: at(7 * 3600), summary: idle, devices: ["d": phone], channels: channels)
        #expect(p.step(now: at(7.75 * 3600), summary: idle, devices: ["d": phone],
                       channels: [lane.key: "NEW=="]) == [.end(lane: lane, channel: "CHAN==", state: idle)])
        #expect(p.running.isEmpty)
    }

    @Test func aNewDeviceJoinsAndAGoneOneEndsIt() {
        var p = Planner()
        let s = state([agent("t1", .working)])
        _ = p.step(now: at(0), summary: s, devices: ["d": phone], channels: channels)
        var pad = phone
        pad.startToken = "bb22"
        let actions = p.step(now: at(1), summary: s, devices: ["d": phone, "e": pad], channels: channels)
        #expect(actions == [.start(lane: lane, channel: "CHAN==", device: "e", token: "bb22", state: s,
                                        alert: .init(title: "Wierdr", body: "1 working", sound: false))])
        #expect(p.step(now: at(2), summary: s, devices: [:], channels: channels) == [.end(lane: lane, channel: "CHAN==", state: s)])
    }

    @Test func startsAgainOnADeviceThatLostIt() {
        var p = Planner()
        let s = state([agent("t1", .working)])
        _ = p.step(now: at(0), summary: s, devices: ["d": phone], channels: channels)
        var gone = phone
        gone.hasActivity = false
        // Written while the start was on its way: not yet.
        gone.updated = at(5).timeIntervalSince1970
        #expect(p.step(now: at(6), summary: s, devices: ["d": gone], channels: channels).isEmpty)
        // Written well after it: start it there again, once.
        gone.updated = at(60).timeIntervalSince1970
        #expect(p.step(now: at(61), summary: s, devices: ["d": gone], channels: channels)
                == [.start(lane: lane, channel: "CHAN==", device: "d", token: "aa11", state: s,
                           alert: .init(title: "Wierdr", body: "1 working", sound: false))])
        #expect(p.step(now: at(62), summary: s, devices: ["d": gone], channels: channels).isEmpty)
        // It's there now.
        gone.hasActivity = true
        gone.updated = at(70).timeIntervalSince1970
        #expect(p.step(now: at(71), summary: s, devices: ["d": gone], channels: channels).isEmpty)
    }

    @Test func restartsBeforeEightHours() {
        var p = Planner()
        let s = state([agent("t1", .working)])
        _ = p.step(now: at(0), summary: s, devices: ["d": phone], channels: channels)
        // No fresh channel yet: it goes on (a heartbeat), the restart waits.
        #expect(p.step(now: at(7.75 * 3600), summary: s, devices: ["d": phone], channels: channels)
                == [.update(lane: lane, channel: "CHAN==", state: s, priority: 5, alert: nil)])
        let actions = p.step(now: at(7.75 * 3600), summary: s, devices: ["d": phone],
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
        _ = p.step(now: at(0), summary: s, devices: ["d": phone], channels: channels)
        p.resend(lane: lane)
        #expect(p.step(now: at(10), summary: s, devices: ["d": phone], channels: channels) == [.update(lane: lane, channel: "CHAN==", state: s, priority: 5, alert: nil)])
    }
}

@Suite struct PayloadTests {
    @Test func startPayloadDecodesAsActivityKitWould() throws {
        let s = state([agent("lf/t1", .blocked, title: "Allow rm?"), agent("t2", .working)], idle: 3)
        let data = ActivityPayload.start(attributes: .init(host: "mentoair"), state: s, channel: "CHAN==",
                                         alert: .init(title: "mentoair", body: "1 needs you", sound: true),
                                         stale: Date(timeIntervalSince1970: 2000), now: Date(timeIntervalSince1970: 1000),
                                         key: nil)
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
        let fit = ActivityPayload.fitting(s, key: nil)
        #expect(fit.agents.count < 5)
        #expect(fit.working == 5, "counts stay")
        let data = ActivityPayload.update(state: fit, alert: nil, stale: Date(), now: Date(), key: nil)
        #expect(data.count < 4096)
    }
}

/// Sealed payloads: the counts open, the agents and the attributes sealed, opened
/// with the key the phone keeps (here `ActivitySeal.lookup`).
@Suite(.serialized) struct SealTests {
    let key = ActivitySealKey.generate()

    func aps(_ data: Data) throws -> [String: Any] {
        try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["aps"] as? [String: Any])
    }

    func decode<T: Decodable>(_ type: T.Type, _ json: Any, keys: [ActivitySealKey]) throws -> T {
        ActivitySeal.lookup = { kid in keys.first { $0.kid == kid } }
        defer { ActivitySeal.lookup = { ActivitySeal.key(kid: $0) } }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func aSealedStartShowsOnlyCountsInTheOpen() throws {
        let s = state([agent("lf/t1", .blocked, title: "Allow rm -rf build?"), agent("t2", .working)], idle: 3)
        let data = ActivityPayload.start(attributes: .init(host: "mentoair"), state: s, channel: "CHAN==",
                                         alert: .init(title: "Wierdr", body: "1 needs you · 1 working", sound: true),
                                         stale: Date(), now: Date(), key: key)
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["Allow rm", "wierdr", "mentoair", "Opus", "lf/t1", "program.claude"] {
            #expect(!text.contains(secret), "\(secret) in \(text)")
        }
        let a = try aps(data)
        let content = try #require(a["content-state"] as? [String: Any])
        #expect(Set(content.keys) == ["blocked", "done", "working", "idle", "at", "sealed", "kid"])
        #expect(content["kid"] as? String == key.kid)
        #expect(content["blocked"] as? Int == 1 && content["idle"] as? Int == 3)
        let attrs = try #require(a["attributes"] as? [String: Any])
        #expect(Set(attrs.keys) == ["sealed", "kid"])

        // The phone with the key reads it all back.
        #expect(try decode(State.self, content, keys: [key]) == s)
        #expect(try decode(AgentsActivityAttributes.self, attrs, keys: [key]).host == "mentoair")
    }

    @Test func withoutItsKeyTheCountsShowAndTheRowsDont() throws {
        let s = state([agent("t1", .blocked), agent("t2", .working)])
        let content = try #require(try aps(ActivityPayload.update(state: s, alert: nil, stale: Date(), now: Date(),
                                                                  key: key))["content-state"])
        for keys in [[], [ActivitySealKey.generate()]] {
            let read = try decode(State.self, content, keys: keys)
            #expect(read.unreadable)
            #expect(read.agents.isEmpty)
            #expect(read.blocked == 1 && read.working == 1)
        }
        let attrs = try #require(try aps(ActivityPayload.start(attributes: .init(host: "mac"), state: s,
                                                               channel: "C", alert: .init(title: "", body: "", sound: false),
                                                               stale: Date(), now: Date(), key: key))["attributes"])
        #expect(try decode(AgentsActivityAttributes.self, attrs, keys: []).host == "")
    }

    @Test func aSealOfOneThingDoesntPassForAnother() throws {
        let sealed = try key.seal([agent("t1", .working)], .agents)
        #expect(key.open([Agent].self, sealed, .agents)?.count == 1)
        #expect(key.open([Agent].self, sealed, .attributes) == nil)
        var bytes = Data(base64Encoded: sealed)!
        bytes[bytes.count - 1] ^= 1
        #expect(key.open([Agent].self, bytes.base64EncodedString(), .agents) == nil, "tampered")
    }

    @Test func fittingMeasuresTheSealedState() throws {
        let words = ["рефакторинг", "сайдбара", "push", "relay", "проверка", "ключа", "APNs", "widget"]
        let s = state((0..<12).map { i in
            agent("lf/t\(i)", .working, title: (0..<14).map { words[($0 + i) % words.count] }.joined(separator: " "))
        })
        let fit = ActivityPayload.fitting(s, key: key)
        let content = try JSONSerialization.data(withJSONObject: ActivityPayload.contentState(fit, key: key))
        #expect(content.count <= 3000)
        #expect(ActivityPayload.update(state: fit, alert: .init(title: "Needs you", body: "12 working", sound: true),
                                       stale: Date(), now: Date(), key: key).count < 4096)
    }

    @Test func theKeyRoundTripsThroughItsDocument() throws {
        let doc = SealDocument(key)
        let read = try #require(SealDocument.decode(doc.encoded()))
        #expect(read == doc)
        #expect(read.sealKey?.kid == key.kid)
        #expect(read.sealKey?.base64 == key.base64)
        var wrong = doc
        wrong.kid = "00000000"
        #expect(wrong.sealKey == nil, "a kid that isn't the key's")
        #expect(SealDocument.decode(Data("null".utf8)) == nil)
        #expect(ActivitySealKey(base64: key.base64)?.kid == key.kid)
        #expect(key.kid.count == 8)
    }

    @Test func theMacKeepsItsKey() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seal-\(UUID().uuidString)/seal-key")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let made = try ActivitySealKey.loadOrCreate(url)
        #expect(try ActivitySealKey.loadOrCreate(url).kid == made.kid)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
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

    /// Claude Code's row: its session's title (the terminal's) while it works, its
    /// question while it needs you; its records count as no agents.
    @Test func claudeCodeTitlesAndRecords() {
        let claude = Program(key: "claude", name: "Claude Code", iconAsset: "program.claude", tint: false, isAgent: true)
        let space = Space(id: "sp1", machine: nil, name: "", displayName: "wierdr", folder: "/x", tabs: [])
        let records = [TaskRecord(id: "a445e47c8be43ef46", app: "claude-code", state: "blocked", title: "Count to five"),
                       TaskRecord(id: "bcq5ektlx", app: "claude-code", state: "working", title: "Sleep")]
        func term(_ a: String, _ s: AgentStatus, msg: String) -> TerminalInfo {
            TerminalInfo(address: a, title: "Ok reply test", program: claude, status: s, message: msg, app: "claude-code",
                         records: records)
        }
        func item(_ t: TerminalInfo) -> InboxItem {
            let tree = t.records.map { TreeNode.record(RecordKid(record: $0, owner: t.address, lines: [.tee])) }
            return InboxItem(row: SidebarRow(kind: .agent, paneID: "p" + t.address, tabID: "tb1", terminal: t, tree: tree), space: space)
        }
        let inbox = [
            InboxGroup(status: .blocked, items: [item(term("t1", .blocked, msg: "approve Bash: rm -rf build"))]),
            InboxGroup(status: .working, items: [item(term("t2", .working, msg: "1 shell still running"))]),
        ]
        let s = ActivitySummary.state(of: inbox, tab: { _ in nil }, now: Date(timeIntervalSince1970: 5))
        #expect(s.agents.map(\.title) == ["approve Bash: rm -rf build", "Ok reply test"])
        let counts: [Int] = [s.blocked, s.done, s.working, s.idle]
        #expect(counts == [1, 0, 1, 0])
    }

    /// Codex's row: its thread's name cut out of its window title (no project, no
    /// "Action Required"), "Codex" while it has none.
    @Test func codexTitles() {
        let codex = Program(key: "codex", name: "Codex", iconAsset: "program.codex", tint: false, isAgent: true)
        let space = Space(id: "sp1", machine: nil, name: "", displayName: "wierdr", folder: "/x", tabs: [])
        func item(_ a: String, _ s: AgentStatus, title: String) -> InboxItem {
            let t = TerminalInfo(address: a, title: title, cwd: "/Users/mentor/me/dev/wierdr", program: codex, status: s,
                                 state: s == .blocked ? "blocked" : "idle", app: "codex")
            return InboxItem(row: SidebarRow(kind: .agent, paneID: "p" + a, tabID: "tb1", terminal: t), space: space)
        }
        let inbox = [
            InboxGroup(status: .blocked, items: [item("t1", .blocked, title: "[ ! ] Action Required | Create approval marker | wierdr")]),
            InboxGroup(status: .done, items: [item("t2", .done, title: "Fix the login redirect | wierdr")]),
            InboxGroup(status: .working, items: [item("t3", .working, title: "wierdr")]),
            InboxGroup(status: .idle, items: [item("t4", .idle, title: "Reply with exactly ok | wierdr")]),
        ]
        let s = ActivitySummary.state(of: inbox, tab: { _ in nil }, now: Date(timeIntervalSince1970: 5))
        #expect(s.agents.map(\.title) == ["Create approval marker", "Fix the login redirect", "Codex"])
        let counts: [Int] = [s.blocked, s.done, s.working, s.idle]
        #expect(counts == [1, 1, 1, 1])
    }

    @Test func subAgentsCountAsAgents() {
        let space = Space(id: "sp1", machine: nil, name: "", displayName: "wierdr", folder: "/x", tabs: [])
        func term(_ a: String, _ s: AgentStatus?) -> TerminalInfo {
            TerminalInfo(address: a, program: .shell, status: s, parent: a == "t1" ? nil : "t1")
        }
        // An idle agent with a working, a done (reads idle) and a blocked sub-agent and a plain terminal.
        let kids = [term("t2", .working), term("t3", .done), term("t4", .blocked), term("t5", nil)]
            .map { SubAgent(terminal: $0, lines: [.tee]) }
        let row = SidebarRow(kind: .agent, paneID: "p1", tabID: "tb1", terminal: term("t1", .idle),
                             subtree: kids, urgency: .blocked)
        let inbox = [InboxGroup(status: .blocked, items: [InboxItem(row: row, space: space)])]
        let s = ActivitySummary.state(of: inbox, tab: { _ in nil }, now: Date(timeIntervalSince1970: 5))
        let counts: [Int] = [s.blocked, s.done, s.working, s.idle]
        #expect(counts == [1, 0, 1, 2])
        #expect(s.agents.map(\.id) == ["t1"], "the parent's row only")
        #expect(s.agents[0].status == .blocked)
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

    @Test func registryUsesSnakeCaseAndSurvivesGarbage() throws {
        let r = PushRegistry(devices: ["d": phone])
        let json = String(decoding: r.encoded(), as: UTF8.self)
        #expect(json.contains("\"start_token\":\"aa11\""), "\(json)")
        var keyed = phone
        keyed.sealKid = "ab12cd34"
        #expect(String(decoding: PushRegistry(devices: ["d": keyed]).encoded(), as: UTF8.self).contains("\"seal_kid\":\"ab12cd34\""))
        #expect(!keyed.same(as: phone))
        #expect(PushRegistry.decode(r.encoded()) == r)
        #expect(PushRegistry.decode(Data("null".utf8)) == PushRegistry())
        #expect(PushRegistry.decode(nil) == PushRegistry())
    }
}
