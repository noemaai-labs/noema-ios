import Foundation
import CryptoKit

enum PassSigningError: LocalizedError, Equatable {
    case missingSignerURL
    case invalidSignerURL
    case missingToken
    case offGrid
    case unauthorized
    case duplicate
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingSignerURL:
            return String(localized: "Add a Wallet signer URL in Settings before signing passes.")
        case .invalidSignerURL:
            return String(localized: "The Wallet signer URL is not valid.")
        case .missingToken:
            return String(localized: "Add a Wallet signer token in Settings before signing passes.")
        case .offGrid:
            return String(localized: "Wallet pass signing requires internet access. Turn off Off-grid Mode and connect to the internet before signing. Your draft has been saved locally.")
        case .unauthorized:
            return String(localized: "The Wallet signer rejected the saved token.")
        case .duplicate:
            return String(localized: "This looks like a duplicate of a pass already in Wallet. You can update the existing pass instead.")
        case .server(let message):
            return message
        case .invalidResponse:
            return String(localized: "The Wallet signer returned an invalid response.")
        }
    }
}

enum PassSigningCredentialStore {
    private static let service = "Noema.WalletPassSigner"
    private static let account = "wallet-pass-signer.token"

    static func token() throws -> String? {
        guard let data = try KeychainStore.read(service: service, account: account),
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func setToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = try KeychainStore.delete(service: service, account: account)
            return
        }
        guard let data = trimmed.data(using: .utf8) else { return }
        try KeychainStore.write(service: service, account: account, data: data)
    }

    @discardableResult
    static func removeToken() throws -> Bool {
        try KeychainStore.delete(service: service, account: account)
    }
}

struct PassSigningRequest: Encodable, Sendable {
    var draft: BoardingPassDraft
    var passJSON: PassJSON
    var requestedAt: Date
    var client: String
}

enum WalletPassConfiguration {
    static let passTypeIdentifier = "pass.com.noemaai.noema.transport"
    static let teamIdentifier = "XX3Z6V9TU9"
    static let hostedSignerBaseURL = PassScannerSettings.defaultSignerBaseURL
}

struct PassSigningClient {
    var session: URLSession
    var encoder: JSONEncoder

    init(session: URLSession = .shared) {
        self.session = session
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func sign(_ draft: BoardingPassDraft, baseURLString: String, token: String? = nil) async throws -> Data {
        guard !NetworkKillSwitch.isEnabled else { throw PassSigningError.offGrid }
#if os(iOS)
        if shouldUseHostedAppAttest(baseURLString: baseURLString, token: token) {
            return try await signHostedWithAppAttest(
                draft,
                baseURLString: baseURLString,
                token: token,
                requestID: UUID().uuidString,
                attempt: 1,
                allowsKeyResetRetry: true
            )
        }
#endif
        let request = try makeRequest(draft, baseURLString: baseURLString, token: token)
        return try await send(request, baseURLString: baseURLString, token: token)
    }

#if os(iOS)
    private func signHostedWithAppAttest(
        _ draft: BoardingPassDraft,
        baseURLString: String,
        token: String?,
        requestID: String,
        attempt: Int,
        allowsKeyResetRetry: Bool
    ) async throws -> Data {
        var request = try makeRequest(draft, baseURLString: baseURLString, token: token)
        request = try await AppAttestClient.shared.authorize(
            request,
            baseURLString: baseURLString,
            session: session,
            requestID: requestID,
            attempt: attempt
        )

        do {
            return try await send(request, baseURLString: baseURLString, token: token)
        } catch PassSigningError.server(let message)
            where allowsKeyResetRetry && Self.isRecoverableHostedAppAttestError(message) {
            try? AppAttestClient.shared.resetStoredKey(baseURLString: baseURLString)
            return try await signHostedWithAppAttest(
                draft,
                baseURLString: baseURLString,
                token: token,
                requestID: UUID().uuidString,
                attempt: attempt + 1,
                allowsKeyResetRetry: false
            )
        }
    }
#endif

    private func send(_ request: URLRequest, baseURLString: String, token: String?) async throws -> Data {
        NetworkKillSwitch.track(session: session)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PassSigningError.invalidResponse
        }
        let responseText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch http.statusCode {
        case 200:
            guard http.mimeType == nil
                    || http.mimeType == "application/vnd.apple.pkpass"
                    || http.value(forHTTPHeaderField: "Content-Type")?.contains("application/vnd.apple.pkpass") == true else {
                throw PassSigningError.invalidResponse
            }
            return data
        case 401, 403:
            if shouldUseHostedAppAttest(baseURLString: baseURLString, token: token) {
                throw PassSigningError.server(Self.hostedAppAttestErrorMessage(responseText: responseText, response: http))
            }
            throw PassSigningError.unauthorized
        case 409:
            throw PassSigningError.duplicate
        default:
            let message = (responseText?.isEmpty == false)
                ? responseText!
                : String.localizedStringWithFormat(String(localized: "Wallet signer failed with status %d."), http.statusCode)
            throw PassSigningError.server(message)
        }
    }

