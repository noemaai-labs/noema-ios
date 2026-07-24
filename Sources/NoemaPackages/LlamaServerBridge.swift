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

    public struct StartOptions: Decodable, Equatable, Sendable {
        public let port: Int
        public let ggufPath: String
        public let mmprojPath: String
        public let mtpPath: String
        public let speculativeType: String
        public let specDraftNMax: Int?
        public let specDraftNMin: Int?
        public let specDraftPMin: Double?
        public let specDynamic: Bool?
        public let contextSize: Int
        public let contextShift: Bool
        public let gpuLayers: Int
        public let threads: Int
        public let threadsBatch: Int
        public let batchSize: Int
        public let ubatchSize: Int
        public let useMmap: Bool
        public let useMlock: Bool
        public let warmup: Bool
        public let kvOffload: Bool
        public let unifiedKVCache: Bool
        public let flashAttention: Bool
        public let cacheTypeK: String
        public let cacheTypeV: String
        public let parallelSlots: Int
        public let tensorOverride: String
        public let cpuMoE: Bool
        public let moeExpertCount: Int?
        public let yarnScale: Double?
        public let yarnOriginalContext: Int?
        public let yarnBetaFast: Double?
        public let yarnBetaSlow: Double?
        public let cacheRamMiB: Int
        public let ctxCheckpoints: Int
        /// Raw paged mode of the live server (PagedMode.rawValue). The native
        /// snapshot only emits paged fields when paging is on, so nil means a
        /// conventional (non-paged) boot.
        public let pagedMode: Int32?
        public let pagedIOThreads: Int32?
        public let pagedIODepth: Int32?
        public let pagedWaves: Bool?
        public let pagedExpertMajor: Bool?
        public let cpuNEON: Bool
        public let cpuDotProduct: Bool
        public let cpuI8MM: Bool
        public let cpuRepack: Bool
        public let argv: [String]
    }

    /// Bank/staging accounting reported by the native sizing pass for a
    /// Noema Overfit paged configuration.
    public struct PagedEstimate: Decodable, Equatable, Sendable {
        public let bankBytes: UInt64
        public let stagingBytes: UInt64
        public let slotsPerLayer: Int32
        public let moeLayerCount: UInt32

        public init(bankBytes: UInt64, stagingBytes: UInt64, slotsPerLayer: Int32, moeLayerCount: UInt32) {
            self.bankBytes = bankBytes
            self.stagingBytes = stagingBytes
            self.slotsPerLayer = slotsPerLayer
            self.moeLayerCount = moeLayerCount
        }
    }

    public struct MemoryEstimate: Decodable, Equatable, Sendable {
        public let modelBytes: UInt64
        public let contextBytes: UInt64
        public let computeBytes: UInt64
        public let projectorBytes: UInt64
        public let speculativeBytes: UInt64
        public let totalBytes: UInt64
        public let paged: PagedEstimate?

        public init(modelBytes: UInt64,
                    contextBytes: UInt64,
                    computeBytes: UInt64,
                    projectorBytes: UInt64,
                    speculativeBytes: UInt64,
                    totalBytes: UInt64,
                    paged: PagedEstimate? = nil) {
            self.modelBytes = modelBytes
            self.contextBytes = contextBytes
            self.computeBytes = computeBytes
            self.projectorBytes = projectorBytes
            self.speculativeBytes = speculativeBytes
            self.totalBytes = totalBytes
            self.paged = paged
        }
    }

    private struct MemoryEstimateEnvelope: Decodable {
        let status: String
        let message: String?
        let modelBytes: UInt64?
        let contextBytes: UInt64?
        let computeBytes: UInt64?
        let projectorBytes: UInt64?
        let speculativeBytes: UInt64?
        let totalBytes: UInt64?
        let paged: PagedEstimate?
    }

    public struct MemoryEstimateError: LocalizedError, Sendable {
        public let message: String

        public var errorDescription: String? { message }
    }

    /// Noema Overfit paged execution mode, mirroring the native contract.
    public enum PagedMode: Int32, Equatable, Sendable {
        case off = 0
        /// Full-size slot bank, every expert resident (parity oracle).
        case residentBank = 1
        /// Streamed slot bank fed from the sidecar (Stage 2).
        case streamed = 2
        /// Route tracing on an ordinary resident model.
        case traceOnly = 3
    }

    public struct StartConfiguration: Equatable, Sendable {
        public let host: String
        public let preferredPort: Int32
        public let ggufPath: String
        public let mmprojPath: String?
        public let mtpPath: String?
        public let chatTemplateFile: String?
        public let reasoningBudget: Int32?
        public let contextSize: Int32
        public let contextShift: Bool
        public let gpuLayers: Int32
        public let threads: Int32
        public let threadsBatch: Int32
        public private(set) var batchSize: Int32
        public private(set) var ubatchSize: Int32
        public let useMmap: Bool
        public let useMlock: Bool
        public let warmup: Bool
        public let kvOffload: Bool
        public let unifiedKVCache: Bool
        public let flashAttention: Bool
        public let cacheTypeK: String
        public let cacheTypeV: String
        public let parallelSlots: Int32
        public let tensorOverride: String?
        public let cpuMoE: Bool
        public let moeExpertCount: Int32?
        public let yarnScale: Double?
        public let yarnOriginalContext: Int32?
        public let yarnBetaFast: Double?
        public let yarnBetaSlow: Double?
        public let cacheRamMiB: Int32
        public let ctxCheckpoints: Int32
        public let speculativeType: String?
        public let specDraftNMax: Int32?
        public let specDraftNMin: Int32?
        public let specDraftPMin: Double?
        public let specDynamic: Bool
        public let useJinja: Bool
        public let pagedMode: PagedMode
        public let pagedManifestPath: String?
        public let pagedSlotsPerLayer: Int32
        public private(set) var pagedBankBudgetMiB: Int32
        public let pagedIOThreads: Int32
        public let pagedIODepth: Int32
        public let pagedIOTimeoutMs: Int32
        public let pagedPrefetch: Bool
        public let pagedOracleAllHit: Bool
        public let pagedTrace: Bool
        public let pagedTracePath: String?
        public let pagedVerifyChecksums: Bool
        public let pagedTelemetryIntervalMs: Int32
        public let pagedWaves: Bool
        public let pagedExpertMajor: Bool

        public init(host: String = "127.0.0.1",
                    preferredPort: Int32 = 0,
                    ggufPath: String,
                    mmprojPath: String? = nil,
                    mtpPath: String? = nil,
                    chatTemplateFile: String? = nil,
                    reasoningBudget: Int32? = nil,
                    contextSize: Int32 = 4096,
                    contextShift: Bool = true,
                    gpuLayers: Int32 = -1,
                    threads: Int32 = 1,
                    threadsBatch: Int32? = nil,
                    batchSize: Int32 = 512,
                    ubatchSize: Int32 = 256,
                    useMmap: Bool = true,
                    useMlock: Bool = false,
                    warmup: Bool = true,
                    kvOffload: Bool = true,
                    unifiedKVCache: Bool = true,
                    flashAttention: Bool = true,
                    cacheTypeK: String = "f16",
                    cacheTypeV: String = "f16",
                    parallelSlots: Int32 = 1,
                    tensorOverride: String? = nil,
                    cpuMoE: Bool = false,
                    moeExpertCount: Int32? = nil,
                    yarnScale: Double? = nil,
                    yarnOriginalContext: Int32? = nil,
                    yarnBetaFast: Double? = nil,
                    yarnBetaSlow: Double? = nil,
                    cacheRamMiB: Int32 = 0,
                    ctxCheckpoints: Int32 = 0,
                    speculativeType: String? = nil,
                    specDraftNMax: Int32? = nil,
                    specDraftNMin: Int32? = nil,
                    specDraftPMin: Double? = nil,
                    specDynamic: Bool = false,
                    useJinja: Bool = false,
                    pagedMode: PagedMode = .off,
                    pagedManifestPath: String? = nil,
                    pagedSlotsPerLayer: Int32 = 0,
                    pagedBankBudgetMiB: Int32 = 0,
                    pagedIOThreads: Int32 = 0,
                    pagedIODepth: Int32 = 0,
                    pagedIOTimeoutMs: Int32 = 0,
                    pagedPrefetch: Bool = false,
                    pagedOracleAllHit: Bool = false,
                    pagedTrace: Bool = false,
                    pagedTracePath: String? = nil,
                    pagedVerifyChecksums: Bool = true,
                    pagedTelemetryIntervalMs: Int32 = 0,
                    pagedWaves: Bool = false,
                    pagedExpertMajor: Bool = false) {
            self.host = host
            self.preferredPort = preferredPort
            self.ggufPath = ggufPath
            self.mmprojPath = mmprojPath
            self.mtpPath = mtpPath
            self.chatTemplateFile = chatTemplateFile
            self.reasoningBudget = reasoningBudget
            self.contextSize = max(1, contextSize)
            self.contextShift = contextShift
            self.gpuLayers = gpuLayers
            self.threads = max(1, threads)
            self.threadsBatch = max(1, threadsBatch ?? threads)
            self.batchSize = max(1, batchSize)
            self.ubatchSize = max(1, min(ubatchSize, batchSize))
            self.useMmap = useMmap
            self.useMlock = useMlock
            self.warmup = warmup
            self.kvOffload = kvOffload
            self.unifiedKVCache = unifiedKVCache
            self.flashAttention = flashAttention
            self.cacheTypeK = cacheTypeK
            self.cacheTypeV = cacheTypeV
            self.parallelSlots = max(1, parallelSlots)
            self.tensorOverride = tensorOverride
            self.cpuMoE = cpuMoE
            self.moeExpertCount = moeExpertCount.flatMap { $0 > 0 ? $0 : nil }
            self.yarnScale = yarnScale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            self.yarnOriginalContext = yarnOriginalContext.flatMap { $0 > 0 ? $0 : nil }
            self.yarnBetaFast = yarnBetaFast.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            self.yarnBetaSlow = yarnBetaSlow.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            self.cacheRamMiB = cacheRamMiB
            self.ctxCheckpoints = ctxCheckpoints
            self.speculativeType = speculativeType
            self.specDraftNMax = specDraftNMax
            self.specDraftNMin = specDraftNMin
            self.specDraftPMin = specDraftPMin
            self.specDynamic = specDynamic
            self.useJinja = useJinja
            self.pagedMode = pagedMode
            self.pagedManifestPath = pagedManifestPath
            self.pagedSlotsPerLayer = max(0, pagedSlotsPerLayer)
            self.pagedBankBudgetMiB = max(0, pagedBankBudgetMiB)
            self.pagedIOThreads = max(0, pagedIOThreads)
            self.pagedIODepth = max(0, pagedIODepth)
            self.pagedIOTimeoutMs = max(0, pagedIOTimeoutMs)
            self.pagedPrefetch = pagedPrefetch
            self.pagedOracleAllHit = pagedOracleAllHit
            self.pagedTrace = pagedTrace
            self.pagedTracePath = pagedTracePath
            self.pagedVerifyChecksums = pagedVerifyChecksums
            self.pagedTelemetryIntervalMs = max(0, pagedTelemetryIntervalMs)
            self.pagedWaves = pagedWaves
            self.pagedExpertMajor = pagedExpertMajor && pagedWaves
        }

        /// Returns the same immutable launch contract with only its logical
        /// and physical prompt batches changed. Paged launch planning uses
        /// this to try successively smaller wave-safe graphs against native
        /// exact sizing without rebuilding or accidentally dropping another
        /// runtime option.
        public func replacingBatchSizes(batchSize: Int32, ubatchSize: Int32) -> Self {
            var copy = self
            copy.batchSize = max(1, batchSize)
            copy.ubatchSize = max(1, min(ubatchSize, copy.batchSize))
            return copy
        }

        /// Returns the same launch contract with a different streamed expert
        /// bank budget. The committed load path uses this after exact native
        /// sizing proves that more of the live process headroom is available.
        public func replacingPagedBankBudgetMiB(_ budgetMiB: Int32) -> Self {
            var copy = self
            copy.pagedBankBudgetMiB = max(0, budgetMiB)
            return copy
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

    /// Marshals the Swift configuration into the native v4 struct with every
    /// string pinned for the duration of `body`. Shared by start and sizing.
    private static func withNativeConfiguration<T>(
        _ configuration: StartConfiguration,
        _ body: (UnsafePointer<noema_llama_server_configuration>) -> T
    ) -> T {
        func optionalCString<U>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> U) -> U {
            guard let value else { return body(nil) }
            return value.withCString(body)
        }
        return configuration.host.withCString { host in
            configuration.ggufPath.withCString { gguf in
                optionalCString(configuration.mmprojPath) { mmproj in
                    optionalCString(configuration.mtpPath) { draft in
                        optionalCString(configuration.chatTemplateFile) { template in
                            configuration.cacheTypeK.withCString { cacheK in
                                configuration.cacheTypeV.withCString { cacheV in
                                    optionalCString(configuration.tensorOverride) { tensor in
                                        optionalCString(configuration.speculativeType) { specType in
                                            optionalCString(configuration.pagedManifestPath) { pagedManifest in
                                                optionalCString(configuration.pagedTracePath) { pagedTracePath in
                                                    var native = noema_llama_server_configuration()
                                                    native.version = UInt32(NOEMA_LLAMA_SERVER_CONFIGURATION_VERSION)
                                                    native.size = UInt32(MemoryLayout<noema_llama_server_configuration>.size)
                                                    native.host = host
                                                    native.preferred_port = configuration.preferredPort
                                                    native.gguf_path = gguf
                                                    native.mmproj_path = mmproj
                                                    native.draft_model_path = draft
                                                    native.chat_template_file = template
                                                    native.reasoning_budget = configuration.reasoningBudget ?? Int32.min
                                                    native.use_jinja = configuration.useJinja ? 1 : 0
                                                    native.context_size = configuration.contextSize
                                                    native.context_shift = configuration.contextShift ? 1 : 0
                                                    native.gpu_layers = configuration.gpuLayers
                                                    native.threads = configuration.threads
                                                    native.threads_batch = configuration.threadsBatch
                                                    native.batch_size = configuration.batchSize
                                                    native.ubatch_size = configuration.ubatchSize
                                                    native.use_mmap = configuration.useMmap ? 1 : 0
                                                    native.use_mlock = configuration.useMlock ? 1 : 0
                                                    native.warmup = configuration.warmup ? 1 : 0
                                                    native.kv_offload = configuration.kvOffload ? 1 : 0
                                                    native.flash_attention = configuration.flashAttention ? 1 : 0
                                                    native.cache_type_k = cacheK
                                                    native.cache_type_v = cacheV
                                                    native.parallel_slots = configuration.parallelSlots
                                                    native.tensor_override = tensor
                                                    native.cpu_moe = configuration.cpuMoE ? 1 : 0
                                                    native.moe_expert_count = configuration.moeExpertCount ?? Int32.min
                                                    native.yarn_scale = configuration.yarnScale ?? -1
                                                    native.yarn_original_context = configuration.yarnOriginalContext ?? Int32.min
                                                    native.yarn_beta_fast = configuration.yarnBetaFast ?? -1
                                                    native.yarn_beta_slow = configuration.yarnBetaSlow ?? -1
                                                    native.cache_ram_mib = configuration.cacheRamMiB
                                                    native.ctx_checkpoints = configuration.ctxCheckpoints
                                                    native.speculative_type = specType
                                                    native.spec_draft_n_max = configuration.specDraftNMax ?? Int32.min
                                                    native.spec_draft_n_min = configuration.specDraftNMin ?? Int32.min
                                                    native.spec_draft_p_min = configuration.specDraftPMin ?? -1
                                                    native.spec_dynamic = configuration.specDynamic ? 1 : 0
                                                    native.kv_unified = configuration.unifiedKVCache ? 1 : 0
                                                    native.paged_mode = configuration.pagedMode.rawValue
                                                    native.paged_manifest_path = pagedManifest
                                                    native.paged_slots_per_layer = configuration.pagedSlotsPerLayer
                                                    native.paged_bank_budget_mib = configuration.pagedBankBudgetMiB
                                                    native.paged_io_threads = configuration.pagedIOThreads
                                                    native.paged_io_depth = configuration.pagedIODepth
                                                    native.paged_io_timeout_ms = configuration.pagedIOTimeoutMs
                                                    native.paged_prefetch = configuration.pagedPrefetch ? 1 : 0
                                                    native.paged_oracle_all_hit = configuration.pagedOracleAllHit ? 1 : 0
                                                    native.paged_trace = configuration.pagedTrace ? 1 : 0
                                                    native.paged_trace_path = pagedTracePath
                                                    native.paged_verify_checksums = configuration.pagedVerifyChecksums ? 1 : 0
                                                    native.paged_telemetry_interval_ms = configuration.pagedTelemetryIntervalMs
                                                    native.paged_waves = configuration.pagedWaves ? 1 : 0
                                                    native.paged_expert_major = configuration.pagedExpertMajor ? 1 : 0
                                                    return withUnsafePointer(to: native) { body($0) }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    public static func start(_ configuration: StartConfiguration) -> Int32 {
        withNativeConfiguration(configuration) { native in
            noema_llama_server_start_with_configuration(native)
        }
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

    /// Uses llama.cpp's no-allocation model/context construction to size the
    /// exact runtime configuration without committing the backing buffers.
    public static func memoryEstimate(
        ggufPath: String,
        mmprojPath: String? = nil,
        mtpPath: String? = nil,
        contextSize: Int,
        batchSize: Int,
        ubatchSize: Int,
        cacheTypeK: String,
        cacheTypeV: String,
        gpuLayers: Int,
        flashAttention: Bool,
        parallelSlots: Int,
        kvOffload: Bool,
        speculativeType: String?,
        specDraftNMax: Int,
        unifiedKVCache: Bool = true
    ) throws -> MemoryEstimate {
        guard let raw = noema_llama_server_memory_estimate_json(
            ggufPath,
            mmprojPath ?? "",
            mtpPath ?? "",
            Int32(clamping: contextSize),
            Int32(clamping: batchSize),
            Int32(clamping: ubatchSize),
            cacheTypeK,
            cacheTypeV,
            Int32(clamping: gpuLayers),
            flashAttention ? 1 : 0,
            Int32(clamping: parallelSlots),
            kvOffload ? 1 : 0,
            speculativeType ?? "",
            Int32(clamping: specDraftNMax),
            unifiedKVCache ? 1 : 0
        ) else {
            throw MemoryEstimateError(message: "memory_sizing_unavailable")
        }
        return try decodeMemoryEstimate(String(cString: raw))
    }

    private static func decodeMemoryEstimate(_ json: String) throws -> MemoryEstimate {
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(MemoryEstimateEnvelope.self, from: data) else {
            throw MemoryEstimateError(message: "invalid_memory_sizing_response")
        }
        guard envelope.status == "ok",
              let modelBytes = envelope.modelBytes,
              let contextBytes = envelope.contextBytes,
              let computeBytes = envelope.computeBytes,
              let projectorBytes = envelope.projectorBytes,
              let speculativeBytes = envelope.speculativeBytes,
              let totalBytes = envelope.totalBytes else {
            throw MemoryEstimateError(message: envelope.message ?? "memory_sizing_failed")
        }
        return MemoryEstimate(
            modelBytes: modelBytes,
            contextBytes: contextBytes,
            computeBytes: computeBytes,
            projectorBytes: projectorBytes,
            speculativeBytes: speculativeBytes,
            totalBytes: totalBytes,
            paged: envelope.paged
        )
    }

    public static func memoryEstimate(configuration: StartConfiguration) throws -> MemoryEstimate {
        // Paged configurations size through the struct-driven native path so
        // the sidecar/bank accounting participates; the resident path keeps
        // its long-standing flat call byte-for-byte.
        if configuration.pagedMode != .off {
            let json = withNativeConfiguration(configuration) { native -> String? in
                guard let raw = noema_llama_server_memory_estimate_json2(native) else { return nil }
                return String(cString: raw)
            }
            guard let json else {
                throw MemoryEstimateError(message: "memory_sizing_unavailable")
            }
            return try decodeMemoryEstimate(json)
        }
        return try memoryEstimate(
            ggufPath: configuration.ggufPath,
            mmprojPath: configuration.mmprojPath,
            mtpPath: configuration.mtpPath,
            contextSize: Int(configuration.contextSize),
            batchSize: Int(configuration.batchSize),
            ubatchSize: Int(configuration.ubatchSize),
            cacheTypeK: configuration.cacheTypeK,
            cacheTypeV: configuration.cacheTypeV,
            gpuLayers: Int(configuration.gpuLayers),
            flashAttention: configuration.flashAttention,
            parallelSlots: Int(configuration.parallelSlots),
            kvOffload: configuration.kvOffload,
            speculativeType: configuration.speculativeType,
            specDraftNMax: Int(configuration.specDraftNMax ?? 0),
            unifiedKVCache: configuration.unifiedKVCache
        )
    }

    /// JSON snapshot of the paged runtime's telemetry, or nil when paging is
    /// inactive.
    public static func pagedStatsJSON() -> String? {
        guard let raw = noema_llama_server_paged_stats_json() else { return nil }
        let json = String(cString: raw)
        return json.isEmpty ? nil : json
    }

    /// Applies memory-pressure mitigation to an active paged runtime
    /// (0 = normal, 1 = stop prefetch, 2 = shrink in-flight depth,
    /// 3 = cancel queued reads). Safe no-op when paging is off.
    public static func pagedApplyPressure(_ level: Int32) {
        noema_llama_server_paged_apply_pressure(level)
    }

    /// Fails the active streamed (paged mode 2) generation at the runtime:
    /// queued and in-flight expert reads are dropped and the request errors
    /// out promptly instead of paging on until the server notices the dead
    /// connection. Safe no-op when paging is off or nothing is generating.
    public static func pagedCancel() {
        noema_llama_server_paged_cancel()
    }

    // MARK: - Paged package conversion

    public struct PagedConvertError: LocalizedError, Sendable {
        public let message: String

        public init(message: String) {
            self.message = message
        }

        public var errorDescription: String? { message }
    }

    private final class PagedConvertProgressBox {
        let callback: @Sendable (Double, String) -> Void

        init(_ callback: @escaping @Sendable (Double, String) -> Void) {
            self.callback = callback
        }
    }

    /// Runs the native GGUF → `.noema-paged` converter (`noema_paged_convert`)
    /// synchronously on the calling thread; call it from a background task.
    /// `destinationDirectory` is the final package directory itself and must
    /// not exist yet; `alignment` <= 0 selects the native default (16384).
    /// `progress` receives a monotonic fraction in [0, 1] plus the native
    /// stage name ("preparing", "resident", "experts", "verifying",
    /// "finishing") on the converter's thread. Cancellation: the callback
    /// trampoline checks `Task.isCancelled` on every progress tick, so
    /// cancelling the task that runs this call aborts the build (staging is
    /// deleted natively) and surfaces as `CancellationError`.
    public static func pagedConvert(
        sourceGGUF: URL,
        destinationDirectory: URL,
        alignment: Int32 = 0,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) throws {
        let box = PagedConvertProgressBox(progress)
        var errorPointer: UnsafePointer<CChar>? = nil
        let code = withExtendedLifetime(box) { () -> Int32 in
            let userData = Unmanaged.passUnretained(box).toOpaque()
            return sourceGGUF.path.withCString { source in
                destinationDirectory.path.withCString { destination in
                    noema_paged_convert(source, destination, alignment, { fraction, stage, userData in
                        guard let userData else { return 0 }
                        let box = Unmanaged<PagedConvertProgressBox>.fromOpaque(userData).takeUnretainedValue()
                        box.callback(Double(fraction), stage.map { String(cString: $0) } ?? "")
                        return Task.isCancelled ? 1 : 0
                    }, userData, &errorPointer)
                }
            }
        }
        switch code {
        case 0:
            return
        case 2:
            throw CancellationError()
        default:
            let message = errorPointer.map { String(cString: $0) } ?? ""
            throw PagedConvertError(message: message.isEmpty ? "paged conversion failed" : message)
        }
    }
}
