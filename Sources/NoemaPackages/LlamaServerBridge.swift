import Foundation
import NoemaLLamaServer

public enum LlamaServerBridge {
    public struct StartDiagnostics: Decodable, Sendable {
        public let code: String
        public let message: String
        public let lastHTTPStatus: Int?
        public let elapsedMs: Int
        public let progress: Double
        public let httpReady: Bool

        public init(code: String,
                    message: String,
                    lastHTTPStatus: Int? = nil,
                    elapsedMs: Int,
                    progress: Double,
                    httpReady: Bool) {
            self.code = code
            self.message = message
            self.lastHTTPStatus = lastHTTPStatus
            self.elapsedMs = elapsedMs
            self.progress = progress
            self.httpReady = httpReady
        }
    }

    public struct StartOptions: Decodable, Sendable {
        public let port: Int
        public let ggufPath: String
        public let mmprojPath: String
        public let mtpPath: String
        public let speculativeType: String
        public let specDraftNMax: Int?
        public let specDraftNMin: Int?
        public let specDraftPMin: Double?
        public let argv: [String]
    }

    public struct StartConfiguration: Sendable {
        public var host: String
        public var preferredPort: Int32
        public var ggufPath: String
        public var mmprojPath: String?
        public var mtpPath: String?
        public var chatTemplateFile: String?
        public var reasoningBudget: Int32?
        public var cacheRamMiB: Int32?
        public var ctxCheckpoints: Int32?
        public var speculativeType: String?
        public var specDraftNMax: Int32?
        public var specDraftNMin: Int32?
        public var specDraftPMin: Double?
        public var useJinja: Bool

        public init(host: String = "127.0.0.1",
                    preferredPort: Int32 = 0,
                    ggufPath: String,
                    mmprojPath: String? = nil,
                    mtpPath: String? = nil,
                    chatTemplateFile: String? = nil,
                    reasoningBudget: Int32? = nil,
                    cacheRamMiB: Int32? = nil,
                    ctxCheckpoints: Int32? = nil,
                    speculativeType: String? = nil,
                    specDraftNMax: Int32? = nil,
                    specDraftNMin: Int32? = nil,
                    specDraftPMin: Double? = nil,
                    useJinja: Bool = false) {
            self.host = host
            self.preferredPort = preferredPort
            self.ggufPath = ggufPath
            self.mmprojPath = mmprojPath
            self.mtpPath = mtpPath
            self.chatTemplateFile = chatTemplateFile
            self.reasoningBudget = reasoningBudget
            self.cacheRamMiB = cacheRamMiB
            self.ctxCheckpoints = ctxCheckpoints
            self.speculativeType = speculativeType
            self.specDraftNMax = specDraftNMax
            self.specDraftNMin = specDraftNMin
            self.specDraftPMin = specDraftPMin
            self.useJinja = useJinja
        }
    }

    @discardableResult
    public static func start(host: String = "127.0.0.1",
                              preferredPort: Int32 = 0,
                              ggufPath: String,
                              mmprojPath: String?) -> Int32 {
        let mm = mmprojPath ?? ""
        return noema_llama_server_start(host, preferredPort, ggufPath, mm)
    }

    @discardableResult
    public static func start(_ configuration: StartConfiguration) -> Int32 {
        let mmproj = configuration.mmprojPath ?? ""
        let templateFile = configuration.chatTemplateFile ?? ""
        let reasoningBudget = configuration.reasoningBudget ?? Int32.min
        let cacheRamMiB = configuration.cacheRamMiB ?? Int32.min
        let ctxCheckpoints = configuration.ctxCheckpoints ?? Int32.min
        let mtp = configuration.mtpPath ?? ""
        let speculativeType = configuration.speculativeType ?? ""
        let specDraftNMax = configuration.specDraftNMax ?? Int32.min
        let specDraftNMin = configuration.specDraftNMin ?? Int32.min
        let specDraftPMin = Float(configuration.specDraftPMin ?? -1.0)
        return noema_llama_server_start_with_options(
            configuration.host,
            configuration.preferredPort,
            configuration.ggufPath,
            mmproj,
            templateFile,
            reasoningBudget,
            configuration.useJinja ? 1 : 0,
            cacheRamMiB,
            ctxCheckpoints,
            mtp,
            speculativeType,
            specDraftNMax,
            specDraftNMin,
            specDraftPMin
        )
    }

    public static func stop() {
        noema_llama_server_stop()
    }

    public static func port() -> Int32 {
        return noema_llama_server_port()
    }

    public static func isLoading() -> Bool {
        return noema_llama_server_is_loading() != 0
    }

    public static func loadProgress() -> Double {
        let value = Double(noema_llama_server_load_progress())
        if value.isNaN || value.isInfinite {
            return 0.0
        }
        return min(1.0, max(0.0, value))
    }

    public static func lastStartDiagnostics() -> StartDiagnostics? {
        guard let raw = noema_llama_server_last_start_diagnostics_json() else {
            return nil
        }
        let json = String(cString: raw)
        guard !json.isEmpty, let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(StartDiagnostics.self, from: data)
    }

    public static func lastStartOptions() -> StartOptions? {
        guard let raw = noema_llama_server_last_start_options_json() else {
            return nil
        }
        let json = String(cString: raw)
        guard !json.isEmpty, let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(StartOptions.self, from: data)
    }
}