    static func isRecoverableHostedAppAttestError(_ message: String) -> Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("app_attest_")
    }

    private static func hostedAppAttestErrorMessage(responseText: String?, response: HTTPURLResponse) -> String {
        let fallback = String(localized: "Noema’s Wallet signer could not verify this device.")
        let code = responseText?.isEmpty == false ? responseText! : fallback
        guard code.hasPrefix("app_attest_"),
              let requestID = response.value(forHTTPHeaderField: "X-Noema-Attest-Request-ID"),
              !requestID.isEmpty else {
            return code
        }
        return "\(code) request_id=\(requestID)"
    }

    func makeRequest(_ draft: BoardingPassDraft, baseURLString: String, token: String? = nil) throws -> URLRequest {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw PassSigningError.missingSignerURL }
        guard let base = URL(string: trimmedURL), base.scheme?.hasPrefix("http") == true else {
            throw PassSigningError.invalidSignerURL
        }
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let endpoint: URL
        if base.path.hasSuffix("/v1/wallet/passes/sign") {
            endpoint = base
        } else {
            endpoint = base
                .appendingPathComponent("v1")
                .appendingPathComponent("wallet")
                .appendingPathComponent("passes")
                .appendingPathComponent("sign")
        }

        let payload = PassSigningRequest(
            draft: draft,
            passJSON: PassJSONMapper.map(draft),
            requestedAt: Date(),
            client: "Noema"
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.apple.pkpass", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue(token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(payload)
        return request
    }

    private func shouldUseHostedAppAttest(baseURLString: String, token: String?) -> Bool {
        guard token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return false
        }
        guard let host = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(),
              let hostedHost = URL(string: WalletPassConfiguration.hostedSignerBaseURL)?.host?.lowercased() else {
            return false
        }
        return host == hostedHost
    }
}

struct PassJSONMapper {
    static func map(_ draft: BoardingPassDraft) -> PassJSON {
        let serial = WalletDuplicateResolver.serialNumber(for: draft)
        return PassJSON(
            description: String(localized: "Trip pass generated from captured boarding pass"),
            formatVersion: 1,
            organizationName: "Noema Travel Tools",
            logoText: "Boarding Pass",
            passTypeIdentifier: WalletPassConfiguration.passTypeIdentifier,
            serialNumber: serial,
            teamIdentifier: WalletPassConfiguration.teamIdentifier,
            foregroundColor: draft.walletPresentation.foregroundColor,
            backgroundColor: draft.walletPresentation.backgroundColor,
            labelColor: draft.walletPresentation.labelColor,
            boardingPass: PassJSON.BoardingPass(
                transitType: draft.walletPresentation.transitType,
                primaryFields: [
                    .init(key: "route", label: String(localized: "Route"), value: "\(draft.journey.originCode) -> \(draft.journey.destinationCode)"),
                    .init(key: "service", label: String(localized: "Flight / Service"), value: draft.journey.serviceNumber)
                ],
                secondaryFields: [
                    .init(key: "passenger", label: String(localized: "Passenger"), value: draft.traveler.fullName),
                    .init(key: "seat", label: String(localized: "Seat"), value: draft.journey.seat ?? "")
                ].filter { !$0.value.isEmpty },
                auxiliaryFields: auxiliaryFields(for: draft),
                backFields: [
                    .init(key: "generatedBy", label: "Noema", value: String(localized: "Generated from a user-confirmed scan.")),
                    .init(key: "capturedAt", label: String(localized: "Captured"), value: ISO8601DateFormatter().string(from: draft.provenance.capturedAt))
                ]
            ),
            barcodes: barcodes(for: draft),
            semanticTags: semanticTags(for: draft)
        )
    }

