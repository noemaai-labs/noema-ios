import SwiftUI
import NoemaPackages
import os

@_silgen_name("app_available_memory")
fileprivate func c_app_available_memory() -> UInt

@_silgen_name("app_memory_footprint")
fileprivate func c_app_memory_footprint() -> UInt

enum ModelRAMAdvisor {
    struct MemoryBudgetSnapshot: Equatable, Sendable {
        let bytes: Int64?
        let isLiveProcessLimit: Bool
    }

    /// Load-time settings that affect llama.cpp allocations independently of model-file size.
    /// `n_batch` limits logical prompt batches while `n_ubatch` is the physical graph size;
    /// the latter is usually the stronger compute-buffer driver.
    struct RuntimeConfiguration: Equatable, Sendable {
        var evaluationBatchSize: Int
        var physicalBatchSize: Int
        var flashAttention: Bool
        var projectorFileBytes: Int64
        var modelPath: String?
        var projectorPath: String?
        var mtpPath: String?
        var speculativeType: String?
        var mtpEnabled: Bool { speculativeType == "draft-mtp" }
        var gpuLayerCount: Int
        var parallelSlots: Int
        var kvCacheOffload: Bool
        var unifiedKVCache: Bool
        var specDraftNMax: Int

        static let conservativeDefault = Self(
            evaluationBatchSize: ModelSettings.defaultEvaluationBatchSize,
            physicalBatchSize: ModelSettings.defaultPhysicalBatchSize,
            flashAttention: true,
            projectorFileBytes: 0,
            modelPath: nil,
            projectorPath: nil,
            mtpPath: nil,
            speculativeType: nil,
            gpuLayerCount: -1,
            parallelSlots: 1,
            kvCacheOffload: true,
            unifiedKVCache: true,
            specDraftNMax: 0
        )

        init(
            evaluationBatchSize: Int = ModelSettings.defaultEvaluationBatchSize,
            physicalBatchSize: Int = ModelSettings.defaultPhysicalBatchSize,
            flashAttention: Bool = true,
            projectorFileBytes: Int64 = 0,
            modelPath: String? = nil,
            projectorPath: String? = nil,
            mtpPath: String? = nil,
            mtpEnabled: Bool = false,
            speculativeType: String? = nil,
            gpuLayerCount: Int = -1,
            parallelSlots: Int = 1,
            kvCacheOffload: Bool = true,
            unifiedKVCache: Bool = true,
            specDraftNMax: Int = 0
        ) {
            self.evaluationBatchSize = max(1, evaluationBatchSize)
            self.physicalBatchSize = max(1, min(physicalBatchSize, evaluationBatchSize))
            self.flashAttention = flashAttention
            self.projectorFileBytes = max(0, projectorFileBytes)
            self.modelPath = modelPath
            self.projectorPath = projectorPath
            self.mtpPath = mtpPath
            self.speculativeType = speculativeType ?? (mtpEnabled ? "draft-mtp" : nil)
            self.gpuLayerCount = gpuLayerCount
            self.parallelSlots = max(1, parallelSlots)
            self.kvCacheOffload = kvCacheOffload
            self.unifiedKVCache = unifiedKVCache
            self.specDraftNMax = max(0, specDraftNMax)
        }

        static func resolved(from settings: ModelSettings, modelURL: URL? = nil) -> Self {
            let resolvedModelURL = modelURL.flatMap(resolveGGUFURL)
            let projectorPath = settings.loadVisionProjector
                ? resolvedModelURL.flatMap { ProjectorLocator.projectorPath(alongside: $0) }
                : nil
            let mtpPath = settings.speculativeDecoding.mtpEnabled
                ? resolvedModelURL.flatMap { MtpLocator.mtpPath(alongside: $0) }
                : nil
            let hasEmbeddedMTP = settings.speculativeDecoding.mtpEnabled
                && (resolvedModelURL.map { GGUFMetadata.hasMTP(at: $0) } ?? false)
            let supportsOffload = DeviceGPUInfo.supportsGPUOffload
            let gpuLayers: Int = {
                guard supportsOffload else { return 0 }
                if settings.gpuLayers < 0 { return 1_000_000 }
                return max(0, settings.gpuLayers)
            }()
            return Self(
                evaluationBatchSize: settings.resolvedEvaluationBatchSize,
                physicalBatchSize: settings.resolvedPhysicalBatchSize,
                flashAttention: settings.flashAttention,
                projectorFileBytes: fileSize(atPath: projectorPath),
                modelPath: resolvedModelURL?.path,
                projectorPath: projectorPath,
                mtpPath: mtpPath,
                speculativeType: settings.speculativeDecoding.mtpEnabled && (mtpPath != nil || hasEmbeddedMTP)
                    ? "draft-mtp"
                    : nil,
                gpuLayerCount: gpuLayers,
                parallelSlots: 1,
                kvCacheOffload: supportsOffload && gpuLayers > 0 && settings.kvCacheOffload,
                unifiedKVCache: settings.unifiedKVCache,
                specDraftNMax: settings.speculativeDecoding.mtpEnabled
                    ? settings.speculativeDecoding.effectiveMTPDraftNMax
                    : 0
            )
        }

        static func resolved(from configuration: LlamaServerBridge.StartConfiguration) -> Self {
            Self(
                evaluationBatchSize: Int(configuration.batchSize),
                physicalBatchSize: Int(configuration.ubatchSize),
                flashAttention: configuration.flashAttention,
                projectorFileBytes: fileSize(atPath: configuration.mmprojPath),
                modelPath: configuration.ggufPath,
                projectorPath: configuration.mmprojPath,
                mtpPath: configuration.mtpPath,
                speculativeType: configuration.speculativeType,
                gpuLayerCount: Int(configuration.gpuLayers),
                parallelSlots: Int(configuration.parallelSlots),
                kvCacheOffload: configuration.kvOffload,
                unifiedKVCache: configuration.unifiedKVCache,
                specDraftNMax: Int(configuration.specDraftNMax ?? 0)
            )
        }

        private static func resolveGGUFURL(_ url: URL) -> URL? {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return nil
            }
            if isDirectory.boolValue {
                return InstalledModelsStore.firstGGUF(in: url)
            }
            return url
        }

