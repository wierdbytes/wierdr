import Foundation
import Testing
@testable import WierdrRelay

/// App Attest as the tests script it.
final class FakeAttest: AppAttesting, @unchecked Sendable {
    let lock = NSLock()
    var isSupported = true
    var keys = 0
    var attests: [String] = []
    var asserts: [String] = []
    var attestError: Error?
    var assertError: Error?

    func generateKey() async throws -> String {
        lock.withLock { keys += 1; return "key\(keys)" }
    }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            attests.append(keyId)
            if let e = attestError { throw e }
            return Data("attestation".utf8)
        }
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            asserts.append(keyId)
            if let e = assertError { assertError = nil; throw e }
            return Data("assertion".utf8)
        }
    }
}

/// The relay as the tests script it: each path's replies, in turn (the last one repeats).
final class FakeRelay: RelayHTTP, @unchecked Sendable {
    let lock = NSLock()
    var replies: [String: [(Int, [String: Any])]] = [:]
    var calls: [String] = []

    init() {
        replies = [
            "v1/challenge": [(200, ["challenge": "c1.x"])],
            "v1/attest": [(200, ["ok": true])],
            "v1/devices": [(200, ["grant": "g2.2000000000.OWNER.mac", "expires": 2_000_000_000.0])],
            "v1/grants/check": [(200, ["ok": true, "renew": false])],
        ]
    }

    func post(_ path: String, body: Data, headers: [String: String]) async throws -> (status: Int, json: [String: Any]) {
        lock.withLock {
            calls.append(path)
            var list = replies[path] ?? [(404, [:])]
            let r = list.count > 1 ? list.removeFirst() : list[0]
            replies[path] = list
            return r
        }
    }

    func count(_ path: String) -> Int { lock.withLock { calls.filter { $0 == path }.count } }
}

@MainActor
final class MemoryStore: RegistrationStore {
    var grant: KeptGrant?
    var keyId: String?
    var attested = false
    var attestRefusedAt: Date?
    var pending: PendingAttestation?
}

@MainActor @Suite final class RelayRegistrationTests {
    let attest = FakeAttest()
    let relay = FakeRelay()
    let store = MemoryStore()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    func registration() -> RelayRegistration {
        let r = RelayRegistration(attest: attest, http: relay, store: store, now: { [unowned self] in self.clock })
        r.log = { _ in }
        return r
    }

    @Test func theFirstTimeAKeyIsMadeAttestedAndAGrantGiven() async {
        let r = registration()
        #expect(await r.grant(token: "aa", env: "development", check: false) == "g2.2000000000.OWNER.mac")
        #expect(attest.keys == 1)
        #expect(attest.attests == ["key1"])
        #expect(store.attested)
        // Then it's kept: no calls while it's good for 10 more days.
        let before = relay.calls.count
        #expect(await r.grant(token: "aa", env: "development", check: false) == "g2.2000000000.OWNER.mac")
        #expect(relay.calls.count == before)
    }

    @Test func onConnectingTheRelaySaysWhetherTheGrantHolds() async {
        let r = registration()
        _ = await r.grant(token: "aa", env: "development", check: false)
        #expect(await r.grant(token: "aa", env: "development", check: true) == "g2.2000000000.OWNER.mac")
        #expect(relay.count("v1/grants/check") == 1)
        #expect(relay.count("v1/devices") == 1, "it holds: no new one")
        // Voided (a new relay secret): a new one, with the same key.
        relay.replies["v1/grants/check"] = [(403, ["error": "bad_grant"])]
        relay.replies["v1/devices"] = [(200, ["grant": "g2.2000000001.OWNER.new", "expires": 2_000_000_001.0])]
        #expect(await r.grant(token: "aa", env: "development", check: true) == "g2.2000000001.OWNER.new")
        #expect(attest.keys == 1)
        // To renew (the old secret, near its end): a new one too.
        relay.replies["v1/grants/check"] = [(200, ["ok": true, "renew": true])]
        relay.replies["v1/devices"] = [(200, ["grant": "g2.2000000002.OWNER.renewed", "expires": 2_000_000_002.0])]
        #expect(await r.grant(token: "aa", env: "development", check: true) == "g2.2000000002.OWNER.renewed")
    }

    @Test func aKeyTheRelayDoesntKnowIsReplacedOnceThenItGivesUp() async {
        relay.replies["v1/devices"] = [(401, ["error": "key_unknown"])]
        let r = registration()
        #expect(await r.grant(token: "aa", env: "development", check: false) == nil)
        #expect(attest.keys == 2, "two rounds at most")
        #expect(relay.count("v1/devices") == 2)
    }

    @Test func aKeyTheSecureEnclaveLostIsReplaced() async {
        attest.assertError = AppAttestFailure.invalidKey
        let r = registration()
        #expect(await r.grant(token: "aa", env: "development", check: false) != nil)
        #expect(attest.keys == 2)
        #expect(attest.asserts == ["key1", "key2"])
    }

