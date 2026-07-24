import Foundation
import Combine
import NoemaPackages

@MainActor
final class LocalVLM: ObservableObject {
    @Published private(set) var baseURL: URL?
    private var loopbackLease: NoemaLlamaClient.StandaloneLoopbackLease?

    func start() async throws {
        // Install any .gguf and .mmproj from the bundle into Caches.
        // If .mmproj exists, it will be passed via --mmproj to enable vision.
        // If not, server still starts as text-only.
        guard let gguf = try Weights.installAny(withExtension: "gguf") else {
            throw NSError(domain: "Noema", code: 100, userInfo: [NSLocalizedDescriptionKey: "No .gguf found in bundle"])
        }
        let mmproj = try Weights.installAny(withExtension: "mmproj")
        let mmPath = mmproj?.url.path
        let (configuration, overfitPlan) = GGUFServerConfigurationResolver.resolveWithPlan(
            modelURL: gguf.url,
            settings: ModelSettings.default(for: .gguf),
            mmprojPath: mmPath,
            contextShiftEnabled: true,
            purpose: .utility
        )
        if case .refused(let reason) = overfitPlan {
            throw NSError(
                domain: "Noema",
                code: 2004,
                userInfo: [NSLocalizedDescriptionKey: OverfitPlanResolver.refusalMessage(reason)]
            )
        }
        guard let lease = await NoemaLlamaClient.startStandaloneLoopbackServer(
            with: configuration,
            visionEnabled: true
        ) else { throw NSError(domain: "Noema", code: 1) }
        loopbackLease = lease
        baseURL = URL(string: "http://127.0.0.1:\(lease.port)")
        // Surface vision capability to the UI so it can enable the attach button
        let d = UserDefaults.standard
        d.set(true, forKey: "currentModelIsRemote")
    }

    func stop() async {
        if let loopbackLease {
            await NoemaLlamaClient.stopStandaloneLoopbackServer(ifOwned: loopbackLease)
        }
        loopbackLease = nil
        baseURL = nil
    }

    func send(prompt: String, imagePNG: Data) async throws -> String {
        guard let baseURL,
              let loopbackLease,
              let bridgeGeneration = NoemaLlamaClient.reserveStandaloneLoopbackGeneration(
                  for: loopbackLease
              ) else { throw NSError(domain: "Noema", code: 2) }
        defer { bridgeGeneration.release() }
        let requestTimeout: TimeInterval = 60 * 60 * 24 * 365 * 10
        let resourceTimeout: TimeInterval = 60 * 60 * 24 * 365 * 10
        let dataURL = "data:image/png;base64," + imagePNG.base64EncodedString()
        let body: [String: Any] = [
            "model": "local-vlm",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": dataURL]]
                ]
            ]]
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = requestTimeout
        if NetworkKillSwitch.shouldBlock(request: req) {
            throw UserFacingErrorFormatter.normalizedTransportError(
                URLError(.notConnectedToInternet),
                context: .localModel
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [AnyHashable: Any]()
        let session = URLSession(configuration: configuration)
        NetworkKillSwitch.track(session: session)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, _) = try await session.data(for: req)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw UserFacingErrorFormatter.normalizedTransportError(error, context: .localModel)
        }
    }
}