        private static func fileSize(atPath path: String?) -> Int64 {
            guard let path,
                  let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber else {
                return 0
            }
            return max(0, size.int64Value)
        }
    }

    struct EstimateBreakdown: Equatable, Sendable {
        let weights: Int64
        let kvCache: Int64
        let recurrentState: Int64
        let computeBuffers: Int64
        let visionProjector: Int64
        let auxiliaryModels: Int64
        let fixedOverhead: Int64
        let safetyMargin: Int64

        var estimate: Int64 {
            saturatedSum([
                weights, kvCache, recurrentState, computeBuffers,
                visionProjector, auxiliaryModels, fixedOverhead, safetyMargin
            ])
        }
    }

    struct GGUFKVCacheEstimate: Equatable, Sendable {
        let kCacheQuant: CacheQuant
        let vCacheQuant: CacheQuant
        let mlxQuantizationBits: Int?
        let mlxQuantizationGroupSize: Int

        static let f16F16 = Self(kCacheQuant: .f16, vCacheQuant: .f16)

        init(
            kCacheQuant: CacheQuant = .f16,
            vCacheQuant: CacheQuant = .f16,
            mlxQuantizationBits: Int? = nil,
            mlxQuantizationGroupSize: Int = 64
        ) {
            self.kCacheQuant = kCacheQuant
            self.vCacheQuant = vCacheQuant
            self.mlxQuantizationBits = mlxQuantizationBits
            self.mlxQuantizationGroupSize = mlxQuantizationGroupSize
        }

        var combinedBytesPerElement: Double {
            kBytesPerElement + vBytesPerElement
        }

        /// Bytes per cached element for the K cache (one element = one key scalar).
        var kBytesPerElement: Double {
            mlxBytesPerElement ?? Self.bytesPerElement(for: kCacheQuant)
        }
        /// Bytes per cached element for the V cache.
        var vBytesPerElement: Double {
            mlxBytesPerElement ?? Self.bytesPerElement(for: vCacheQuant)
        }

        var displayLabel: String {
            if let mlxQuantizationBits {
                return "\(mlxQuantizationBits)-BIT / \(mlxQuantizationBits)-BIT"
            }
            return "\(kCacheQuant.rawValue) / \(vCacheQuant.rawValue)"
        }

        static func resolved(from settings: ModelSettings) -> Self {
            if let mlxBits = settings.mlxKVCacheQuantization.bits {
                return Self(
                    mlxQuantizationBits: mlxBits,
                    mlxQuantizationGroupSize: settings.resolvedMLXKVCacheGroupSize
                )
            }
            return Self(
                kCacheQuant: settings.kCacheQuant,
                vCacheQuant: settings.flashAttention ? settings.vCacheQuant : .f16
            )
        }

        static func resolved(from configuration: LlamaServerBridge.StartConfiguration) -> Self {
            Self(
                kCacheQuant: CacheQuant(rawValue: configuration.cacheTypeK.uppercased()) ?? .f16,
                vCacheQuant: CacheQuant(rawValue: configuration.cacheTypeV.uppercased()) ?? .f16
            )
        }

        private var mlxBytesPerElement: Double? {
            guard let bits = mlxQuantizationBits else { return nil }
            // MLX affine quantization stores packed values plus one Float16 scale
            // and one Float16 bias per group.
            let packedValueBytes = Double(bits) / 8.0
            let metadataBytes = 4.0 / Double(max(1, mlxQuantizationGroupSize))
            return packedValueBytes + metadataBytes
        }

        private static func bytesPerElement(for quant: CacheQuant) -> Double {
            // Exact bytes/element from the vendored ggml block layouts:
            // q8_0 = 34/32, q5_0 = 22/32, q5_1 = 24/32, q4_0 = 18/32,
            // q4_1 = 20/32, iq4_nl = 18/32.
            switch quant {
            case .f32:
                return 4.0
            case .f16:
                return 2.0
            case .q8_0:
                return 34.0 / 32.0
            case .q5_0:
                return 22.0 / 32.0
            case .q5_1:
                return 24.0 / 32.0
            case .q4_0:
                return 18.0 / 32.0
            case .q4_1:
                return 20.0 / 32.0
            case .iq4_nl:
                return 18.0 / 32.0
            }
        }
    }

    struct GGUFLaunchFitAssessment: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case fits
            case doesNotFit
            case unavailable
        }

        let status: Status
        let estimatedIncrementalBytes: Int64?
        let requiredIncrementalBytes: Int64?
        let availableHeadroomBytes: Int64?
        let message: String?
    }

    private struct ExactSizingKey: Hashable, Sendable {
        let modelPath: String
        let modelFileSize: Int64
        let modelModificationTime: Int64
        let projectorPath: String?
        let mtpPath: String?
        let contextLength: Int
        let evaluationBatchSize: Int
        let physicalBatchSize: Int
        let cacheTypeK: String
        let cacheTypeV: String
        let gpuLayerCount: Int
        let flashAttention: Bool
        let parallelSlots: Int
        let kvCacheOffload: Bool
        let unifiedKVCache: Bool
        let speculativeType: String?
        let specDraftNMax: Int
        // Paged (Noema Overfit) launches size bank + staging on top of the
        // dense load, and the bank budget can differ between launches of the
        // SAME model file (resolved from live headroom). Without these in the
        // key, a flat settings-card sizing and a paged launch sizing collide
        // and the definitive fit gate judges a stale configuration.
        let pagedMode: Int32
        let pagedManifestPath: String?
        let pagedBankBudgetMiB: Int32
        let pagedIOThreads: Int32
        let pagedIODepth: Int32
        let pagedWaves: Bool
        let pagedExpertMajor: Bool

        func hasSameProfile(as other: Self) -> Bool {
            modelPath == other.modelPath
                && modelFileSize == other.modelFileSize
                && modelModificationTime == other.modelModificationTime
                && projectorPath == other.projectorPath
                && mtpPath == other.mtpPath
                && evaluationBatchSize == other.evaluationBatchSize
                && physicalBatchSize == other.physicalBatchSize
                && cacheTypeK == other.cacheTypeK
                && cacheTypeV == other.cacheTypeV
                && gpuLayerCount == other.gpuLayerCount
                && flashAttention == other.flashAttention
                && parallelSlots == other.parallelSlots
                && kvCacheOffload == other.kvCacheOffload
                && unifiedKVCache == other.unifiedKVCache
                && speculativeType == other.speculativeType
                && specDraftNMax == other.specDraftNMax
                && pagedMode == other.pagedMode
                && pagedManifestPath == other.pagedManifestPath
                && pagedBankBudgetMiB == other.pagedBankBudgetMiB
                && pagedIOThreads == other.pagedIOThreads
                && pagedIODepth == other.pagedIODepth
                && pagedWaves == other.pagedWaves
                && pagedExpertMajor == other.pagedExpertMajor
        }
    }

    struct ExactWorkingSetSample: Equatable, Sendable {
        let contextLength: Int
        let bytes: Int64
    }

    /// Settings is not a model-launch boundary. Preserve the measured curve that makes
    /// recommendations accurate, but never calibrate at an extreme advertised maximum.
    /// Embedded MTP sizes a second context, so it gets a deliberately smaller window.
    static func settingsExactSizingContextLimit(
        runtimeConfiguration: RuntimeConfiguration
    ) -> Int {
        runtimeConfiguration.mtpEnabled ? 8_192 : 32_768
    }

    static func permitsSettingsExactSizing(
        contextLength: Int,
        runtimeConfiguration: RuntimeConfiguration
    ) -> Bool {
        contextLength > 0
            && contextLength <= settingsExactSizingContextLimit(
                runtimeConfiguration: runtimeConfiguration
            )
    }

    static func settingsExactSizingContexts(
        selectedContext: Int,
        lowerBound: Int,
        upperBound: Int,
        runtimeConfiguration: RuntimeConfiguration
    ) -> [Int] {
        let safeUpper = min(
            max(1, upperBound),
            settingsExactSizingContextLimit(runtimeConfiguration: runtimeConfiguration)
        )
        let safeLower = min(safeUpper, max(1, lowerBound))
        let baseline = min(safeUpper, max(safeLower, selectedContext))
        let distanceToLower = baseline - safeLower
        let distanceToUpper = safeUpper - baseline
        let calibration = distanceToUpper >= distanceToLower ? safeUpper : safeLower
        return calibration == baseline ? [baseline] : [baseline, calibration]
    }

    private static let exactSizingCache = OSAllocatedUnfairLock<
        [ExactSizingKey: LlamaServerBridge.MemoryEstimate]
    >(initialState: [:])
    // llama.cpp backend initialization is process-global. Serialize settings-card sizing
    // with launch-time sizing so tapping Load while the card says "Checking…" cannot run
    // two no-allocation backend passes concurrently.
    private static let exactSizingExecutionLock = OSAllocatedUnfairLock<Void>(initialState: ())

    private static func exactSizingKey(
        contextLength: Int,
        kvCacheEstimate: GGUFKVCacheEstimate,
        runtimeConfiguration: RuntimeConfiguration,
        serverConfiguration: LlamaServerBridge.StartConfiguration? = nil
    ) -> ExactSizingKey? {
        guard let modelPath = runtimeConfiguration.modelPath, !modelPath.isEmpty else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: modelPath)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modificationTime = Int64((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return ExactSizingKey(
            modelPath: modelPath,
            modelFileSize: fileSize,
            modelModificationTime: modificationTime,
            projectorPath: runtimeConfiguration.projectorPath,
            mtpPath: runtimeConfiguration.mtpPath,
            contextLength: max(1, contextLength),
            evaluationBatchSize: runtimeConfiguration.evaluationBatchSize,
            physicalBatchSize: runtimeConfiguration.physicalBatchSize,
            cacheTypeK: kvCacheEstimate.kCacheQuant.rawValue,
            cacheTypeV: kvCacheEstimate.vCacheQuant.rawValue,
            gpuLayerCount: runtimeConfiguration.gpuLayerCount,
            flashAttention: runtimeConfiguration.flashAttention,
            parallelSlots: runtimeConfiguration.parallelSlots,
            kvCacheOffload: runtimeConfiguration.kvCacheOffload,
            unifiedKVCache: runtimeConfiguration.unifiedKVCache,
            speculativeType: runtimeConfiguration.speculativeType,
            specDraftNMax: runtimeConfiguration.specDraftNMax,
            pagedMode: serverConfiguration?.pagedMode.rawValue ?? 0,
            pagedManifestPath: serverConfiguration?.pagedManifestPath,
            pagedBankBudgetMiB: serverConfiguration?.pagedBankBudgetMiB ?? 0,
            pagedIOThreads: serverConfiguration?.pagedIOThreads ?? 0,
            pagedIODepth: serverConfiguration?.pagedIODepth ?? 0,
            pagedWaves: serverConfiguration?.pagedWaves ?? false,
            pagedExpertMajor: serverConfiguration?.pagedExpertMajor ?? false
        )
    }

    private static func cachedExactEstimate(for key: ExactSizingKey?) -> LlamaServerBridge.MemoryEstimate? {
        guard let key else { return nil }
        return exactSizingCache.withLock { cache in
            cache[key]
        }
    }

    private static func cacheExactEstimate(_ estimate: LlamaServerBridge.MemoryEstimate, for key: ExactSizingKey) {
        exactSizingCache.withLock { cache in
            cache[key] = estimate
            if cache.count > 48 {
                cache.remove(at: cache.startIndex)
            }
        }
    }

    private static func cachedExactWorkingSetSamples(
        for key: ExactSizingKey?,
        runtimeConfiguration: RuntimeConfiguration
    ) -> [ExactWorkingSetSample] {
        guard let key else { return [] }
        let reserve = runtimeTransientReserveBytes(runtimeConfiguration: runtimeConfiguration)
        return exactSizingCache.withLock { cache in
            cache.compactMap { cachedKey, estimate in
                guard cachedKey.hasSameProfile(as: key) else { return nil }
                return ExactWorkingSetSample(
                    contextLength: cachedKey.contextLength,
                    bytes: saturatedSum([
                        clampedInt64(Double(estimate.totalBytes)),
                        // Paged sizing keeps the staging buffer outside totalBytes.
                        clampedInt64(Double(estimate.paged?.stagingBytes ?? 0)),
                        reserve
                    ])
                )
            }
            .sorted { $0.contextLength < $1.contextLength }
        }
    }

    /// Interpolates a model-specific curve made from llama.cpp no-allocation samples.
    /// Context and KV allocations are predominantly linear between graph-size boundaries;
    /// using two real samples preserves the true per-token slope without doing native model
    /// setup on every slider tick. Values outside the sampled interval use the nearest
    /// measured slope and are clamped to a non-decreasing curve.
    static func interpolatedExactWorkingSet(
        contextLength: Int,
        samples: [ExactWorkingSetSample]
    ) -> Int64? {
        let samples = samples.sorted { $0.contextLength < $1.contextLength }
        guard samples.count >= 2 else { return nil }
        if let exact = samples.first(where: { $0.contextLength == contextLength }) {
            return exact.bytes
        }

        let lower: ExactWorkingSetSample
        let upper: ExactWorkingSetSample
        if contextLength < samples[0].contextLength {
            lower = samples[0]
            upper = samples[1]
        } else if contextLength > samples[samples.count - 1].contextLength {
            lower = samples[samples.count - 2]
            upper = samples[samples.count - 1]
        } else {
            guard let upperIndex = samples.firstIndex(where: { $0.contextLength > contextLength }),
                  upperIndex > 0 else { return nil }
            lower = samples[upperIndex - 1]
            upper = samples[upperIndex]
        }

        let contextSpan = upper.contextLength - lower.contextLength
        guard contextSpan > 0 else { return max(lower.bytes, upper.bytes) }
        let byteSpan = max(0, upper.bytes - lower.bytes)
        let slope = Double(byteSpan) / Double(contextSpan)
        let projected = Double(lower.bytes)
            + Double(contextLength - lower.contextLength) * slope
        return max(0, clampedInt64(projected.rounded(.up)))
    }

    /// Performs the definitive GGUF fit decision. A sizing failure is deliberately
    /// non-rejecting: until llama.cpp has parsed the metadata and produced a complete
    /// no-allocation breakdown, the UI may warn but must not claim the model cannot run.
    static func definitiveGGUFLaunchFitAssessment(
        contextLength: Int,
        kvCacheEstimate: GGUFKVCacheEstimate,
        runtimeConfiguration: RuntimeConfiguration,
        serverConfiguration: LlamaServerBridge.StartConfiguration? = nil
    ) async -> GGUFLaunchFitAssessment {
        let effectiveContextLength = serverConfiguration.map { Int($0.contextSize) } ?? contextLength
        let effectiveKVCacheEstimate = serverConfiguration.map(GGUFKVCacheEstimate.resolved(from:))
            ?? kvCacheEstimate
        let effectiveRuntimeConfiguration = serverConfiguration.map(RuntimeConfiguration.resolved(from:))
            ?? runtimeConfiguration
        guard let key = exactSizingKey(
            contextLength: effectiveContextLength,
            kvCacheEstimate: effectiveKVCacheEstimate,
            runtimeConfiguration: effectiveRuntimeConfiguration,
            serverConfiguration: serverConfiguration
        ) else {
            return GGUFLaunchFitAssessment(
                status: .unavailable,
                estimatedIncrementalBytes: nil,
                requiredIncrementalBytes: nil,
                availableHeadroomBytes: planningBudgetBytes(),
                message: "metadata_not_ready"
            )
        }

        let exact: LlamaServerBridge.MemoryEstimate
        if let cached = cachedExactEstimate(for: key) {
            exact = cached
        } else {
            do {
                exact = try await Task.detached(priority: .utility) {
                    try exactSizingExecutionLock.withLock { _ in
                        // A profile-calibration task and the committed-context check can
                        // request the same point concurrently. Recheck after acquiring the
                        // process-global llama.cpp lock so the second caller uses the sample
                        // the first caller just produced instead of parsing the GGUF twice.
                        if let cached = cachedExactEstimate(for: key) {
                            return cached
                        }
                        if let serverConfiguration {
                            return try LlamaServerBridge.memoryEstimate(
                                configuration: serverConfiguration
                            )
                        }
                        return try LlamaServerBridge.memoryEstimate(
                            ggufPath: key.modelPath,
                            mmprojPath: key.projectorPath,
                            mtpPath: key.mtpPath,
                            contextSize: key.contextLength,
                            batchSize: key.evaluationBatchSize,
                            ubatchSize: key.physicalBatchSize,
                            cacheTypeK: key.cacheTypeK,
                            cacheTypeV: key.cacheTypeV,
                            gpuLayers: key.gpuLayerCount,
                            flashAttention: key.flashAttention,
                            parallelSlots: key.parallelSlots,
                            kvOffload: key.kvCacheOffload,
                            speculativeType: key.speculativeType,
                            specDraftNMax: key.specDraftNMax,
                            unifiedKVCache: key.unifiedKVCache
                        )
                    }
                }.value
                cacheExactEstimate(exact, for: key)
            } catch {
                return GGUFLaunchFitAssessment(
                    status: .unavailable,
                    estimatedIncrementalBytes: nil,
                    requiredIncrementalBytes: nil,
                    availableHeadroomBytes: planningBudgetBytes(),
                    message: error.localizedDescription
                )
            }
        }

        // `modelBytes` is the logical size of llama.cpp's model buffers. Noema always
        // launches GGUFs with mmap enabled, and on Apple platforms those read-only model
        // buffers are backed directly by the GGUF mapping (including Metal's no-copy
        // buffers). Charging their entire virtual size again against
        // os_proc_available_memory() turns a total working-set description into a false
        // incremental allocation and is especially damaging for large quantized models.
        //
        // Context/recurrent state, compute buffers, the separately allocated projector,
        // and speculative runtime allocations are the no-allocation categories that do
        // consume new process headroom for this launch. Any measured footprint beyond
        // these categories is learned by recordSuccessfulGGUFLaunch as transient reserve.
        //
        // Paged (Noema Overfit) launches are the exception to the mmap exemption:
        // they force useMmap off, dense-load the resident weights, and allocate the
        // expert bank cache outright, so their model buffers always count against
        // process headroom. A flat sizing call on a paged install lacks the
        // bank/staging categories entirely; backfill them from the launch plan so
        // the gate never judges resident-alone.
        let pagedBackfill: PagedEstimateFigures? = (serverConfiguration == nil && exact.paged == nil)
            ? pagedEstimateFigures(forModelPath: key.modelPath)
            : nil
        let pagedExtraBytes = saturatedSum([
            clampedInt64(Double(exact.paged?.stagingBytes ?? 0)),
            pagedBackfill.map { saturatedSum([$0.bankBudgetBytes, $0.stagingBytes]) } ?? 0
        ])
        let chargeMappedModelBuffers: Bool
#if os(macOS) || targetEnvironment(macCatalyst)
        // The macOS fallback is a physical-memory budget, not iOS process headroom.
        chargeMappedModelBuffers = true
#else
        chargeMappedModelBuffers = (serverConfiguration?.pagedMode ?? .off) != .off
            || exact.paged != nil
            || pagedBackfill != nil
#endif
        let estimated = saturatedSum([
            incrementalProcessAllocationBytes(
                modelBytes: exact.modelBytes,
                contextBytes: exact.contextBytes,
                computeBytes: exact.computeBytes,
                projectorBytes: exact.projectorBytes,
                speculativeBytes: exact.speculativeBytes,
                chargeMappedModelBuffers: chargeMappedModelBuffers
            ),
            pagedExtraBytes
        ])
        let required = saturatedSum([
            estimated,
            runtimeTransientReserveBytes(runtimeConfiguration: runtimeConfiguration)
        ])
        let available = planningBudgetBytes()
        let status: GGUFLaunchFitAssessment.Status = {
            guard let available else { return .unavailable }
            guard required <= available else { return .doesNotFit }
#if os(macOS) || targetEnvironment(macCatalyst)
            return .fits
#else
            // Allocation headroom alone is insufficient on unified memory: mmap-backed
            // weights become resident as inference touches them. Device testing on 6 GB-class
            // process limits shows that allowing a broad logical overcommit can launch but
            // then OOM at large contexts. Enforce the same measured working-set ceiling used
            // by the recommendation UI before calling a configuration a fit.
            let processLimit = liveProcessMemoryLimitBytes(
                liveAvailable: available,
                currentFootprint: currentFootprintBytes()
            ) ?? currentMemoryBudgetSnapshot().bytes
            guard let workingSetLimit = advisoryWorkingSetLimitBytes(
                processLimitBytes: processLimit,
                runtimeConfiguration: runtimeConfiguration
            ) else { return .fits }
            let totalWorkingSet = saturatedSum([
                clampedInt64(Double(exact.totalBytes)),
                pagedExtraBytes,
                runtimeTransientReserveBytes(runtimeConfiguration: runtimeConfiguration)
            ])
            return totalWorkingSet <= workingSetLimit ? .fits : .doesNotFit
#endif
        }()
        return GGUFLaunchFitAssessment(
            status: status,
            estimatedIncrementalBytes: estimated,
            requiredIncrementalBytes: required,
            availableHeadroomBytes: available,
            message: nil
        )
    }

    /// Converts llama.cpp's exact logical buffer breakdown into the incremental bytes that
    /// count against iOS process headroom. The main GGUF model is mmap-backed by Noema's
    /// runtime, so its logical model-buffer size is intentionally not charged a second time.
    /// The argument remains explicit to make that distinction visible at every call site.
    static func incrementalProcessAllocationBytes(
        modelBytes: UInt64,
        contextBytes: UInt64,
        computeBytes: UInt64,
        projectorBytes: UInt64,
        speculativeBytes: UInt64,
        chargeMappedModelBuffers: Bool = false
    ) -> Int64 {
        var allocations = [
            clampedInt64(Double(contextBytes)),
            clampedInt64(Double(computeBytes)),
            clampedInt64(Double(projectorBytes)),
            clampedInt64(Double(speculativeBytes))
        ]
        if chargeMappedModelBuffers {
            allocations.append(clampedInt64(Double(modelBytes)))
        }
        return saturatedSum(allocations)
    }

    /// Returns the current available bytes the app may allocate before hitting its limit.
    /// Uses os_proc_available_memory via C bridge. Returns nil if unavailable or zero.
    private static func availableMemoryBytes() -> Int64? {
        let v = Int64(c_app_available_memory())
        return v > 0 ? v : nil
    }

    /// Current resident footprint reported by the same process-level diagnostics bridge.
    private static func currentFootprintBytes() -> Int64? {
        let value = Int64(c_app_memory_footprint())
        return value > 0 ? value : nil
    }

    /// Reconstructs the current process allocation limit from the app's live footprint and
    /// the additional bytes the operating system reports that this process may allocate.
    static func liveProcessMemoryLimitBytes(
        liveAvailable: Int64?,
        currentFootprint: Int64?
    ) -> Int64? {
        guard let liveAvailable, liveAvailable > 0,
              let currentFootprint, currentFootprint > 0 else { return nil }
        return saturatedSum([liveAvailable, currentFootprint])
    }

    /// Budget intended for user-facing diagnostics. On iOS-family platforms this reports the
    /// live process allocation limit, not a value inferred from physical RAM. The device-table
    /// estimate remains a fallback for platforms/readings where a live limit is unavailable.
    static func currentMemoryBudgetSnapshot() -> MemoryBudgetSnapshot {
        let conservativeBudget = DeviceRAMInfo.current().conservativeLimitBytes()
#if os(macOS) || targetEnvironment(macCatalyst)
        return MemoryBudgetSnapshot(bytes: conservativeBudget, isLiveProcessLimit: false)
#else
        if let liveLimit = liveProcessMemoryLimitBytes(
            liveAvailable: availableMemoryBytes(),
            currentFootprint: currentFootprintBytes()
        ) {
            return MemoryBudgetSnapshot(bytes: liveLimit, isLiveProcessLimit: true)
        }
        return MemoryBudgetSnapshot(bytes: conservativeBudget, isLiveProcessLimit: false)
#endif
    }

    /// Soft ceiling for user-facing context recommendations. Unlike the hard launch gate,
    /// this compares the complete logical working set with the process limit so mmap-backed
    /// weights still contribute to unified-memory pressure. Standard GGUFs get only a small
    /// 11% logical overcommit because clean mapped pages are reclaimable. Ultra-low-bit Metal
    /// kernels do not get that allowance: device launches show their runtime workspace is much
    /// less predictable than the compact Q1/Q2 file size suggests.
    static func advisoryWorkingSetLimitBytes(
        processLimitBytes: Int64?,
        mappedWorkingSetOvercommitRatio: Double? = nil,
        runtimeConfiguration: RuntimeConfiguration? = nil
    ) -> Int64? {
        guard let processLimitBytes, processLimitBytes > 0 else { return nil }
        let ratio: Double
        if let mappedWorkingSetOvercommitRatio {
            ratio = max(1.0, mappedWorkingSetOvercommitRatio)
        } else {
#if os(macOS) || targetEnvironment(macCatalyst)
            ratio = 1.0
#else
            ratio = (runtimeConfiguration.map(additionalMetalSafetyReserveBytes) ?? 0) > 0
                ? 1.0
                : 1.11
#endif
        }
        return clampedInt64(Double(processLimitBytes) * ratio)
    }

    /// Incremental headroom for a new allocation. A positive `os_proc_available_memory()`
    /// reading is authoritative on iOS and is never reduced by the static device table.
    /// The table is used only when the OS reading is absent or zero; in that fallback case,
    /// subtract the current footprint so a total-RAM budget is converted to headroom.
    static func mobilePlanningBudgetBytes(
        conservativeBudget: Int64?,
        liveAvailable: Int64?,
        currentFootprint: Int64?,
        reserveBytes: Int64 = 0
    ) -> Int64? {
        let reserve = max(0, reserveBytes)
        if let liveAvailable, liveAvailable > 0 {
            return max(0, liveAvailable - reserve)
        }
        guard let conservativeBudget, conservativeBudget > 0 else { return nil }
        let fallbackHeadroom: Int64
        if let currentFootprint, currentFootprint > 0 {
            fallbackHeadroom = max(0, conservativeBudget - currentFootprint)
        } else {
            fallbackHeadroom = conservativeBudget
        }
        return max(0, fallbackHeadroom - reserve)
    }

    private static func planningBudgetBytes() -> Int64? {
        let conservativeBudget = DeviceRAMInfo.current().conservativeLimitBytes()
#if os(macOS) || targetEnvironment(macCatalyst)
        return conservativeBudget
#else
        return mobilePlanningBudgetBytes(
            conservativeBudget: conservativeBudget,
            liveAvailable: availableMemoryBytes(),
            currentFootprint: currentFootprintBytes()
        )
#endif
    }
    /// Multiplier from quant file size to resident weight bytes.
    ///
    /// With `mmap` on (the default for GGUF), the quantized weights are mapped
    /// directly and stay quantized in RAM, so resident weights ≈ file size. The
    /// small margin covers allocator slop and the non-mmap path; it is NOT meant
    /// to absorb the KV cache or compute buffers, which are accounted separately.
    private static func baseWeightsMultiplier(for format: ModelFormat) -> Double {
        switch format {
        case .gguf: return 1.05
        case .mlx:  return 1.1   // MLX may keep some tensors in higher precision
        case .et:  return 1.1
        case .ane: return 1.0
        case .afm: return 1.0
        case .coreai: return 1.0
        }
    }

    /// Approximate hidden size from known quant sizes when explicit metadata is unavailable.
    /// This is a heuristic to scale KV cache cost with model capacity.
    private static func approximateHiddenSize(format: ModelFormat, sizeBytes: Int64) -> Int {
        // Heuristic buckets derived from common Llama/Mistral quants
        let gb = Double(sizeBytes) / 1_073_741_824.0
        switch format {
        case .gguf:
            if gb < 3.0 { return 3072 }     // very small (e.g., 3B/4B)
            if gb < 6.0 { return 4096 }     // 7B class
            if gb < 12.0 { return 5120 }    // 13B class
            if gb < 24.0 { return 6656 }    // 30B class
            return 8192                      // 70B class and above
        case .mlx, .ane, .et, .afm, .coreai:
            // MLX/Apple/ET models vary widely; use a modest default
            if gb < 3.0 { return 3072 }
            if gb < 6.0 { return 4096 }
            if gb < 12.0 { return 5120 }
            return 6144
        }
    }

    /// Per-token KV-cache cost in bytes for a *single* context position, summed across all
    /// layers and across both the K and V caches. Multiply by context length for total KV
    /// bytes; divide the available budget by it to get the max context that fits.
    ///
    /// When the model exposes its real attention shape (`head_count_kv`, plus `key_length` /
    /// `value_length` or a derivable head dim), this is the exact allocation llama.cpp makes:
    ///   per_token = layers · ( n_kv_heads · head_dim_k · k_bytes  +  n_kv_heads · head_dim_v · v_bytes )
    /// Otherwise it falls back to a coarse `hidden · gqaRatio` heuristic.
    private static func kvBytesPerToken(format: ModelFormat,
                                        sizeBytes: Int64,
                                        layerCount: Int?,
                                        moeInfo: MoEInfo?,
                                        kvCacheEstimate: GGUFKVCacheEstimate) -> Double {
        let resolvedLayerCount = moeInfo?.attentionLayerCount
            ?? moeInfo?.totalLayerCount
            ?? layerCount
            ?? 32
        guard resolvedLayerCount > 0 else { return 0 }
        let layers = Double(resolvedLayerCount)

        // Bytes per cached scalar. GGUF and MLX honour the configured cache
        // precision; the remaining runtimes keep an f16 cache.
        let kBytes: Double
        let vBytes: Double
        switch format {
        case .gguf, .mlx:
            kBytes = kvCacheEstimate.kBytesPerElement
            vBytes = kvCacheEstimate.vBytesPerElement
        case .ane, .et, .afm, .coreai:
            kBytes = 2.0
            vBytes = 2.0
        }

        // Exact path: real attention metadata is available (any format that provides it).
        if let nKV = moeInfo?.headCountKV, nKV > 0,
           let headDim = resolvedHeadDim(moeInfo: moeInfo) {
            let headDimK = Double(moeInfo?.keyLength ?? headDim)
            let headDimV = Double(moeInfo?.valueLength ?? headDim)
            let perToken = layers * (Double(nKV) * headDimK * kBytes + Double(nKV) * headDimV * vBytes)
            return max(0.0, perToken)
        }

        // Fallback: no head metadata. Approximate the KV dimension as a fraction of the hidden
        // size. The ratio is deliberately coarse and only used when metadata is missing — real
        // GGUFs always carry head_count_kv, so the exact path above covers them in practice.
        let hidden = Double(moeInfo?.hiddenSize ?? approximateHiddenSize(format: format, sizeBytes: sizeBytes))
        let gqaRatio: Double = (format == .gguf) ? 0.34 : 0.5
        let kvDim = hidden * gqaRatio
        return max(0.0, layers * (kvDim * kBytes + kvDim * vBytes))
    }

    /// Per-head key/value dimension. Prefers the explicit `key_length`, otherwise derives it
    /// from `hidden / head_count`. Returns nil when neither is known.
    private static func resolvedHeadDim(moeInfo: MoEInfo?) -> Int? {
        if let k = moeInfo?.keyLength, k > 0 { return k }
        if let v = moeInfo?.valueLength, v > 0 { return v }
        if let hidden = moeInfo?.hiddenSize, let heads = moeInfo?.headCount, heads > 0 {
            return max(1, hidden / heads)
        }
        return nil
    }

    /// Estimate total KV cache memory in bytes for the given context length.
    private static func estimateKVBytes(format: ModelFormat,
                                        sizeBytes: Int64,
                                        contextLength: Int,
                                        layerCount: Int?,
                                        moeInfo: MoEInfo?,
                                        kvCacheEstimate: GGUFKVCacheEstimate) -> Int64 {
        let perToken = kvBytesPerToken(format: format,
                                       sizeBytes: sizeBytes,
                                       layerCount: layerCount,
                                       moeInfo: moeInfo,
                                       kvCacheEstimate: kvCacheEstimate)
        let kv = perToken * Double(max(1, contextLength))
        return Int64(max(0.0, min(kv, Double(Int64.max))))
    }

    /// Resident weight bytes.
    ///
    /// The quant file's bytes are what occupy RAM: `mmap` maps the whole file (so *every*
    /// MoE expert is resident, not just the active ones), and the non-mmap path loads the
    /// whole file too. There is therefore no "active experts only" reduction for memory —
    /// the earlier active-expert accounting under-counted MoE footprint. `moeInfo` and
    /// `layerCount` are retained for signature stability but no longer affect the result.
    private static func estimatedWeightBytes(format: ModelFormat, sizeBytes: Int64, moeInfo: MoEInfo?, layerCount: Int?) -> Int64 {
        let multiplier = baseWeightsMultiplier(for: format)
        let bytes = max(0.0, min(Double(sizeBytes) * multiplier, Double(Int64.max)))
        return Int64(bytes)
    }

    /// Fixed-size state used by recurrent/linear-attention blocks. Qwen3.5/3.6 stores
    /// this state in F32 in the vendored llama.cpp runtime. Unlike KV, it scales with
    /// recurrent layer count but not with context length.
    private static func estimatedRecurrentStateBytes(moeInfo: MoEInfo?) -> Int64 {
        guard let info = moeInfo,
              let recurrentLayers = info.recurrentLayerCount, recurrentLayers > 0,
              let convKernel = info.ssmConvKernel,
              let innerSize = info.ssmInnerSize,
              let stateSize = info.ssmStateSize,
              let groupCount = info.ssmGroupCount else { return 0 }

        let convolutionState = Double(max(0, convKernel - 1))
            * Double(max(0, innerSize + 2 * groupCount * stateSize))
        let linearState = Double(max(0, stateSize * innerSize))
        return clampedInt64(Double(recurrentLayers) * (convolutionState + linearState) * 4.0)
    }

    /// Conservative llama.cpp prompt-processing workspace. The graph is reserved for the
    /// physical micro-batch, and its largest tensors scale with hidden/FFN width and the
    /// vocabulary projection. Flash attention avoids an additional context-by-batch matrix.
    private static func estimatedComputeBufferBytes(
        format: ModelFormat,
        contextLength: Int,
        layerCount: Int?,
        moeInfo: MoEInfo?,
        runtimeConfiguration: RuntimeConfiguration
    ) -> Int64 {
        guard format == .gguf else { return 0 }

        let tokens = max(1, min(
            max(1, contextLength),
            runtimeConfiguration.evaluationBatchSize,
            runtimeConfiguration.physicalBatchSize
        ))
        let hidden = max(256, moeInfo?.hiddenSize ?? approximateHiddenSize(format: format, sizeBytes: 0))
        let feedForward = max(hidden, moeInfo?.feedForwardSize ?? hidden * 3)
        let vocab = max(8_192, moeInfo?.vocabSize ?? 32_768)
        let layers = max(1, moeInfo?.totalLayerCount ?? layerCount ?? 32)
        let heads = max(1, moeInfo?.headCount ?? max(1, hidden / 128))

        // F16 activations for norms, QKV/SSM projections, residuals, and FFN intermediates.
        // Several values remain live across graph splits/backend copies. Hybrid recurrent
        // graphs keep more concurrent state than a conventional dense-attention graph.
        let activationScalarsPerToken = Double(6 * hidden + 2 * feedForward)
        let liveBufferFactor = (moeInfo?.recurrentLayerCount ?? 0) > 0 ? 5.0 : 3.0
        let activations = Double(tokens) * activationScalarsPerToken * 2.0 * liveBufferFactor
        // Noema's server requests one output per sequence, so the F32 vocabulary projection
        // is one row rather than `n_batch` rows. The physical batch still drives activations.
        let vocabularyProjection = Double(vocab) * 4.0
        // Graph metadata, tensor descriptors, backend copies, and per-layer scheduling state.
        let graphBookkeeping = Double(16 * 1_048_576 + layers * 512 * 1_024)

        let nonFlashAttention: Double
        if runtimeConfiguration.flashAttention {
            nonFlashAttention = 0
        } else {
            let attendedContext = min(max(1, contextLength), 8_192)
            nonFlashAttention = Double(tokens) * Double(attendedContext) * Double(heads) * 2.0
        }

        return clampedInt64(activations + vocabularyProjection + graphBookkeeping + nonFlashAttention)
    }

    private static func estimatedProjectorBytes(_ fileBytes: Int64) -> Int64 {
        guard fileBytes > 0 else { return 0 }
        // Projector weights are mapped like the language model, with a small vision graph
        // reservation made during multimodal initialization.
        return clampedInt64(Double(fileBytes) * 1.05 + Double(96 * 1_048_576))
    }

    private static let fixedRuntimeOverhead: Int64 = 200 * 1_048_576
    private static let defaultTransientReserve: Int64 = 192 * 1_048_576
    private static let transientReserveSampleKey = "ggufMemoryTransientReserveSamples.v1"

    /// Q1/Q2 files are exceptionally compact, but Metal still needs wide dequantization,
    /// graph, and command-buffer workspace while evaluating their much larger logical model.
    /// These reserves are calibrated from the observed iPhone failure boundary rather than
    /// multiplying every model allocation by a broad safety factor.
    static func additionalMetalSafetyReserveBytes(
        runtimeConfiguration: RuntimeConfiguration
    ) -> Int64 {
#if os(macOS) || targetEnvironment(macCatalyst)
        return 0
#else
        guard runtimeConfiguration.gpuLayerCount != 0,
              let path = runtimeConfiguration.modelPath?.lowercased() else { return 0 }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let twoBitMarkers = ["q2_0", "iq2_", "tq2_", "-2bit", "-2-bit"]
        if twoBitMarkers.contains(where: filename.contains)
            || path.contains("ternary-bonsai-27b") {
            return 512 * 1_048_576
        }
        let oneBitMarkers = ["q1_0", "iq1_", "tq1_", "-1bit", "-1-bit"]
        if oneBitMarkers.contains(where: filename.contains)
            || path.contains("bonsai-27b") {
            return 1_024 * 1_048_576
        }
        return 0
#endif
    }

    private static func runtimeTransientReserveBytes(
        runtimeConfiguration: RuntimeConfiguration
    ) -> Int64 {
        saturatedSum([
            calibratedTransientReserveBytes(),
            additionalMetalSafetyReserveBytes(runtimeConfiguration: runtimeConfiguration)
        ])
    }

    /// Fixed reserve calibrated from successful launches. We retain a small floor for
    /// devices without samples, then use the observed 90th-percentile allocation above
    /// llama.cpp's no-allocation estimate plus 32 MiB of allocator slack. This avoids
    /// multiplying multi-gigabyte model weights by a blanket safety factor.
    static func calibratedTransientReserveBytes(defaults: UserDefaults = .standard) -> Int64 {
        let storedSamples = (defaults.array(forKey: transientReserveSampleKey) as? [NSNumber]) ?? []
        let samples: [Int64] = storedSamples
            .map(\.int64Value)
            .filter { $0 >= 0 }
            .sorted()
        guard !samples.isEmpty else { return defaultTransientReserve }
        let index = min(samples.count - 1, Int((Double(samples.count - 1) * 0.9).rounded(.up)))
        let measured = saturatedSum([samples[index], 32 * 1_048_576])
        return min(768 * 1_048_576, max(128 * 1_048_576, measured))
    }

    static func recordSuccessfulGGUFLaunch(
        estimatedIncrementalBytes: Int64,
        baselineFootprintBytes: Int64,
        peakFootprintBytes: Int64,
        defaults: UserDefaults = .standard
    ) {
        guard estimatedIncrementalBytes > 0,
              baselineFootprintBytes > 0,
              peakFootprintBytes >= baselineFootprintBytes else { return }
        let observedIncremental = peakFootprintBytes - baselineFootprintBytes
        let transient = max(0, observedIncremental - estimatedIncrementalBytes)
        let storedSamples = (defaults.array(forKey: transientReserveSampleKey) as? [NSNumber]) ?? []
        var samples: [Int64] = storedSamples.map(\.int64Value)
        samples.append(transient)
        if samples.count > 20 {
            samples.removeFirst(samples.count - 20)
        }
        defaults.set(samples, forKey: transientReserveSampleKey)
    }

    static func processFootprintBytes() -> Int64 {
        currentFootprintBytes() ?? 0
    }

    // MARK: - Noema Overfit paged installs

    /// Memory figures for a `.noema-paged` install. The paged runtime
    /// dense-loads the resident GGUF (mmap is forced off), streams experts
    /// through a bank cache sized by `OverfitPlanResolver`, and stages reads
    /// through a small fixed buffer — so the honest weights figure is
    /// resident + bank budget + staging, never the resident file alone and
    /// never the multi-gigabyte package total.
    struct PagedEstimateFigures: Equatable, Sendable {
        let residentBytes: Int64
        let bankBudgetBytes: Int64
        let stagingBytes: Int64
        /// Paged launches clamp context to the plan cap; estimates follow suit.
        let contextCapTokens: Int

        var weightBytes: Int64 {
            ModelRAMAdvisor.saturatedSum([residentBytes, bankBudgetBytes, stagingBytes])
        }
    }

    /// Flat staging allowance for heuristic estimates. The native
    /// no-allocation sizing reports the exact figure in
    /// `MemoryEstimate.paged.stagingBytes` once it has run.
    static let pagedStagingEstimateBytes: Int64 = 64 * 1_048_576

    /// Figure resolution loads the package manifest (multi-MB for large
    /// models), so verdicts memoize per canonical path — same lifecycle
    /// argument as OverfitPagedInstallCache: an install only changes through
    /// a re-download (new URL) or an app restart. `nil` = not a paged install.
    private static let pagedFiguresCache = OSAllocatedUnfairLock<[String: PagedEstimateFigures?]>(initialState: [:])

    static func pagedEstimateFigures(forModelPath modelPath: String?) -> PagedEstimateFigures? {
        guard let modelPath, !modelPath.isEmpty else { return nil }
        let key = URL(fileURLWithPath: modelPath).standardizedFileURL.path
        if let cached = pagedFiguresCache.withLock({ $0[key] }) {
            return cached
        }
        let resolved = resolvePagedEstimateFigures(modelURL: URL(fileURLWithPath: modelPath))
        pagedFiguresCache.withLock { $0[key] = resolved }
        return resolved
    }

    static func invalidatePagedEstimateFigures() {
        pagedFiguresCache.withLock { $0.removeAll() }
    }

    private static func resolvePagedEstimateFigures(modelURL: URL) -> PagedEstimateFigures? {
        guard OverfitPagedInstallCache.isPaged(modelURL) else { return nil }
        // Launch parity: read the bank budget from the same plan launches use
        // instead of duplicating its policy. The plan consults settings only
        // for the mode/purpose gates, which never affect the budget, so
        // estimation resolves with the GGUF defaults (Overfit enabled).
        guard case .paged(let parameters) = OverfitPlanResolver.plan(
            modelURL: modelURL,
            settings: ModelSettings.default(for: .gguf),
            purpose: .chat
        ) else { return nil }
        let residentPath = PagedPackageLocator.residentGGUF(inPackage: parameters.packageDirectory).path
        let residentBytes = (try? FileManager.default.attributesOfItem(atPath: residentPath)[.size]) as? NSNumber
        return PagedEstimateFigures(
            residentBytes: max(0, residentBytes?.int64Value ?? 0),
            bankBudgetBytes: Int64(parameters.bankBudgetMiB) * 1_048_576,
            stagingBytes: pagedStagingEstimateBytes,
            contextCapTokens: max(1, Int(parameters.contextCap))
        )
    }

    static func estimateBreakdown(
        format: ModelFormat,
        sizeBytes: Int64,
        contextLength: Int,
        layerCount: Int?,
        moeInfo: MoEInfo? = nil,
        kvCacheEstimate: GGUFKVCacheEstimate = .f16F16,
        runtimeConfiguration: RuntimeConfiguration = .conservativeDefault
    ) -> EstimateBreakdown {
        let pagedFigures = format == .gguf
            ? pagedEstimateFigures(forModelPath: runtimeConfiguration.modelPath)
            : nil
        // The paged runtime clamps context at launch; size the same shape so
        // slider positions beyond the cap stop inflating KV/compute costs.
        let contextLength = pagedFigures.map { min(contextLength, $0.contextCapTokens) }
            ?? contextLength
        let exactKey = format == .gguf
            ? exactSizingKey(
                contextLength: contextLength,
                kvCacheEstimate: kvCacheEstimate,
                runtimeConfiguration: runtimeConfiguration
            )
            : nil
        if let exact = cachedExactEstimate(for: exactKey) {
            return EstimateBreakdown(
                weights: clampedInt64(Double(exact.modelBytes)),
                // llama.cpp reports context as one exact allocation category. It includes
                // architecture-specific KV/recurrent state, so do not reconstruct either.
                kvCache: clampedInt64(Double(exact.contextBytes)),
                recurrentState: 0,
                computeBuffers: clampedInt64(Double(exact.computeBytes)),
                visionProjector: clampedInt64(Double(exact.projectorBytes)),
                auxiliaryModels: clampedInt64(Double(exact.speculativeBytes)),
                // Paged sizing reports bank bytes inside modelBytes; the
                // staging buffer is the one extra allocation on top.
                fixedOverhead: clampedInt64(Double(exact.paged?.stagingBytes ?? 0)),
                safetyMargin: runtimeTransientReserveBytes(
                    runtimeConfiguration: runtimeConfiguration
                )
            )
        }

        // Paged installs: resident file + streamed-bank budget + staging.
        // The resident-alone file size undersells the runtime (the observed
        // 4.69 GB vs 19.92 GB failure) and the package total oversells it.
        let weights = pagedFigures?.weightBytes
            ?? estimatedWeightBytes(format: format, sizeBytes: sizeBytes, moeInfo: moeInfo, layerCount: layerCount)
        let kv = estimateKVBytes(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate
        )
        let recurrent = estimatedRecurrentStateBytes(moeInfo: moeInfo)
        let compute = estimatedComputeBufferBytes(
            format: format,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            runtimeConfiguration: runtimeConfiguration
        )
        let projector = estimatedProjectorBytes(runtimeConfiguration.projectorFileBytes)
        return EstimateBreakdown(
            weights: weights,
            kvCache: kv,
            recurrentState: recurrent,
            computeBuffers: compute,
            visionProjector: projector,
            auxiliaryModels: 0,
            fixedOverhead: fixedRuntimeOverhead,
            safetyMargin: runtimeTransientReserveBytes(
                runtimeConfiguration: runtimeConfiguration
            )
        )
    }

    /// Whether a model of given format and size likely fits within the device RAM budget
    /// for a specific context length and (optional) layer count.
    static func fitsInRAM(format: ModelFormat,
                          sizeBytes: Int64,
                          contextLength: Int,
                          layerCount: Int?,
                          moeInfo: MoEInfo? = nil,
                          kvCacheEstimate: GGUFKVCacheEstimate = .f16F16,
                          runtimeConfiguration: RuntimeConfiguration = .conservativeDefault) -> Bool {
        if format == .gguf,
           runtimeConfiguration.modelPath != nil,
           cachedExactEstimate(for: exactSizingKey(
               contextLength: contextLength,
               kvCacheEstimate: kvCacheEstimate,
               runtimeConfiguration: runtimeConfiguration
           )) == nil {
            // The heuristic is useful as a provisional warning, but it is not allowed to
            // reject a GGUF before llama.cpp has parsed the metadata and sized the real graph.
            return true
        }
        let (estimate, planningBudget) = budgetAndEstimate(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration
        )
#if os(macOS) || targetEnvironment(macCatalyst)
        let liveAvailable = availableMemoryBytes()
        if let planningBudget, let liveAvailable, liveAvailable > 0 {
            return estimate <= max(planningBudget, liveAvailable)
        }
        if let planningBudget {
            return estimate <= planningBudget
        }
        if let liveAvailable, liveAvailable > 0 {
            return estimate <= liveAvailable
        }
        // If no budget or availability information is present, default to permissive (legacy behavior)
        return true
#else
        if let planningBudget {
            return estimate <= planningBudget
        }
        // If no budget information is available at all, default to permissive (legacy behavior)
        return true
#endif
    }

    /// Backwards-compatible overload (assumes a default context of 4096 and unknown layer count).
    static func fitsInRAM(format: ModelFormat, sizeBytes: Int64) -> Bool {
        return fitsInRAM(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: 4096,
            layerCount: nil,
            moeInfo: nil,
            kvCacheEstimate: .f16F16,
            runtimeConfiguration: .conservativeDefault
        )
    }

    /// Exposes the raw estimate and device budget for UI display.
    static func estimateAndBudget(format: ModelFormat,
                                  sizeBytes: Int64,
                                  contextLength: Int,
                                  layerCount: Int?,
                                  moeInfo: MoEInfo? = nil,
                                  kvCacheEstimate: GGUFKVCacheEstimate = .f16F16,
                                  runtimeConfiguration: RuntimeConfiguration = .conservativeDefault,
                                  knownWorkingContextLength: Int? = nil) -> (estimate: Int64, budget: Int64?) {
        let result = budgetAndEstimate(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration
        )
        let budget = budgetRaisedForKnownWorkingContext(
            result.1,
            format: format,
            sizeBytes: sizeBytes,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration,
            knownWorkingContextLength: knownWorkingContextLength
        )
        return (result.0, budget)
    }

    /// Compute maximum context that fits under budget for this model on this device.
    /// Returns nil if no budget info is available.
    static func maxContextUnderBudget(format: ModelFormat,
                                      sizeBytes: Int64,
                                      layerCount: Int?,
                                      moeInfo: MoEInfo? = nil,
                                      upperBound: Int? = nil,
                                      kvCacheEstimate: GGUFKVCacheEstimate = .f16F16,
                                      runtimeConfiguration: RuntimeConfiguration = .conservativeDefault,
                                      budgetBytesOverride: Int64? = nil,
                                      knownWorkingContextLength: Int? = nil) -> Int? {
        let baseBudget = budgetBytesOverride ?? planningBudgetBytes()
        guard let budget = budgetRaisedForKnownWorkingContext(
            baseBudget,
            format: format,
            sizeBytes: sizeBytes,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration,
            knownWorkingContextLength: knownWorkingContextLength
        ) else { return nil }
        let low = 512
        // Paged launches clamp context at the plan cap; never recommend past it.
        let pagedContextCap = format == .gguf
            ? pagedEstimateFigures(forModelPath: runtimeConfiguration.modelPath)?.contextCapTokens
            : nil
        let high = max(low, min(upperBound ?? 2_097_152, pagedContextCap ?? Int.max))

        func fits(_ context: Int) -> Bool {
            planningEstimate(
                format: format,
                sizeBytes: sizeBytes,
                contextLength: context,
                layerCount: layerCount,
                moeInfo: moeInfo,
                kvCacheEstimate: kvCacheEstimate,
                runtimeConfiguration: runtimeConfiguration
            ) <= budget
        }

        guard fits(low) else { return low }
        if fits(high) { return high }

        var lower = low
        var upper = high
        while lower + 1 < upper {
            let midpoint = lower + (upper - lower) / 2
            if fits(midpoint) {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        return lower
    }

    /// Recommended context ceiling based on total unified-memory pressure rather than the
    /// hard incremental launch allocation. This prevents mmap accounting from implying that
    /// very large contexts are comfortable merely because their buffers can be allocated.
    static func maxContextUnderAdvisoryWorkingSet(
        format: ModelFormat,
        sizeBytes: Int64,
        layerCount: Int?,
        moeInfo: MoEInfo? = nil,
        upperBound: Int? = nil,
        kvCacheEstimate: GGUFKVCacheEstimate = .f16F16,
        runtimeConfiguration: RuntimeConfiguration = .conservativeDefault,
        processLimitBytes: Int64? = nil,
        exactAnchorContextLength: Int? = nil,
        knownWorkingContextLength: Int? = nil
    ) -> Int? {
        let nominalLimit = processLimitBytes ?? currentMemoryBudgetSnapshot().bytes
        guard let limit = advisoryWorkingSetLimitBytes(
            processLimitBytes: nominalLimit,
            runtimeConfiguration: runtimeConfiguration
        ) else {
            return knownWorkingContextLength
        }
        let low = 512
        // Paged launches clamp context at the plan cap; never recommend past it.
        let pagedContextCap = format == .gguf
            ? pagedEstimateFigures(forModelPath: runtimeConfiguration.modelPath)?.contextCapTokens
            : nil
        let high = max(low, min(upperBound ?? 2_097_152, pagedContextCap ?? Int.max))

        func fits(_ context: Int) -> Bool {
            advisoryWorkingSetEstimate(
                format: format,
                sizeBytes: sizeBytes,
                contextLength: context,
                layerCount: layerCount,
                moeInfo: moeInfo,
                kvCacheEstimate: kvCacheEstimate,
                runtimeConfiguration: runtimeConfiguration,
                exactAnchorContextLength: exactAnchorContextLength
            ) <= limit
        }

        let estimatedMaximum: Int
        if !fits(low) {
            estimatedMaximum = low
        } else if fits(high) {
            estimatedMaximum = high
        } else {
            var lower = low
            var upper = high
            while lower + 1 < upper {
                let midpoint = lower + (upper - lower) / 2
                if fits(midpoint) {
                    lower = midpoint
                } else {
                    upper = midpoint
                }
            }
            estimatedMaximum = lower
        }
        // A server reaching its ready state is not proof that sustained inference is safe;
        // high-context failures can occur only after Metal touches the full working set.
        // Do not let a previously loaded context override this pressure ceiling.
        return estimatedMaximum
    }

    /// Full risk-adjusted working set for a context slider position. Once any exact llama.cpp
    /// pass has completed for this runtime, keep its fixed model/graph baseline and change only
    /// the architecture-aware KV/compute portion while the next exact pass is pending. This is
    /// what keeps the live slider estimate continuous instead of falling back to a much smaller
    /// file-size heuristic and jumping when "Checking…" completes.
    static func advisoryWorkingSetEstimate(
        format: ModelFormat,
        sizeBytes: Int64,
        contextLength: Int,
        layerCount: Int?,
        moeInfo: MoEInfo? = nil,
        kvCacheEstimate: GGUFKVCacheEstimate = .f16F16,
        runtimeConfiguration: RuntimeConfiguration = .conservativeDefault,
        exactAnchorContextLength: Int? = nil
    ) -> Int64 {
        // Paged launches clamp context at the plan cap, so working-set pressure
        // stops growing past it. Clamping here also lets slider positions above
        // the cap keep hitting the exact sample cached at the capped context.
        let contextLength: Int = {
            guard format == .gguf,
                  let figures = pagedEstimateFigures(forModelPath: runtimeConfiguration.modelPath) else {
                return contextLength
            }
            return min(contextLength, figures.contextCapTokens)
        }()
        if format == .gguf,
           let currentKey = exactSizingKey(
            contextLength: contextLength,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration
           ),
           cachedExactEstimate(for: currentKey) != nil {
            return estimateBreakdown(
                format: format,
                sizeBytes: sizeBytes,
                contextLength: contextLength,
                layerCount: layerCount,
                moeInfo: moeInfo,
                kvCacheEstimate: kvCacheEstimate,
                runtimeConfiguration: runtimeConfiguration
            ).estimate
        }

        if format == .gguf {
            let currentKey = exactSizingKey(
                contextLength: contextLength,
                kvCacheEstimate: kvCacheEstimate,
                runtimeConfiguration: runtimeConfiguration
            )
            if let curveEstimate = interpolatedExactWorkingSet(
                contextLength: contextLength,
                samples: cachedExactWorkingSetSamples(
                    for: currentKey,
                    runtimeConfiguration: runtimeConfiguration
                )
            ) {
                return curveEstimate
            }
        }

        guard format == .gguf,
              let exactAnchorContextLength,
              exactAnchorContextLength > 0,
              cachedExactEstimate(for: exactSizingKey(
                contextLength: exactAnchorContextLength,
                kvCacheEstimate: kvCacheEstimate,
                runtimeConfiguration: runtimeConfiguration
              )) != nil else {
            return estimateBreakdown(
                format: format,
                sizeBytes: sizeBytes,
                contextLength: contextLength,
                layerCount: layerCount,
                moeInfo: moeInfo,
                kvCacheEstimate: kvCacheEstimate,
                runtimeConfiguration: runtimeConfiguration
            ).estimate
        }

        let anchorWorkingSet = estimateBreakdown(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: exactAnchorContextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration
        ).estimate
        let anchorContextDependent = estimatedContextDependentBytes(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: exactAnchorContextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration
        )
        let candidateContextDependent = estimatedContextDependentBytes(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration
        )
        return applyingContextDependentChange(
            to: anchorWorkingSet,
            from: anchorContextDependent,
            to: candidateContextDependent
        )
    }

    private static func estimatedContextDependentBytes(
        format: ModelFormat,
        sizeBytes: Int64,
        contextLength: Int,
        layerCount: Int?,
        moeInfo: MoEInfo?,
        kvCacheEstimate: GGUFKVCacheEstimate,
        runtimeConfiguration: RuntimeConfiguration
    ) -> Int64 {
        saturatedSum([
            estimateKVBytes(
                format: format,
                sizeBytes: sizeBytes,
                contextLength: contextLength,
                layerCount: layerCount,
                moeInfo: moeInfo,
                kvCacheEstimate: kvCacheEstimate
            ),
            estimatedComputeBufferBytes(
                format: format,
                contextLength: contextLength,
                layerCount: layerCount,
                moeInfo: moeInfo,
                runtimeConfiguration: runtimeConfiguration
            )
        ])
    }

    private static func applyingContextDependentChange(
        to workingSet: Int64,
        from anchorContextDependent: Int64,
        to candidateContextDependent: Int64
    ) -> Int64 {
        if candidateContextDependent >= anchorContextDependent {
            return saturatedSum([
                workingSet,
                candidateContextDependent - anchorContextDependent
            ])
        }
        return max(0, workingSet - (anchorContextDependent - candidateContextDependent))
    }

    /// A successfully loaded configuration is stronger evidence than a volatile process-memory
    /// snapshot. Raise the planning floor just enough to keep that proven context classified as
    /// viable; larger contexts still have to fit under the remaining estimator headroom.
    private static func budgetRaisedForKnownWorkingContext(
        _ budget: Int64?,
        format: ModelFormat,
        sizeBytes: Int64,
        layerCount: Int?,
        moeInfo: MoEInfo?,
        kvCacheEstimate: GGUFKVCacheEstimate,
        runtimeConfiguration: RuntimeConfiguration,
        knownWorkingContextLength: Int?
    ) -> Int64? {
        guard let knownWorkingContextLength, knownWorkingContextLength > 0 else { return budget }
        let provenEstimate = planningEstimate(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: knownWorkingContextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration
        )
        return max(budget ?? 0, provenEstimate)
    }

    /// Returns (estimateWorkingSetBytes, budgetBytes)
    private static func budgetAndEstimate(format: ModelFormat,
                                          sizeBytes: Int64,
                                          contextLength: Int,
                                          layerCount: Int?,
                                          moeInfo: MoEInfo?,
                                          kvCacheEstimate: GGUFKVCacheEstimate,
                                          runtimeConfiguration: RuntimeConfiguration) -> (Int64, Int64?) {
        let budgetBytes = planningBudgetBytes()
        let estimate = planningEstimate(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration
        )
        return (estimate, budgetBytes)
    }

    /// Bytes that should be compared with the selected platform's planning budget.
    /// On iOS the budget is incremental process headroom, so a local GGUF's read-only,
    /// mmap-backed model buffers are not part of the new allocation. macOS uses a physical
    /// memory budget and therefore retains the complete logical working-set estimate.
    private static func planningEstimate(
        format: ModelFormat,
        sizeBytes: Int64,
        contextLength: Int,
        layerCount: Int?,
        moeInfo: MoEInfo?,
        kvCacheEstimate: GGUFKVCacheEstimate,
        runtimeConfiguration: RuntimeConfiguration
    ) -> Int64 {
        let breakdown = estimateBreakdown(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvCacheEstimate,
            runtimeConfiguration: runtimeConfiguration
        )
#if os(macOS) || targetEnvironment(macCatalyst)
        return breakdown.estimate
#else
        guard format == .gguf, runtimeConfiguration.modelPath != nil else {
            return breakdown.estimate
        }
        // Paged installs dense-load the resident weights and allocate the bank
        // cache outright (mmap is forced off), so nothing is mmap-exempt.
        if pagedEstimateFigures(forModelPath: runtimeConfiguration.modelPath) != nil {
            return breakdown.estimate
        }
        return saturatedSum([
            breakdown.kvCache,
            breakdown.recurrentState,
            breakdown.computeBuffers,
            breakdown.visionProjector,
            breakdown.auxiliaryModels,
            breakdown.fixedOverhead,
            breakdown.safetyMargin
        ])
#endif
    }

    @ViewBuilder
    static func badge(format: ModelFormat, sizeBytes: Int64, contextLength: Int = 4096, layerCount: Int? = nil, moeInfo: MoEInfo? = nil) -> some View {
        let (estimate, budget) = budgetAndEstimate(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: .f16F16,
            runtimeConfiguration: .conservativeDefault
        )
        let fits: Bool = {
            guard let budget else { return true }
            return estimate <= budget
        }()
        RAMBadgeView(fits: fits, estimate: estimate, budget: budget, context: contextLength)
    }

    private static func clampedInt64(_ value: Double) -> Int64 {
        Int64(max(0, min(value, Double(Int64.max))))
    }

    private static func saturatedSum(_ values: [Int64]) -> Int64 {
        values.reduce(into: Int64(0)) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            total = overflow ? Int64.max : sum
        }
    }

    static func saturatedAdding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        saturatedSum([lhs, rhs])
    }
}

