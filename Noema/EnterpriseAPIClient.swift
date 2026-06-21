// EnterpriseAPIClient.swift
// HTTP client for the Noema Teams workspace server, modeled on SearXNGSearchClient:
// ephemeral sessions, NetworkKillSwitch tracking, explicit status-code mapping.
import Foundation

enum EnterpriseAPIError: Error, LocalizedError {
    case invalidToken          // 401
    case paymentRequired(String) // 402 — workspace trial/subscription lapsed server-side
    case deviceRevoked         // 410 — reserved for revocation server-side
    case notFound(String)      // 404
    case forbidden(String)     // 403
    case server(Int, String)
    case network
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return String(localized: "Your workspace session is no longer valid.", locale: LocalizationManager.preferredLocale())
        case .paymentRequired(let detail):
            return detail.isEmpty
                ? String(localized: "Your organization's Noema Teams subscription has ended.", locale: LocalizationManager.preferredLocale())
                : detail
        case .deviceRevoked:
            return String(localized: "This device's access was revoked by your organization.", locale: LocalizationManager.preferredLocale())
        case .notFound(let detail), .forbidden(let detail):
            return detail
        case .server(let code, let detail):
            return detail.isEmpty ? "HTTP \(code)" : detail
        case .network:
            return String(localized: "Could not reach your organization's workspace server.", locale: LocalizationManager.preferredLocale())
        case .decoding:
            return String(localized: "The workspace server sent an unexpected response.", locale: LocalizationManager.preferredLocale())
        }
    }
}

actor EnterpriseAPIClient {
    static let shared = EnterpriseAPIClient()

    private let urlSessionTimeout: TimeInterval = 20

    /// Root of the Teams API host. Paths below are all under /v1/teams.
    static func baseURL() -> URL {
        if let override = UserDefaults.standard.string(forKey: "enterpriseAPIBaseURL"),
           let url = URL(string: override.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            return url
        }
        return AppSecrets.teamsAPIBaseURL
    }

    static var apiHost: String? { baseURL().host?.lowercased() }

    private func endpoint(_ path: String) -> URL {
        // String concatenation, not appendingPathComponent: paths here may carry a
        // query string ("?enrollmentID=…") which appendingPathComponent would
        // percent-encode into the path.
        var base = Self.baseURL().absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/v1/teams" + path) ?? Self.baseURL()
    }

    private func send(
        _ path: String,
        method: String = "GET",
        token: String? = nil,
        body: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        request.timeoutInterval = timeout ?? urlSessionTimeout

        // The kill switch allowlists this host while an off-grid policy is active,
        // so policy sync keeps working; any other state blocks like the rest of the app.
        if NetworkKillSwitch.shouldBlock(url: request.url) {
            throw EnterpriseAPIError.network
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = max(request.timeoutInterval * 2, 60)
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        NetworkKillSwitch.track(session: session)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EnterpriseAPIError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw EnterpriseAPIError.network
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw EnterpriseAPIError.invalidToken
        case 402:
            throw EnterpriseAPIError.paymentRequired(Self.detail(from: data))
        case 410:
            throw EnterpriseAPIError.deviceRevoked
        case 403:
            throw EnterpriseAPIError.forbidden(Self.detail(from: data))
        case 404:
            throw EnterpriseAPIError.notFound(Self.detail(from: data))
        default:
            throw EnterpriseAPIError.server(http.statusCode, Self.detail(from: data))
        }
    }

    private static func detail(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? String else { return "" }
        return detail
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try EnterprisePolicy.decoder().decode(type, from: data)
        } catch {
            throw EnterpriseAPIError.decoding
        }
    }

    // MARK: Enrollment

    func lookup(companyCode: String) async throws -> EnterpriseLookupResponse {
        let data = try await send("/lookup", method: "POST", body: ["companyCode": companyCode])
        return try decode(EnterpriseLookupResponse.self, from: data)
    }

    func startEnrollment(companyCode: String, email: String, deviceName: String, platform: String) async throws -> EnterpriseEnrollStartResponse {
        let data = try await send(
            "/enroll/start",
            method: "POST",
            body: [
                "companyCode": companyCode,
                "email": email,
                "deviceName": deviceName,
                "platform": platform,
            ]
        )
        return try decode(EnterpriseEnrollStartResponse.self, from: data)
    }

    func verifyEnrollment(enrollmentID: String, code: String) async throws -> EnterpriseEnrollResultResponse {
        let data = try await send(
            "/enroll/verify",
            method: "POST",
            body: ["enrollmentID": enrollmentID, "code": code]
        )
        return try decode(EnterpriseEnrollResultResponse.self, from: data)
    }

    func enrollmentStatus(enrollmentID: String) async throws -> EnterpriseEnrollResultResponse {
        let encoded = enrollmentID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? enrollmentID
        let data = try await send("/enroll/status?enrollmentID=\(encoded)")
        return try decode(EnterpriseEnrollResultResponse.self, from: data)
    }

    // MARK: Policy + datasets (device token)

    func fetchPolicy(deviceToken: String) async throws -> (EnterprisePolicy, Data) {
        let data = try await send("/policy", token: deviceToken)
        let policy = try decode(EnterprisePolicy.self, from: data)
        return (policy, data)
    }

    func fetchDatasetManifests(deviceToken: String) async throws -> [EnterpriseDatasetManifest] {
        let data = try await send("/datasets", token: deviceToken)
        return try decode(EnterpriseDatasetListResponse.self, from: data).datasets
    }

    func fetchDatasetFiles(deviceToken: String, enterpriseDatasetID: String) async throws -> [EnterpriseDatasetFile] {
        let data = try await send("/datasets/\(enterpriseDatasetID)/files", token: deviceToken)
        return try decode(EnterpriseDatasetFilesResponse.self, from: data).files
    }

    func downloadDatasetFile(deviceToken: String, enterpriseDatasetID: String, relPath: String) async throws -> Data {
        let encoded = relPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relPath
        return try await send(
            "/datasets/\(enterpriseDatasetID)/files/\(encoded)",
            token: deviceToken,
            timeout: 300
        )
    }

    func disconnect(deviceToken: String) async throws {
        _ = try await send("/device/disconnect", method: "POST", token: deviceToken, body: [:])
    }
}
