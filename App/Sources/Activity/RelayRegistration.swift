import DeviceCheck
import Foundation
import WierdrRelay

/// The app's side of `RelayRegistration` (WierdrRelay): App Attest from DeviceCheck,
/// the relay at `WierdrRelay` in Info.plist, what's kept in UserDefaults (the key id
/// too: restored on another device, its key is gone from the Secure Enclave, App Attest
/// says `invalidKey` and a new one is made).
extension RelayRegistration {
    @MainActor static let shared: RelayRegistration? = {
        guard let base = (Bundle.main.object(forInfoDictionaryKey: "WierdrRelay") as? String).flatMap(URL.init(string:))
        else { return nil }
        return RelayRegistration(attest: DeviceAppAttest(), http: URLSessionRelayHTTP(base: base),
                                 store: DefaultsRegistrationStore())
    }()
}

/// `DCAppAttestService`, its errors as `AppAttestFailure`.
struct DeviceAppAttest: AppAttesting {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await mapped { try await DCAppAttestService.shared.generateKey() }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await mapped { try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await mapped { try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) }
    }

    private func mapped<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let e as DCError where e.code == .invalidKey {
            throw AppAttestFailure.invalidKey
        } catch let e as DCError where e.code == .serverUnavailable {
            throw AppAttestFailure.serverUnavailable
        }
    }
}