    @Test func aRefusedAttestationRestsForADay() async {
        relay.replies["v1/attest"] = [(403, ["error": "bad_attestation"])]
        let r = registration()
        #expect(await r.grant(token: "aa", env: "development", check: false) == nil)
        #expect(attest.attests.count == 1)
        #expect(store.keyId == nil, "a refused key goes")
        #expect(await r.grant(token: "aa", env: "development", check: false) == nil)
        #expect(attest.attests.count == 1, "not again within the day")
        clock = clock.addingTimeInterval(86401)
        relay.replies["v1/attest"] = [(200, ["ok": true])]
        #expect(await r.grant(token: "aa", env: "development", check: false) != nil)
    }

    @Test func whileApplesServiceIsDownTheKeyStays() async {
        attest.attestError = AppAttestFailure.serverUnavailable
        let r = registration()
        #expect(await r.grant(token: "aa", env: "development", check: false) == nil)
        #expect(store.keyId == "key1")
        attest.attestError = nil
        #expect(await r.grant(token: "aa", env: "development", check: false) != nil)
        #expect(attest.keys == 1)
        #expect(attest.attests == ["key1", "key1"])
    }

    @Test func otherAttestationFailuresDropTheKey() async {
        attest.attestError = URLError(.notConnectedToInternet)
        let r = registration()
        #expect(await r.grant(token: "aa", env: "development", check: false) == nil)
        #expect(store.keyId == nil)
    }

    @Test func twoTokensAtOnceEachGetTheirOwn() async {
        relay.replies["v1/devices"] = [(200, ["grant": "g2.2000000000.OWNER.a", "expires": 2_000_000_000.0]),
                                       (200, ["grant": "g2.2000000000.OWNER.b", "expires": 2_000_000_000.0])]
        let r = registration()
        async let a = r.grant(token: "aa", env: "development", check: false)
        async let b = r.grant(token: "bb", env: "development", check: false)
        let (ga, gb) = await (a, b)
        #expect(Set([ga, gb]) == ["g2.2000000000.OWNER.a", "g2.2000000000.OWNER.b"])
    }

    @Test func aKeyRevokedOnCheckingRestsADayAsOnRegistering() async {
        let r = registration()
        _ = await r.grant(token: "aa", env: "development", check: false)
        relay.replies["v1/grants/check"] = [(403, ["error": "key_revoked"])]
        #expect(await r.grant(token: "aa", env: "development", check: true) == nil)
        #expect(attest.keys == 1, "no new key within the day")
        #expect(store.grant == nil)
    }

    @Test func aKeyTheRelayForgotIsReplacedAtOnceOnChecking() async {
        let r = registration()
        _ = await r.grant(token: "aa", env: "development", check: false)
        relay.replies["v1/grants/check"] = [(403, ["error": "key_unknown"])]
        relay.replies["v1/devices"] = [(200, ["grant": "g2.2000000005.OWNER.new", "expires": 2_000_000_005.0])]
        #expect(await r.grant(token: "aa", env: "development", check: true) == "g2.2000000005.OWNER.new")
        #expect(attest.keys == 2)
    }

    @Test func whatAppleAttestedIsSentAgainIfTheRelayWasOutOfReach() async {
        relay.replies["v1/attest"] = [(503, ["error": "attest_budget"]), (200, ["ok": true])]
        let r = registration()
        #expect(await r.grant(token: "aa", env: "development", check: false) == nil)
        #expect(store.pending?.attestation != nil)
        #expect(await r.grant(token: "aa", env: "development", check: false) != nil)
        #expect(attest.attests == ["key1"], "Apple asked once")
        #expect(store.pending == nil)
    }

    @Test func afterApplesOutageTheSameChallengeIsAttested() async {
        attest.attestError = AppAttestFailure.serverUnavailable
        let r = registration()
        _ = await r.grant(token: "aa", env: "development", check: false)
        let first = store.pending?.challenge
        attest.attestError = nil
        relay.replies["v1/challenge"] = [(200, ["challenge": "c1.other"])]
        _ = await r.grant(token: "aa", env: "development", check: false)
        #expect(first == "c1.x")
        #expect(relay.count("v1/attest") == 1)
        #expect(attest.attests == ["key1", "key1"])
    }

    @Test func theSignedBodySaysWhatItsFor() async {
        final class Capture: RelayHTTP, @unchecked Sendable {
            let inner: FakeRelay
            var devicesBody: Data?
            init(_ inner: FakeRelay) { self.inner = inner }
            func post(_ path: String, body: Data, headers: [String: String]) async throws -> (status: Int, json: [String: Any]) {
                if path == "v1/devices" { devicesBody = body }
                return try await inner.post(path, body: body, headers: headers)
            }
        }
        let capture = Capture(relay)
        let r = RelayRegistration(attest: attest, http: capture, store: store, now: { [unowned self] in self.clock })
        r.log = { _ in }
        _ = await r.grant(token: "aa", env: "development", check: false)
        let body = try? JSONSerialization.jsonObject(with: capture.devicesBody ?? Data()) as? [String: Any]
        #expect(body?["op"] as? String == "devices")
    }

    @Test func noAppAttestNoGrant() async {
        attest.isSupported = false
        #expect(await registration().grant(token: "aa", env: "development", check: false) == nil)
        #expect(relay.calls.isEmpty)
    }
}
