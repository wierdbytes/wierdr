import Foundation
import HerdrCore
import Testing
@testable import WierdrModel

/// A `limits` document as @wierdbytes/pi-herdr writes it.
enum LimitsFixture {
    static func doc(_ accounts: [String: JSONValue]) -> JSONValue {
        ["schema": 1, "updated_at": 1000, "accounts": .object(JSONObject(accounts))]
    }

    static func window(_ id: String, label: String, length: Int, used: Double, reset: Int?, at: Int) -> JSONValue {
        var w: JSONValue = ["id": .string(id), "label": .string(label), "window_s": .int(Int64(length)),
                            "used": .double(used), "at": .int(Int64(at))]
        if let reset { w["resets_at"] = .int(Int64(reset)) }
        return w
    }

    static func claude(at: Int = 1000, used5h: Double = 37, reset5h: Int = 10_000, host: String = "mac") -> JSONValue {
        ["provider": "claude", "account": "849d2d8c", "status": "ok", "binding": "5h", "host": .string(host), "at": .int(Int64(at)),
         "windows": [
            "5h": window("5h", label: "5 hours", length: 18_000, used: used5h, reset: reset5h, at: at),
            "7d": window("7d", label: "7 days", length: 604_800, used: 58, reset: 500_000, at: at),
            "7d_oi": window("7d_oi", label: "7 days + extra", length: 604_800, used: 30, reset: 500_000, at: at),
         ]]
    }

    static func codex(at: Int = 900) -> JSONValue {
        ["provider": "codex", "account": "d4800446", "label": "dev@example.com", "plan": "plus", "at": .int(Int64(at)),
         "windows": [
            "7d": window("7d", label: "7 days", length: 604_800, used: 21, reset: 400_000, at: at),
            "5h": window("5h", label: "5 hours", length: 18_000, used: 9, reset: 9_000, at: at),
         ]]
    }
}

@Suite struct LimitsTests {
    typealias F = LimitsFixture
    let t0 = Date(timeIntervalSince1970: 0)
    func date(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }

    @Test func parsesTheDocument() throws {
        let accounts = Limits.parse(F.doc(["claude.849d2d8c": F.claude(), "codex.d4800446": F.codex()]))
        let claude = try #require(accounts.first { $0.id == "claude.849d2d8c" })
        #expect(claude.provider == "claude" && claude.binding == "5h" && claude.host == "mac" && claude.at == date(1000))
        #expect(claude.windows.map(\.id) == ["5h", "7d", "7d_oi"])
        #expect(claude.windows[0] == LimitWindow(id: "5h", label: "5 hours", length: 18_000, used: 37, resetsAt: date(10_000), at: date(1000)))
        let codex = try #require(accounts.first { $0.id == "codex.d4800446" })
        #expect(codex.windows.map(\.id) == ["5h", "7d"])  // shortest first, whatever the document's order
        #expect(codex.label == "dev@example.com" && codex.plan == "plus")
    }

    @Test func ignoresOtherDocuments() {
        #expect(Limits.parse(.null).isEmpty)
        #expect(Limits.parse(["schema": 2, "accounts": ["claude.x": F.claude()]]).isEmpty)
        #expect(Limits.parse(F.doc(["broken": ["windows": [:]]])).isEmpty)
    }

    @Test func foldsWindowsLikePiHerdr() {
        func w(_ used: Double, _ reset: Double?, _ at: Double) -> LimitWindow {
            LimitWindow(id: "5h", label: "5 hours", length: 18_000, used: used, resetsAt: reset.map(date), at: date(at))
        }
        // One window: the used share only grows; the later reset of the two.
        #expect(Limits.fold(w(40, 1000, 10), w(30, 1060, 20)) == w(40, 1060, 20))
        // A later window replaces it; a reading of an earlier one is dropped.
        #expect(Limits.fold(w(90, 1000, 10), w(5, 20_000, 20)) == w(5, 20_000, 20))
        #expect(Limits.fold(w(5, 20_000, 20), w(90, 1000, 30)) == w(5, 20_000, 20))
        // A window that hasn't started replaces one only after its reset.
        #expect(Limits.fold(w(90, 1000, 10), w(0, nil, 500)) == w(90, 1000, 10))
        #expect(Limits.fold(w(90, 1000, 10), w(0, nil, 1500)) == w(0, nil, 1500))
    }