private struct RAMBadgeView: View {
    let fits: Bool
    let estimate: Int64
    let budget: Int64?
    let context: Int
    @State private var showInfo = false
    @Environment(\.locale) private var locale

    private var color: Color { fits ? .green : .red }
    private var symbol: String { fits ? "checkmark" : "xmark" }

    private func localizedMemoryString(_ bytes: Int64) -> String {
        let useGB = bytes >= 1_073_741_824
        let value = useGB ? Double(bytes) / 1_073_741_824.0 : Double(bytes) / 1_048_576.0
        let unit: UnitInformationStorage = useGB ? .gigabytes : .megabytes

        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.locale = locale
        formatter.numberFormatter.maximumFractionDigits = 1
        formatter.numberFormatter.minimumFractionDigits = 0
        return formatter.string(from: Measurement(value: value, unit: unit))
    }

    private var infoText: String {
        let estStr = localizedMemoryString(estimate)
        let budStr = budget.map { localizedMemoryString($0) } ?? "--"
        let ctxFormatter = NumberFormatter()
        ctxFormatter.locale = locale
        ctxFormatter.numberStyle = .decimal
        let ctx = ctxFormatter.string(from: NSNumber(value: context)) ?? "\(context)"
        return String.localizedStringWithFormat(
            String(localized: "Estimate: %@\nBudget: %@\nContext length: %@ tokens\n\nThis is an estimate based on your device’s memory budget, context length (KV cache), and typical runtime overheads. Actual usage may vary.", locale: locale),
            estStr, budStr, ctx
        )
    }

    var body: some View {
        Button(action: { showInfo = true }) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundColor(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(color.opacity(0.15))
                .clipShape(Capsule())
                .accessibilityLabel(fits ? LocalizedStringKey("Model likely fits in RAM") : LocalizedStringKey("Model may not fit in RAM"))
        }
        .buttonStyle(.plain)
        // The bare checkmark glyph makes VoiceOver infer an `.isSelected` trait,
        // so every model that fits RAM (downloaded or not) wrongly reads as
        // "Selected." This badge is informational, never a selection control.
        .accessibilityRemoveTraits(.isSelected)
        .popover(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol).foregroundColor(color)
                    Text(fits ? LocalizedStringKey("Fits in RAM (estimated)") : LocalizedStringKey("May not fit (estimated)"))
                        .font(.headline)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                }

                ScrollView(.vertical, showsIndicators: true) {
                    Text(infoText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)

#if !os(macOS)
                HStack {
                    Spacer()
                    Button(LocalizedStringKey("OK")) { showInfo = false }
                        .buttonStyle(.borderedProminent)
                }
#endif
            }
            .padding(12)
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 420, alignment: .leading)
#if !os(macOS)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
#endif
        }
    }
}