    private static func barcodes(for draft: BoardingPassDraft) -> [PassJSON.Barcode] {
        guard let rawValue = draft.barcode.rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return []
        }
        return [
            PassJSON.Barcode(
                format: (draft.barcode.symbology ?? .qr).walletFormat,
                message: rawValue,
                messageEncoding: "iso-8859-1"
            )
        ]
    }

    private static func auxiliaryFields(for draft: BoardingPassDraft) -> [PassJSON.Field] {
        var fields: [PassJSON.Field] = []
        if let gate = draft.journey.gate, !gate.isEmpty {
            fields.append(.init(key: "gate", label: String(localized: "Gate"), value: gate))
        }
        if let terminal = draft.journey.terminal, !terminal.isEmpty {
            fields.append(.init(key: "terminal", label: String(localized: "Terminal"), value: terminal))
        }
        if let platform = draft.journey.platform, !platform.isEmpty {
            fields.append(.init(key: "platform", label: String(localized: "Platform"), value: platform))
        }
        if let boarding = draft.journey.boardingTime, !boarding.isEmpty {
            fields.append(.init(key: "boarding", label: String(localized: "Boarding"), value: boarding))
        }
        if !draft.journey.departureTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.append(.init(key: "departure", label: String(localized: "Departure"), value: draft.journey.departureTime))
        }
        return fields
    }

    private static func semanticTags(for draft: BoardingPassDraft) -> [String: String] {
        var tags: [String: String] = [
            "passengerName": draft.traveler.fullName,
            "departureLocation": draft.journey.originCode,
            "destinationLocation": draft.journey.destinationCode,
            "flightNumber": draft.journey.serviceNumber
        ]
        if let airline = draft.issuer.iataCode {
            tags["airlineCode"] = airline
        }
        return tags
    }

}

struct PassJSON: Encodable, Equatable, Sendable {
    struct Field: Encodable, Equatable, Sendable {
        var key: String
        var label: String
        var value: String
    }

    struct BoardingPass: Encodable, Equatable, Sendable {
        var transitType: String
        var primaryFields: [Field]
        var secondaryFields: [Field]
        var auxiliaryFields: [Field]
        var backFields: [Field]
    }

    struct Barcode: Encodable, Equatable, Sendable {
        var format: String
        var message: String
        var messageEncoding: String
    }

    var description: String
    var formatVersion: Int
    var organizationName: String
    var logoText: String
    var passTypeIdentifier: String
    var serialNumber: String
    var teamIdentifier: String
    var foregroundColor: String
    var backgroundColor: String
    var labelColor: String
    var boardingPass: BoardingPass
    var barcodes: [Barcode]
    var semanticTags: [String: String]
}

enum WalletDuplicateResolver {
    static func serialNumber(for draft: BoardingPassDraft) -> String {
        let canonical = [
            draft.transportMode.rawValue,
            draft.issuer.iataCode ?? draft.issuer.railOperatorCode ?? draft.issuer.name,
            draft.traveler.fullName,
            draft.journey.originCode,
            draft.journey.destinationCode,
            draft.journey.serviceNumber,
            draft.journey.departureTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (draft.journey.boardingTime ?? "")
                : draft.journey.departureTime
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