    @Test func mergesMachinesByAccount() throws {
        let mac = Limits.parse(F.doc(["claude.849d2d8c": F.claude(at: 1000, used5h: 37), "codex.d4800446": F.codex()]))
        let box = Limits.parse(F.doc(["claude.849d2d8c": F.claude(at: 2000, used5h: 41, host: "box"), "gemini.x": [
            "provider": "gemini", "account": "x", "at": 3000, "windows": [:]]]))
        let merged = Limits.merge([mac, box])
        #expect(merged.map(\.id) == ["claude.849d2d8c", "codex.d4800446", "gemini.x"])
        let claude = merged[0]
        #expect(claude.host == "box" && claude.at == date(2000))
        #expect(claude.windows.first { $0.id == "5h" }?.used == 41)
        // Codex keeps its plan and e-mail though the other machine never saw it.
        #expect(merged[1].plan == "plus" && merged[1].label == "dev@example.com")
    }

    @Test func pace() throws {
        let start = 10_000.0
        func w(used: Double, gone: Double) -> LimitWindow {
            LimitWindow(id: "5h", label: "5 hours", length: 18_000, used: used, resetsAt: date(start + 18_000), at: date(start))
        }
        let now = date(start + 9_000)  // half the window gone
        #expect(Limits.pace(w(used: 40, gone: 0.5), now: now)?.speed == 0)
        #expect(Limits.tone(w(used: 40, gone: 0.5), now: now).tone == .ok)
        #expect(Limits.tone(w(used: 60, gone: 0.5), now: now) == (.ahead, 1))
        #expect(Limits.tone(w(used: 80, gone: 0.5), now: now) == (.danger, 2))
        #expect(Limits.tone(w(used: 91, gone: 0.5), now: now).tone == .danger)
        // Early in a window the ratio is noise.
        let early = date(start + 600)
        #expect(Limits.pace(w(used: 5, gone: 0), now: early)?.trusted == false)
        #expect(Limits.tone(w(used: 5, gone: 0), now: early).tone == .ok)
        // After its reset a reading shows nothing.
        #expect(Limits.tone(w(used: 95, gone: 0), now: date(start + 20_000)).tone == .reset)
        #expect(Limits.elapsed(w(used: 0, gone: 0), now: now) == 0.5)
    }

    @Test func headlineIsPinnedOrTheWorstProjection() throws {
        let account = try #require(Limits.parse(F.doc(["claude.849d2d8c": F.claude()])).first)
        // 5h: 37% with 0.53 of 5h gone; 7d: 58% with ~0.19 of the week gone → the week runs out first.
        let now = date(10_000 - 18_000 + 9_500)
        #expect(Limits.headline(account, pinned: nil, now: now)?.id == "7d")
        #expect(Limits.headline(account, pinned: "5h", now: now)?.id == "5h")
        #expect(Limits.headline(account, pinned: "7d_oi", now: now)?.id == "7d")  // not shown: not pinnable
        #expect(Limits.shown(account).map(\.id) == ["5h", "7d"])
    }

    @Test func text() {
        #expect(Limits.percent(37.4) == "37%" && Limits.percent(0.3) == "<1%" && Limits.percent(0) == "0%")
        #expect(Limits.span(16 * 60) == "16m")
        #expect(Limits.span(2 * 3600 + 5 * 60) == "2h 05m")
        #expect(Limits.span(40 * 3600) == "1d 16h")
        #expect(Limits.planName("codex", "plus") == "Plus")
        #expect(Limits.planName("codex", "prolite") == "Pro 100")
        #expect(Limits.planName("claude", "max 20x") == "Ultra")
        #expect(Limits.planName("claude", "claude_max") == "Max")
        #expect(Limits.planName("claude", nil) == nil)
        #expect(Limits.providerName("codex") == "Codex" && Limits.providerName("qwen") == "Qwen")
        let codex = Limits.parse(F.doc(["codex.d4800446": F.codex()]))[0]
        #expect(Limits.accountName(codex) == "dev")
    }
}
