import Foundation

#if os(iOS)
import CryptoKit
import DeviceCheck

enum AppAttestClientError: LocalizedError {
    case unsupported
    case missingBody
    case invalidChallenge
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return String(localized: "This device cannot verify Noema’s Wallet signer.")
        case .missingBody:
            return String(localized: "The Wallet signer request is missing its draft payload.")
        case .invalidChallenge, .invalidResponse:
            return String(localized: "Noema’s Wallet signer could not verify this device.")
        }
    }
}

struct AppAttestClient {
    static let shared = AppAttestClient()

    private let service = "Noema.WalletAppAttest"
    private let keyIDAccountPrefix = "wallet-signer.app-attest-key-id"
    private let legacyKeyIDAccount = "wallet-signer.app-attest-key-id"

    func resetStoredKey(baseURLString: String) throws {
        _ = try KeychainStore.delete(service: service, account: keyIDAccount(baseURLString: baseURLString))
        _ = try KeychainStore.delete(service: service, account: legacyKeyIDAccount)
    }

    func authorize(_ request: URLRequest, baseURLString: String, session: URLSession, requestID: String, attempt: Int) async throws -> URLRequest {
        guard DCAppAttestService.shared.isSupported else {
            throw AppAttestClientError.unsupported
        }
        guard let body = request.httpBody else {
            throw AppAttestClientError.missingBody
        }

        let keyID = try await ensureRegisteredKey(baseURLString: baseURLString, session: session, requestID: requestID, attempt: attempt)
        let challenge = try await fetchChallenge(baseURLString: baseURLString, purpose: "assert", session: session, requestID: requestID, attempt: attempt)
        let bodyHash = Data(SHA256.hash(data: body))
        let clientData = challenge.data + bodyHash
        let clientDataHash = Data(SHA256.hash(data: clientData))
        let assertion = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)

        var authorized = request
        authorized.setValue(keyID, forHTTPHeaderField: "X-Noema-App-Attest-Key-ID")
        authorized.setValue(challenge.encoded, forHTTPHeaderField: "X-Noema-App-Attest-Challenge")
        authorized.setValue(assertion.base64URLEncodedString(), forHTTPHeaderField: "X-Noema-App-Attest-Assertion")
        authorized.setValue(bodyHash.base64URLEncodedString(), forHTTPHeaderField: "X-Noema-Body-SHA256")
        authorized.setValue("challenge-bytes+body-sha256/v1", forHTTPHeaderField: "X-Noema-App-Attest-Client-Data")
        authorized.setValue(clientDataHash.base64URLEncodedString(), forHTTPHeaderField: "X-Noema-App-Attest-Client-Data-Hash")
        authorized.setValue(requestID, forHTTPHeaderField: "X-Noema-Attest-Request-ID")
        authorized.setValue(String(attempt), forHTTPHeaderField: "X-Noema-Attest-Attempt")
        return authorized
    }

    private func ensureRegisteredKey(baseURLString: String, session: URLSession, requestID: String, attempt: Int) async throws -> String {
        let account = try keyIDAccount(baseURLString: baseURLString)
        if let stored = try readKeyID(account: account) {
            return stored
        }

        let challenge = try await fetchChallenge(baseURLString: baseURLString, purpose: "register", session: session, requestID: requestID, attempt: attempt)
        let keyID = try await DCAppAttestService.shared.generateKey()
        let clientDataHash = Data(SHA256.hash(data: challenge.data))
        let attestation = try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
        let body = RegistrationRequest(
            keyId: keyID,
            challenge: challenge.encoded,
            attestationObject: attestation.base64URLEncodedString()
        )
        var request = URLRequest(url: try appAttestURL(baseURLString: baseURLString, path: "register"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID, forHTTPHeaderField: "X-Noema-Attest-Request-ID")
        request.setValue(String(attempt), forHTTPHeaderField: "X-Noema-Attest-Attempt")
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppAttestClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppAttestClientError.invalidResponse
        }
        _ = try KeychainStore.delete(service: service, account: legacyKeyIDAccount)
        try storeKeyID(keyID, account: account)
        return keyID
    }

    private func fetchChallenge(baseURLString: String, purpose: String, session: URLSession, requestID: String, attempt: Int) async throws -> Challenge {
        var components = URLComponents(url: try appAttestURL(baseURLString: baseURLString, path: "challenge"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "purpose", value: purpose)]
        guard let url = components?.url else {
            throw PassSigningError.invalidSignerURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(requestID, forHTTPHeaderField: "X-Noema-Attest-Request-ID")
        request.setValue(String(attempt), forHTTPHeaderField: "X-Noema-Attest-Attempt")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppAttestClientError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(ChallengeResponse.self, from: data)
        guard let challengeData = Data(base64URLEncoded: decoded.challenge), !challengeData.isEmpty else {
            throw AppAttestClientError.invalidChallenge
        }
        return Challenge(encoded: decoded.challenge, data: challengeData)
    }

    private func appAttestURL(baseURLString: String, path: String) throws -> URL {
        guard let base = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme?.hasPrefix("http") == true,
              let host = base.host else {
            throw PassSigningError.invalidSignerURL
        }
        var components = URLComponents()
        components.scheme = base.scheme
        components.host = host
        components.port = base.port
        components.path = "/v1/wallet/app-attest/\(path)"
        guard let url = components.url else {
            throw PassSigningError.invalidSignerURL
        }
        return url
    }

    private func keyIDAccount(baseURLString: String) throws -> String {
        let scope = try signerScope(baseURLString: baseURLString)
        let digest = SHA256.hash(data: Data(scope.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(keyIDAccountPrefix).\(digest)"
    }

    private func signerScope(baseURLString: String) throws -> String {
        guard let base = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = base.scheme?.lowercased(),
              let host = base.host?.lowercased() else {
            throw PassSigningError.invalidSignerURL
        }
        let port = base.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func readKeyID(account: String) throws -> String? {
        guard let data = try KeychainStore.read(service: service, account: account),
              let keyID = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !keyID.isEmpty else {
            return nil
        }
        return keyID
    }

    private func storeKeyID(_ keyID: String, account: String) throws {
        guard let data = keyID.data(using: .utf8) else { return }
        try KeychainStore.write(service: service, account: account, data: data)
    }

    private struct ChallengeResponse: Decodable {
        var challenge: String
    }

    private struct RegistrationRequest: Encodable {
        var keyId: String
        var challenge: String
        var attestationObject: String
    }

    private struct Challenge {
        var encoded: String
        var data: Data
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
