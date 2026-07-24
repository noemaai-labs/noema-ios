import SwiftUI
import Foundation
import RelayKit
import Combine
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import NoemaPackages
#if canImport(MLX)
import MLX
#endif

#if canImport(UIKit) || os(macOS)
/// The sole translation from persisted GGUF settings to the immutable native
/// server contract. Request-scoped sampling deliberately stays out of this value.
@MainActor
enum GGUFServerConfigurationResolver {
    static func resolve(
        modelURL: URL,
        settings: ModelSettings,
        mmprojPath: String?,
        contextShiftEnabled: Bool,
        downloadedModels: [LocalModel] = [],
        parallelSlots: Int32 = 1
    ) -> LlamaServerBridge.StartConfiguration {
        let supportsOffload = DeviceGPUInfo.supportsGPUOffload
        let gpuLayers: Int32 = {
            guard supportsOffload else { return 0 }
            return Int32(clamping: settings.gpuLayers < 0 ? 1_000_000 : max(0, settings.gpuLayers))
        }()
        let requestedThreads = settings.cpuThreads > 0
            ? settings.cpuThreads
            : ModelSettings.recommendedInferenceThreadCount
        let threads = Int32(clamping: min(max(1, requestedThreads), ModelSettings.maxInferenceThreadCount))

        var draftPath: String?
        var speculativeType: String?
        var draftNMax: Int32?
        var draftNMin: Int32?
        var draftPMin: Double?
        var draftDynamic = false
        switch settings.speculativeDecoding.selection {
        case .off:
            break
        case .helperDraftModel:
            if let helperID = settings.speculativeDecoding.helperModelID {
                // The settings picker persists LocalModel.id (the file path);
                // the wizard persists modelID. Accept both.
                let helperURL = downloadedModels.first(where: { $0.modelID == helperID || $0.id == helperID })?.url
                    ?? InstalledModelsStore.firstGGUF(
                        in: InstalledModelsStore.baseDir(for: .gguf, modelID: helperID)
                    )
                if let helperURL {
                    draftPath = helperURL.path
                    speculativeType = "draft-simple"
                    draftNMax = Int32(clamping: max(1, settings.speculativeDecoding.value))
                    draftDynamic = settings.speculativeDecoding.mode == .max
                }
            }
        case .mtp:
            let sidecar = MtpLocator.mtpPath(alongside: modelURL)
            if sidecar != nil || GGUFMetadata.hasMTP(at: modelURL) {
                draftPath = sidecar
                speculativeType = "draft-mtp"
                draftNMax = Int32(settings.speculativeDecoding.effectiveMTPDraftNMax)
                draftNMin = Int32(settings.speculativeDecoding.effectiveMTPDraftNMin)
                draftPMin = settings.speculativeDecoding.effectiveMTPDraftPMin
                draftDynamic = settings.speculativeDecoding.mtpAutoTune
            }
        }

        let tensorOverride = settings.tensorOverride == .ffnCPU
            ? ".*\\.ffn_(up|down|gate).*\\.weight=CPU"
            : nil
        let rope = settings.ropeScaling
        return TemplateDrivenModelSupport.loopbackStartConfiguration(
            modelURL: modelURL,
            ggufPath: modelURL.path,
            mmprojPath: mmprojPath,
            mtpPath: draftPath,
            speculativeType: speculativeType,
            specDraftNMax: draftNMax,
            specDraftNMin: draftNMin,
            specDraftPMin: draftPMin,
            specDynamic: draftDynamic,
            contextSize: Int32(clamping: max(1, Int(settings.contextLength))),
            contextShift: contextShiftEnabled,
            gpuLayers: gpuLayers,
            threads: threads,
            threadsBatch: threads,
            batchSize: Int32(clamping: settings.resolvedEvaluationBatchSize),
            ubatchSize: Int32(clamping: settings.resolvedPhysicalBatchSize),
            useMmap: settings.useMmap,
            useMlock: {
                #if os(macOS)
                settings.keepInMemory
                #else
                false
                #endif
            }(),
            warmup: !settings.disableWarmup,
            kvOffload: supportsOffload && gpuLayers > 0 && settings.kvCacheOffload,
            unifiedKVCache: settings.unifiedKVCache,
            flashAttention: settings.flashAttention,
            cacheTypeK: settings.kCacheQuant.rawValue,
            cacheTypeV: settings.flashAttention ? settings.vCacheQuant.rawValue : "f16",
            parallelSlots: parallelSlots,
            tensorOverride: tensorOverride,
            cpuMoE: settings.tensorOverride == .expertsCPU,
            moeExpertCount: settings.moeActiveExperts.map { Int32(clamping: $0) },
            yarnScale: rope?.factor,
            yarnOriginalContext: rope.map { Int32(clamping: $0.originalContext) },
            yarnBetaFast: rope?.betaFast,
            yarnBetaSlow: rope?.betaSlow,
            promptCacheEnabled: settings.promptCacheEnabled
        )
    }

    /// Overfit-aware resolution: selects resident or paged execution for this
    /// launch and produces the matching immutable configuration. The resident
    /// path delegates to `resolve(...)` unchanged; a `.refused` plan returns a
    /// placeholder configuration the caller must not start.
    static func resolveWithPlan(
        modelURL: URL,
        settings: ModelSettings,
        mmprojPath: String?,
        contextShiftEnabled: Bool,
        downloadedModels: [LocalModel] = [],
        parallelSlots: Int32 = 1,
        purpose: OverfitLaunchPurpose = .chat
    ) -> (configuration: LlamaServerBridge.StartConfiguration, plan: OverfitPlan) {
        let plan = OverfitPlanResolver.plan(modelURL: modelURL, settings: settings, purpose: purpose)
        switch plan {
        case .resident, .refused:
            let configuration = resolve(
                modelURL: modelURL,
                settings: settings,
                mmprojPath: mmprojPath,
                contextShiftEnabled: contextShiftEnabled,
                downloadedModels: downloadedModels,
                parallelSlots: parallelSlots
            )
            return (configuration, plan)
        case .paged(let parameters):
            return (pagedConfiguration(modelURL: modelURL,
                                       settings: settings,
                                       contextShiftEnabled: contextShiftEnabled,
                                       downloadedModels: downloadedModels,
                                       parameters: parameters), plan)
        }
    }

    /// Paged launches force their own runtime shape regardless of the user's
    /// conventional GGUF preferences: explicit dense loads only (no mmap or
    /// mlock), no cache-ram prompt cache, no projector, a single slot, and a
    /// conservative context ceiling. Context checkpoints stay ON for streamed
    /// mode (`OverfitPlanResolver.pagedCtxCheckpoints`): the hybrid target
    /// architecture cannot roll a sequence back partially, so checkpoints are
    /// the only mechanism that lets turn N+1 reuse turn N's prefix instead of
    /// re-prefilling the whole transcript. Streamed mode pins the physical
    /// batch to one token only when the wave-split kill switch is active.
    /// Waves are the default on every supported Apple platform and need
    /// multi-token prefill graphs (the native gate requires n_tokens > 1),
    /// so the enabled path passes a larger
    /// physical batch and lets the bridge clamp — floor((slots − spare) / K)
    /// with waves off, no clamp with waves on (per-wave residency is bounded
    /// by the expert-group width). The initial graph is 1024 on Mac and 512
    /// on iPhone/iPad; the committed launch tries descending exact-sized
    /// shapes. Per-wave residency is independent of n_tokens, so prefill
    /// expert I/O is one full expert sweep per
    /// micro-batch — a 1 k-token prompt at ubatch 256 pays ~4 sweeps where
    /// ubatch 1024 pays one. An ineligible layer under waves fails closed: the route
    /// callback poisons the generation instead of over-pinning the bank. The
    /// one speculative shape that survives is a helper draft model under
    /// streamed mode — it loads resident beside the paged target, so the
    /// helper must not itself be a paged install — with the draft budget
    /// capped at 8 (the server clamps further to the bank).
    private static func pagedConfiguration(
        modelURL: URL,
        settings: ModelSettings,
        contextShiftEnabled: Bool,
        downloadedModels: [LocalModel],
        parameters: PagedLaunchParameters
    ) -> LlamaServerBridge.StartConfiguration {
        let supportsOffload = DeviceGPUInfo.supportsGPUOffload
        let gpuLayers: Int32 = {
            guard supportsOffload else { return 0 }
            return Int32(clamping: settings.gpuLayers < 0 ? 1_000_000 : max(0, settings.gpuLayers))
        }()
        let requestedThreads = settings.cpuThreads > 0
            ? settings.cpuThreads
            : ModelSettings.recommendedInferenceThreadCount
        let threads = Int32(clamping: min(max(1, requestedThreads), ModelSettings.maxInferenceThreadCount))
        let contextSize = min(Int32(clamping: max(1, Int(settings.contextLength))), parameters.contextCap)

        // Helper-draft speculation survives paging only under streamed mode
        // (the bridge rejects every speculative shape elsewhere) and only when
        // the helper resolves to a conventional GGUF: a paged install cannot
        // load resident as the draft.
        var draftPath: String?
        var speculativeType: String?
        var draftNMax: Int32?
        var draftDynamic = false
        if parameters.mode == .streamed,
           settings.speculativeDecoding.selection == .helperDraftModel,
           let helperID = settings.speculativeDecoding.helperModelID {
            // The settings picker persists LocalModel.id (the file path); the
            // wizard persists modelID. Accept both.
            let helperURL = downloadedModels.first(where: { $0.modelID == helperID || $0.id == helperID })?.url
                ?? InstalledModelsStore.firstGGUF(
                    in: InstalledModelsStore.baseDir(for: .gguf, modelID: helperID)
                )
            if let helperURL, !PagedPackageLocator.isPagedInstall(helperURL) {
                draftPath = helperURL.path
                speculativeType = "draft-simple"
                draftNMax = Int32(clamping: min(max(1, settings.speculativeDecoding.value), 8))
                draftDynamic = settings.speculativeDecoding.mode == .max
            }
        }
        let evaluationBatch = Int32(clamping: settings.resolvedEvaluationBatchSize)
        let physicalBatch = Int32(clamping: settings.resolvedPhysicalBatchSize)
        let wavesEnabled = parameters.mode == .streamed && Self.wavesEnabledByPolicy
        var batchSize = evaluationBatch
        var ubatchSize: Int32 = parameters.mode == .streamed && !wavesEnabled ? 1 : physicalBatch
        if wavesEnabled {
            // Waves guarantee per-wave expert residency independent of the
            // token count, so each prefill micro-batch costs one expert sweep.
            // Start with the platform preview shape; the committed launch
            // performs exact-size fallback before allocating the server.
            let lifted = OverfitPlanResolver.initialPagedWaveUbatch(
                requested: physicalBatch,
                contextCap: parameters.contextCap
            )
            batchSize = min(max(batchSize, lifted), parameters.contextCap)
            ubatchSize = min(lifted, batchSize)
        }
        return TemplateDrivenModelSupport.loopbackStartConfiguration(
            modelURL: modelURL,
            ggufPath: modelURL.path,
            mmprojPath: nil,
            mtpPath: draftPath,
            speculativeType: speculativeType,
            specDraftNMax: draftNMax,
            specDynamic: draftDynamic,
            contextSize: contextSize,
            contextShift: contextShiftEnabled,
            gpuLayers: gpuLayers,
            threads: threads,
            threadsBatch: threads,
            batchSize: batchSize,
            ubatchSize: ubatchSize,
            useMmap: false,
            useMlock: false,
            warmup: false,
            kvOffload: supportsOffload && gpuLayers > 0 && settings.kvCacheOffload,
            unifiedKVCache: settings.unifiedKVCache,
            flashAttention: settings.flashAttention,
            cacheTypeK: settings.kCacheQuant.rawValue,
            cacheTypeV: settings.flashAttention ? settings.vCacheQuant.rawValue : "f16",
            parallelSlots: 1,
            // No cache-ram prompt cache (single slot, nothing to swap), but
            // context checkpoints must stay on for streamed paged launches:
            // the hybrid architecture cannot partially roll back a sequence,
            // so a restored checkpoint is the only path to prefix reuse.
            // Checkpoints are gated natively on --ctx-checkpoints alone,
            // independent of --cache-ram.
            promptCacheEnabled: false,
            ctxCheckpointsOverride: parameters.mode == .streamed
                ? OverfitPlanResolver.pagedCtxCheckpoints
                : nil,
            pagedMode: parameters.mode,
            pagedManifestPath: parameters.manifestPath,
            pagedTrace: parameters.trace,
            pagedBankBudgetMiB: parameters.bankBudgetMiB,
            pagedPrefetch: parameters.prefetch,
            pagedIOThreads: OverfitPlanResolver.pagedIOThreads,
            pagedIODepth: OverfitPlanResolver.pagedIODepth,
            pagedWaves: wavesEnabled,
            pagedExpertMajor: wavesEnabled
        )
    }

    /// Production default for wave-split/expert-major prefill. The native v4
    /// contract receives this value explicitly. getenv remains a live
    /// diagnostic/test override (`0` kills the path, `1` forces it).
    static var wavesEnabledByPolicy: Bool {
        if let raw = getenv("NOEMA_PAGED_WAVES") {
            return String(cString: raw) == "1"
        }
        return true
    }
}

// Helper utilities for MLX repo inference and tokenizer fetching
@MainActor
private func inferRepoID(from directory: URL) -> String? {
    // Prefer explicit repo.txt if present
    let explicit = directory.appendingPathComponent("repo.txt")
    if let data = try? Data(contentsOf: explicit), let s = String(data: data, encoding: .utf8) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    // Typical layout: .../LocalLLMModels/<owner>/<repo>
    let owner = directory.deletingLastPathComponent().lastPathComponent
    let repo  = directory.lastPathComponent
    if !owner.isEmpty, owner != "LocalLLMModels" { return owner + "/" + repo }
    // Legacy single-component folder names
    if repo.contains("/") { return repo }
    if repo.contains("_") { return repo.replacingOccurrences(of: "_", with: "/") }
    return repo
}

@MainActor
private func fetchTokenizer(into dir: URL, repoID: String) async {
    let defaults = UserDefaults.standard
    let token = defaults.string(forKey: "huggingFaceToken")
    func request(_ url: URL, accept: String) async throws -> Data? {
        if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
        var req = URLRequest(url: url)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let t = token, !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        NetworkKillSwitch.track(session: URLSession.shared)
        let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
        if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { return data }
        return nil
    }
    func isLFSPointerData(_ data: Data) -> Bool {
        if data.count > 4096 { return false }
        guard let s = String(data: data, encoding: .utf8) else { return false }
        let lower = s.lowercased()
        return lower.contains("git-lfs") || lower.contains("oid sha256:")
    }
    // Try to derive tokenizer path from local config.json if it references a subpath
    if let cfgData = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
       let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any] {
        let keys = ["tokenizer_file", "tokenizer_json", "tokenizer", "tokenizer_path"]
        for k in keys {
            if let rel = cfg[k] as? String, rel.lowercased().contains("tokenizer") {
                let candidates = [
                    URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(rel)?download=1"),
                    URL(string: "https://huggingface.co/\(repoID)/raw/main/\(rel)")
                ].compactMap { $0 }
                for u in candidates {
                    if let data = try? await request(u, accept: "application/json"), data.count > 0, !isLFSPointerData(data) {
                        try? data.write(to: dir.appendingPathComponent("tokenizer.json"))
                        return
                    }
                }
            }
        }
    }
    // Try tokenizer.json via resolve first (works with LFS), then raw as fallback
    if let data = try? await request(URL(string: "https://huggingface.co/\(repoID)/resolve/main/tokenizer.json?download=1")!, accept: "application/json"), data.count > 0, !isLFSPointerData(data) {
        try? data.write(to: dir.appendingPathComponent("tokenizer.json"))
        return
    }
    if let data = try? await request(URL(string: "https://huggingface.co/\(repoID)/raw/main/tokenizer.json")!, accept: "application/json"), data.count > 0, !isLFSPointerData(data) {
        try? data.write(to: dir.appendingPathComponent("tokenizer.json"))
        return
    }
    // Try known SentencePiece names (prefer resolve first)
    for name in ["tokenizer.model", "spiece.model", "sentencepiece.bpe.model"] {
        if let data = try? await request(URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(name)?download=1")!, accept: "application/octet-stream"), data.count > 0 {
            try? data.write(to: dir.appendingPathComponent(name))
            return
        }
        if let data = try? await request(URL(string: "https://huggingface.co/\(repoID)/raw/main/\(name)")!, accept: "application/octet-stream"), data.count > 0 {
            try? data.write(to: dir.appendingPathComponent(name))
            return
        }
    }
}

extension ChatVM {
    @MainActor
    func resolveLoadURL(for model: LocalModel) -> URL {
        resolveLoadURL(for: model.url, explicitFormat: model.format, modelHint: model).url
    }

    struct PreparedModelLoad {
        let url: URL
        let format: ModelFormat
        let settings: ModelSettings?
        let promptTemplateSource: String?
        let appleModelKind: AppleFoundationModelKind?
    }

    @MainActor
    private func displayLoadName(for originalURL: URL, format: ModelFormat?) -> String {
        let resolved = resolveLoadURL(for: originalURL, explicitFormat: format)
        let canonicalURL: URL = {
            switch resolved.format {
            case .gguf:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .gguf)
            case .mlx:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .mlx)
            case .et:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .et)
            case .ane:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .ane)
            case .afm:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .afm)
            case .coreai:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .coreai)
            }
        }()

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: canonicalURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return canonicalURL.lastPathComponent
        }

        return canonicalURL.deletingPathExtension().lastPathComponent
    }

    @MainActor
    func resolveLoadURL(
        for originalURL: URL,
        explicitFormat: ModelFormat?,
        modelHint: LocalModel? = nil
    ) -> (url: URL, format: ModelFormat) {
        let detectedFmt = explicitFormat ?? ModelFormat.detect(from: originalURL)
        var loadURL = originalURL

        if detectedFmt == .gguf {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue, let alt = InstalledModelsStore.firstGGUF(in: loadURL) {
                loadURL = alt
            }

            var effectiveIsDir: ObjCBool = false
            let effectiveExists = FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &effectiveIsDir)
            let isValid = effectiveExists && (effectiveIsDir.boolValue || InstalledModelsStore.isValidGGUF(at: loadURL))
            if !isValid {
                let managerModel = modelManager?.downloadedModels.first(where: { candidate in
                    candidate.url == originalURL
                        || candidate.url == loadURL
                        || candidate.url.deletingLastPathComponent() == originalURL
                        || candidate.url.deletingLastPathComponent() == loadURL
                })
                let modelID = modelHint?.modelID
                    ?? managerModel?.modelID
                    ?? inferRepoID(from: loadURL)
                    ?? loadURL.deletingLastPathComponent().lastPathComponent
                let base = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
                if let alt = InstalledModelsStore.firstGGUF(in: base) {
                    loadURL = alt
                }
            }
        }

        return (loadURL, detectedFmt)
    }


    @MainActor
    func prepareLoad(
        for originalURL: URL,
        settings: ModelSettings?,
        format: ModelFormat?,
        modelHint: LocalModel? = nil
    ) async throws -> PreparedModelLoad {
        let resolution = resolveLoadURL(for: originalURL, explicitFormat: format, modelHint: modelHint)
        var loadURL = resolution.url
        let detectedFmt = resolution.format

        if detectedFmt != .afm {
            guard FileManager.default.fileExists(atPath: loadURL.path) else {
                throw NSError(domain: "Noema", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model not downloaded"])
            }
        }

        var finalSettings = settings
        var promptTemplateSource = PromptTemplateSource.defaultTemplate.rawValue
        var appleModelKind: AppleFoundationModelKind?

        if detectedFmt == .mlx {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir)
            if !isDir.boolValue {
                let dir = loadURL.deletingLastPathComponent()
                var dirIsDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: dir.path, isDirectory: &dirIsDir), dirIsDir.boolValue {
                    loadURL = dir
                    if verboseLogging { print("[ChatVM] Adjusted MLX URL to directory: \(dir.path)") }
                } else {
                    throw NSError(domain: "Noema", code: 400, userInfo: [NSLocalizedDescriptionKey: "MLX model directory missing"])
                }
            }

            if (finalSettings?.tokenizerPath ?? "").isEmpty {
                let possibleTokenizers = ["tokenizer.json", "tokenizer.model", "spiece.model", "sentencepiece.bpe.model"]
                let existing = possibleTokenizers
                    .map { loadURL.appendingPathComponent($0) }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
                if let existing {
                    var s = finalSettings ?? ModelSettings.default(for: .mlx)
                    s.tokenizerPath = existing.path
                    finalSettings = s
                }
            }

            do {
                let cfg = loadURL.appendingPathComponent("config.json")
                let data = try Data(contentsOf: cfg)
                _ = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw NSError(domain: "Noema", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid or missing config.json in MLX model directory"])
            }

            let possibleTokenizers = ["tokenizer.json", "tokenizer.model", "spiece.model", "sentencepiece.bpe.model"]
            func isGitLFSPointer(_ url: URL) -> Bool {
                guard let d = try? Data(contentsOf: url), d.count < 4096,
                      let s = String(data: d, encoding: .utf8) else { return false }
                let lower = s.lowercased()
                return lower.contains("git-lfs") || lower.contains("oid sha256:")
            }
            var hasTokenizerAsset = possibleTokenizers.contains { name in
                let u = loadURL.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: u.path) {
                    if name == "tokenizer.json" && isGitLFSPointer(u) { return false }
                    return true
                }
                return false
            }
            if !hasTokenizerAsset {
                var repoHint: String? = nil
                if let mm = modelManager {
                    if let m = mm.downloadedModels.first(where: { $0.url == loadURL || $0.url.deletingLastPathComponent() == loadURL }) {
                        repoHint = m.modelID
                    }
                }
                let repoID = repoHint ?? inferRepoID(from: loadURL)
                if let repoID {
                    if verboseLogging { print("[ChatVM] Attempting to fetch tokenizer.json for repo: \(repoID)") }
                    await fetchTokenizer(into: loadURL, repoID: repoID)
                    hasTokenizerAsset = possibleTokenizers.contains { name in
                        let u = loadURL.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: u.path) {
                            if name == "tokenizer.json" && isGitLFSPointer(u) { return false }
                            return true
                        }
                        return false
                    }
                }
            }
            if !hasTokenizerAsset {
                throw NSError(domain: "Noema", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing tokenizer assets in MLX model directory"])
            }
            if (finalSettings?.tokenizerPath ?? "").isEmpty {
                if let first = possibleTokenizers
                    .map({ loadURL.appendingPathComponent($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    var s = finalSettings ?? ModelSettings.default(for: .mlx)
                    s.tokenizerPath = first.path
                    finalSettings = s
                }
            }
            let contents = (try? FileManager.default.contentsOfDirectory(at: loadURL, includingPropertiesForKeys: nil)) ?? []
            let hasWeights = contents.contains { url in
                let ext = url.pathExtension.lowercased()
                return ext == "safetensors" || ext == "npz"
            }
            if !hasWeights {
                throw NSError(domain: "Noema", code: 400, userInfo: [NSLocalizedDescriptionKey: "No weight files (.safetensors or .npz) found in MLX model directory"])
            }
        }

        if detectedFmt == .ane {
            var isDir: ObjCBool = false
            let managerModel = modelManager?.downloadedModels.first(where: { candidate in
                candidate.url == originalURL
                    || candidate.url == loadURL
                    || candidate.url.deletingLastPathComponent() == originalURL
                    || candidate.url.deletingLastPathComponent() == loadURL
            })
            let modelID = modelHint?.modelID
                ?? managerModel?.modelID
                ?? inferRepoID(from: loadURL)
                ?? loadURL.deletingLastPathComponent().lastPathComponent

            if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                if !isDir.boolValue {
                    loadURL = loadURL.deletingLastPathComponent()
                }
            } else {
                loadURL = InstalledModelsStore.baseDir(for: .ane, modelID: modelID)
            }

            loadURL = InstalledModelsStore.canonicalURL(for: loadURL, format: .ane)
            guard InstalledModelsStore.firstANEArtifact(in: loadURL) != nil else {
                throw NSError(
                    domain: "Noema",
                    code: 400,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No Core ML artifact found (.mlmodelc, .mlpackage, or .mlmodel)."
                    ]
                )
            }

            let resolvedSettings = ModelSettings.resolvedANEModelSettings(modelID: modelID, modelURL: loadURL)
            promptTemplateSource = resolvedSettings.promptTemplateSource.rawValue
            if finalSettings == nil {
                finalSettings = resolvedSettings.settings
            }
        }

        if detectedFmt == .afm {
            let managerModel = modelManager?.downloadedModels.first(where: { candidate in
                candidate.format == .afm && (
                    candidate.url == originalURL
                        || candidate.url == loadURL
                        || originalURL.path.hasPrefix(candidate.url.path)
                        || loadURL.path.hasPrefix(candidate.url.path)
                )
            })
            let modelID = modelHint?.modelID
                ?? managerModel?.modelID
                ?? AppleFoundationModelKind.resolve(modelID: nil, url: originalURL).modelID
            let kind = AppleFoundationModelKind.resolve(modelID: modelID, url: originalURL)
            appleModelKind = kind

            switch kind {
            case .onDevice:
                let state = AppleFoundationModelAvailability.current
                guard state.isSupportedDevice else {
                    throw NSError(
                        domain: "Noema",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: AppleFoundationModelUnavailableReason.unsupportedDevice.message]
                    )
                }
                if let reason = state.unavailableReason, !state.isAvailableNow {
                    throw NSError(
                        domain: "Noema",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: reason.message]
                    )
                }
            case .privateCloudCompute:
                let status = ApplePrivateCloudComputeAvailability.status
                guard status.isAvailableForRequests else {
                    throw NSError(
                        domain: "Noema",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: status.message]
                    )
                }
            }

            loadURL = InstalledModelsStore.baseDir(for: .afm, modelID: modelID)
            try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
            loadURL = InstalledModelsStore.canonicalURL(for: loadURL, format: .afm)
        }

        if let fmt = format {
            switch fmt {
            case .mlx:
                finalSettings?.gpuLayers = 0
            case .gguf:
                if var s = finalSettings {
                    let layers = ModelScanner.layerCount(for: loadURL, format: .gguf)
                    let ctxMax = GGUFMetadata.contextLength(at: loadURL) ?? Int.max
                    if s.gpuLayers >= 0, layers > 0 {
                        // Only clamp when layer count is known; otherwise trust the user's value
                        s.gpuLayers = min(max(0, s.gpuLayers), layers)
                    }
                    s.contextLength = min(s.contextLength, Double(ctxMax))
                    // llama-server always uses tokenizer metadata embedded in the
                    // GGUF. Keep sidecar tokenizer selection exclusive to backends
                    // with a supported tokenizer-file contract.
                    s.tokenizerPath = nil
                    finalSettings = s
                }
            case .et, .ane, .afm, .coreai:
                break
            }
        }

        return PreparedModelLoad(
            url: loadURL,
            format: detectedFmt,
            settings: finalSettings,
            promptTemplateSource: detectedFmt == .ane ? promptTemplateSource : nil,
            appleModelKind: appleModelKind
        )
    }

    private func resolveETLoadArtifacts(url: URL, settings: ModelSettings?) throws -> ETModelResolver.LoadArtifacts {
        try ETModelResolver.resolveLoadArtifacts(for: url, settings: settings)
    }

    private func etRepairCandidate(for attemptedURL: URL, diagnostic: ETModelResolver.ArtifactDiagnostic) -> ETRepairCandidate? {
        guard diagnostic.isRepairable else { return nil }
        let modelDirectory = diagnostic.modelDirectory
        let model = modelManager?.downloadedModels.first(where: { candidate in
            candidate.format == .et && (
                candidate.url == attemptedURL
                || candidate.url == modelDirectory
                || candidate.url.deletingLastPathComponent() == modelDirectory
                || ETModelResolver.modelDirectory(for: candidate.url) == modelDirectory
            )
        })

        return ETRepairCandidate(
            modelID: model?.modelID ?? inferRepoID(from: modelDirectory) ?? "",
            quantLabel: model?.quant ?? "",
            modelURL: model?.url ?? modelDirectory,
            sourceRepoID: diagnostic.sourceRepoID
        )
    }

    private func catalogETSourceRepoID(modelID: String, quantLabel: String) async -> String? {
        guard !modelID.isEmpty else { return nil }
        guard let details = try? await ManualModelRegistry().details(for: modelID) else { return nil }
        let matching = details.quants.first { quant in
            quant.format == .et && (
                quant.label.caseInsensitiveCompare(quantLabel) == .orderedSame
                || quantLabel.isEmpty
            )
        } ?? details.quants.first(where: { $0.format == .et })
        guard let url = matching?.downloadURL else { return nil }
        return huggingFaceRepoID(from: url)
    }

    private func huggingFaceRepoID(from url: URL) -> String? {
        guard let host = url.host, host.contains("huggingface.co") else { return nil }
        var parts = url.path.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
        let prefixes: Set<String> = ["repos", "api", "models"]
        while parts.count > 2, let first = parts.first, prefixes.contains(first) {
            parts.removeFirst()
        }
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    func repairPendingETArtifacts() async {
        guard let candidate = pendingETRepairCandidate else { return }
        let sourceRepo: String?
        if let existing = candidate.sourceRepoID {
            sourceRepo = existing
        } else {
            sourceRepo = await catalogETSourceRepoID(modelID: candidate.modelID, quantLabel: candidate.quantLabel)
        }
        guard sourceRepo != nil || !candidate.modelID.isEmpty else {
            loadError = String(localized: "Repair is unavailable for this ET model. Reinstall it from Explore.")
            return
        }

        loading = true
        stillLoading = false
        defer { loading = false; stillLoading = false }

        do {
            try await ModelDownloadManager().repairETArtifacts(
                modelID: candidate.modelID,
                modelURL: candidate.modelURL,
                sourceRepoID: sourceRepo
            )
            modelManager?.refresh()
            pendingETRepairCandidate = nil
            loadError = String(localized: "Repair finished. Load the ET model again.")
        } catch let diagnostic as ETModelResolver.ArtifactDiagnostic {
            pendingETRepairCandidate = etRepairCandidate(for: candidate.modelURL, diagnostic: diagnostic)
            loadError = diagnostic.userFacingMessage
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func startGGUFLoopbackServer(
        modelURL: URL,
        settings: ModelSettings,
        explicitMMProj: String?,
        bypassRAMCheck: Bool
    ) async throws -> (
        port: Int32,
        effectiveSettings: ModelSettings,
        configuration: LlamaServerBridge.StartConfiguration,
        bridgeReservation: NoemaLlamaClient.BridgeMutationReservation
    ) {
        let bridgeReservation = await NoemaLlamaClient.reserveLoopbackBridge()
        var isHandedOff = false
        defer {
            if !isHandedOff {
                bridgeReservation.release()
            }
        }
        guard bridgeReservation.isActive else { throw CancellationError() }
        try Task.checkCancellation()

        let resolvedLaunch = GGUFServerConfigurationResolver.resolveWithPlan(
            modelURL: modelURL,
            settings: settings,
            mmprojPath: explicitMMProj,
            contextShiftEnabled: contextOverflowStrategy != .stopAtLimit,
            downloadedModels: modelManager?.downloadedModels ?? []
        )
        var primaryConfiguration = resolvedLaunch.configuration
        let overfitPlan = resolvedLaunch.plan
        if case .refused(let reason) = overfitPlan {
            throw NSError(
                domain: "Noema",
                code: 2004,
                userInfo: [NSLocalizedDescriptionKey: OverfitPlanResolver.refusalMessage(reason)]
            )
        }
        var runtimeConfiguration = ModelRAMAdvisor.RuntimeConfiguration.resolved(
            from: settings,
            modelURL: modelURL
        )
        // Size the projector passed to this launch, not a merely discoverable one.
        runtimeConfiguration.projectorPath = explicitMMProj?.isEmpty == false ? explicitMMProj : nil
        runtimeConfiguration.projectorFileBytes = {
            guard let explicitMMProj,
                  let size = (try? FileManager.default.attributesOfItem(atPath: explicitMMProj)[.size]) as? NSNumber else {
                return 0
            }
            return max(0, size.int64Value)
        }()
        var fitAssessment: ModelRAMAdvisor.GGUFLaunchFitAssessment
        if overfitPlan.isPaged, primaryConfiguration.pagedWaves {
            // A 1k graph minimizes expert sweeps, but compute-buffer growth is
            // device/model specific. Try largest-first against llama.cpp's
            // exact no-allocation estimate and the live process headroom.
            // When sizing itself is unavailable, fail open only at the
            // platform's conservative multi-token wave shape.
            var selected: (
                configuration: LlamaServerBridge.StartConfiguration,
                assessment: ModelRAMAdvisor.GGUFLaunchFitAssessment
            )?
            var lastAttempt: (
                configuration: LlamaServerBridge.StartConfiguration,
                assessment: ModelRAMAdvisor.GGUFLaunchFitAssessment
            )?
            for ubatch in OverfitPlanResolver.pagedWaveUbatchCandidates(
                contextCap: primaryConfiguration.contextSize
            ) {
                let candidate = primaryConfiguration.replacingBatchSizes(
                    batchSize: ubatch,
                    ubatchSize: ubatch
                )
                let assessment = await ModelRAMAdvisor.definitiveGGUFLaunchFitAssessment(
                    contextLength: Int(settings.contextLength),
                    kvCacheEstimate: .resolved(from: settings),
                    runtimeConfiguration: runtimeConfiguration,
                    serverConfiguration: candidate
                )
                lastAttempt = (candidate, assessment)
                if assessment.status == .fits
                    || (assessment.status == .unavailable
                        && ubatch <= OverfitPlanResolver.conservativePagedWaveUbatch) {
                    selected = (candidate, assessment)
                    break
                }
            }
            if let resolved = selected ?? lastAttempt {
                primaryConfiguration = resolved.configuration
                fitAssessment = resolved.assessment
            } else {
                fitAssessment = await ModelRAMAdvisor.definitiveGGUFLaunchFitAssessment(
                    contextLength: Int(settings.contextLength),
                    kvCacheEstimate: .resolved(from: settings),
                    runtimeConfiguration: runtimeConfiguration,
                    serverConfiguration: primaryConfiguration
                )
            }
        } else {
            fitAssessment = await ModelRAMAdvisor.definitiveGGUFLaunchFitAssessment(
                contextLength: Int(settings.contextLength),
                kvCacheEstimate: .resolved(from: settings),
                runtimeConfiguration: runtimeConfiguration,
                serverConfiguration: primaryConfiguration
            )
        }
        if overfitPlan.isPaged, fitAssessment.status == .fits {
            // The synchronous plan deliberately starts at one third of live
            // iOS headroom. Once native exact sizing has charged resident
            // weights, KV, compute, staging, and the runtime reserve, spend
            // only the remaining proven slack on a larger decode cache. Two
            // passes absorb slot-size rounding without turning launch into a
            // long search over hundreds of MiB values.
            for _ in 0..<2 {
                let expandedMiB = OverfitPlanResolver.expandedPagedBankBudgetMiB(
                    currentMiB: primaryConfiguration.pagedBankBudgetMiB,
                    requiredBytes: fitAssessment.requiredIncrementalBytes,
                    availableBytes: fitAssessment.availableHeadroomBytes
                )
                guard expandedMiB > primaryConfiguration.pagedBankBudgetMiB else { break }
                let candidate = primaryConfiguration.replacingPagedBankBudgetMiB(expandedMiB)
                let assessment = await ModelRAMAdvisor.definitiveGGUFLaunchFitAssessment(
                    contextLength: Int(settings.contextLength),
                    kvCacheEstimate: .resolved(from: settings),
                    runtimeConfiguration: runtimeConfiguration,
                    serverConfiguration: candidate
                )
                let remaining = (assessment.availableHeadroomBytes ?? 0)
                    - (assessment.requiredIncrementalBytes ?? Int64.max)
                guard assessment.status == .fits,
                      remaining >= OverfitPlanResolver.adaptivePagedBankReserveBytes else {
                    break
                }
                primaryConfiguration = candidate
                fitAssessment = assessment
            }
        }
        if overfitPlan.isPaged {
            let selectedUbatch = primaryConfiguration.ubatchSize
            let selectedBankMiB = primaryConfiguration.pagedBankBudgetMiB
            let selectedStatus = fitAssessment.status
            let selectedRequiredBytes = fitAssessment.requiredIncrementalBytes ?? 0
            let selectedAvailableBytes = fitAssessment.availableHeadroomBytes ?? 0
            Task {
                await logger.log(
                    "[Overfit][LaunchPlan] ubatch=\(selectedUbatch) "
                    + "bankMiB=\(selectedBankMiB) "
                    + "fit=\(String(describing: selectedStatus)) "
                    + "required=\(selectedRequiredBytes) "
                    + "available=\(selectedAvailableBytes)"
                )
            }
        }
        if fitAssessment.status == .doesNotFit,
           !bypassRAMCheck,
           !UserDefaults.standard.bool(forKey: "bypassRAMCheck") {
            Task {
                await logger.log(
                    "[Loopback][RAMGuard] blocked exact=true required=\(fitAssessment.requiredIncrementalBytes ?? 0) available=\(fitAssessment.availableHeadroomBytes ?? 0)"
                )
            }
            throw NSError(
                domain: "Noema",
                code: 2003,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Model likely exceeds memory budget. Lower context or choose a smaller quant.",
                        locale: LocalizationManager.preferredLocale()
                    )
                ]
            )
        }
        func start(_ configuration: LlamaServerBridge.StartConfiguration) async -> Int32 {
            await Task.detached { @Sendable () -> Int32 in
                NoemaLlamaClient.replaceLoopbackServer(
                    with: configuration,
                    reservation: bridgeReservation
                )
            }.value
        }

        let baselineFootprint = ModelRAMAdvisor.processFootprintBytes()
        let peakSampler = Task.detached(priority: .utility) {
            var peak = baselineFootprint
            while !Task.isCancelled {
                peak = max(peak, ModelRAMAdvisor.processFootprintBytes())
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return max(peak, ModelRAMAdvisor.processFootprintBytes())
        }
        if case .paged(let pagedParameters) = overfitPlan {
            // Must precede start(): the bridge reads NOEMA_PAGED_SLOT_SAVE_DIR
            // at argv-build time to enable the slot save/restore endpoints.
            OverfitPromptStateCache.shared.prepareForPagedLaunch(
                packageDirectory: pagedParameters.packageDirectory,
                configuration: primaryConfiguration,
                systemPromptText: systemPromptText
            )
            // Also pre-start: the paged runtime samples NOEMA_PAGED_NOCACHE
            // when it configures for this boot. The store's hysteretic
            // per-volume decision turns page-cache bypass on only where the
            // calibrated F_NOCACHE bandwidth clearly beats the cached path.
            OverfitStorageCalibrationStore.shared.applyNoCacheEnvironment(
                packageDirectory: pagedParameters.packageDirectory
            )
        }
        let primaryPort = await start(primaryConfiguration)
        peakSampler.cancel()
        let peakFootprint = await peakSampler.value
        if primaryPort > 0 {
            // Paged launches never feed the resident transient-reserve
            // calibration: their allocation shape is intentionally different.
            if let exactBytes = fitAssessment.estimatedIncrementalBytes, !overfitPlan.isPaged {
                ModelRAMAdvisor.recordSuccessfulGGUFLaunch(
                    estimatedIncrementalBytes: exactBytes,
                    baselineFootprintBytes: baselineFootprint,
                    peakFootprintBytes: peakFootprint
                )
            }
            logLastLoopbackStartOptions(prefix: "[Loopback][StartOptions][Load]")
            if overfitPlan.isPaged {
                OverfitGovernorController.shared.beginPagedSession()
                // Restore persisted prompt KV before the first user request;
                // fail-open inside — a failed restore just prefills cold.
                await OverfitPromptStateCache.shared.restoreIfAvailable(port: primaryPort)
            }
            isHandedOff = true
            return (primaryPort, settings, primaryConfiguration, bridgeReservation)
        }

        let diagnostics = LlamaServerBridge.lastStartDiagnostics()
        let reason = diagnostics?.message.isEmpty == false
            ? (diagnostics?.message ?? "startup_failed")
            : (diagnostics?.code ?? "startup_failed")
        Task {
            await logger.log(
                "[Loopback] start.failed reason=\(reason) settings_unchanged=true"
            )
        }

        throw NSError(
            domain: "Noema",
            code: 2001,
            userInfo: [
                NSLocalizedDescriptionKey: LoopbackStartupPlanner.formatFailureMessage(diagnostics)
            ]
        )
    }

    func ensureClient(
        url: URL,
        settings: ModelSettings?,
        format: ModelFormat?,
        forceReload: Bool,
        bypassRAMCheck: Bool = false
    ) async throws {
        let requestedFormat = format ?? ModelFormat.detect(from: url)
        if client != nil, !forceReload { return }
#if os(macOS)
        // A stronger GGUF owns the same process-global bridge used by a GGUF
        // chat model. Release it completely before the resident loader resets
        // the bridge, and reserve that bridge through the full async load so a
        // queued prewarm cannot reclaim it in the middle of replacement.
        guard await AutopilotLocalEscalationRuntime.shared.beginResidentModelLoad(
            manager: modelManager
        ) else {
            throw NSError(
                domain: "Noema.AutopilotLocalEscalation",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Wait for the stronger model's response to finish before loading another chat model.",
                        locale: LocalizationManager.preferredLocale()
                    )
                ]
            )
        }
        defer {
            AutopilotLocalEscalationRuntime.shared.endResidentModelLoad()
        }
#endif
        if client != nil {
            // Fully unload the existing runner before starting a new load to avoid
            // llama.cpp/Metal races on iOS when models are reloaded back‑to‑back.
            await unload()
        }
        // A prior ChatVM GGUF was ownership-safely stopped by `unload()` above.
        // Non-GGUF backends do not use the loopback, so they must not stop a
        // server owned by Relay, LocalVLM, or another app subsystem.
        loadingProgressTracker.startLoading(for: requestedFormat)
        loadingProgressTracker.reportBackendProgress(0.02)
        loading = true
        stillLoading = false
        loadError = nil
        pendingETRepairCandidate = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.loading == true { self?.stillLoading = true }
        }
        defer { loading = false; stillLoading = false }

        var pendingGGUFBridgeReservation: NoemaLlamaClient.BridgeMutationReservation?
        var pendingGGUFConfiguration: LlamaServerBridge.StartConfiguration?
        defer { pendingGGUFBridgeReservation?.release() }

        let prepared = try await prepareLoad(for: url, settings: settings, format: format)
        var loadURL = prepared.url
        let detectedFmt = prepared.format
        var finalSettings = prepared.settings
        if let settings = finalSettings {
            let powerDecision = GenerationPowerPolicy.adjustedSettings(settings, format: detectedFmt)
            finalSettings = powerDecision.settings
            if powerDecision.adapted {
                Task {
                    await logger.log(
                        "[GenerationPower] adapted=true format=\(detectedFmt.rawValue) threads=\(powerDecision.originalThreadCount)->\(powerDecision.appliedThreadCount) reasons=\(powerDecision.reasons.map(\.rawValue).joined(separator: ","))"
                    )
                }
            }
        }
        let preparedPromptTemplateSource = prepared.promptTemplateSource ?? PromptTemplateSource.defaultTemplate.rawValue
        inferenceBackendSummary = nil
        loadingProgressTracker.reportBackendProgress(0.08)

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            let sizeGB = Double(size) / 1_073_741_824.0
            let text = DeviceRAMInfo.current().limit
            if let num = Double(text.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)),
               sizeGB > num {
                loadError = "Model may exceed available RAM (\(String(format: "%.1f", sizeGB)) GB > \(text))"
            }
        }
        if let s = finalSettings {
            if verboseLogging { print("[ChatVM] loading \(loadURL.lastPathComponent) with context \(Int(s.contextLength))") }
        } else {
            if verboseLogging {
                let kind: String = {
                    switch detectedFmt {
                    case .gguf: return "GGUF"
                    case .mlx: return "MLX"
                    case .et: return "ET"
                    case .ane: return ModelFormat.ane.displayName
                    case .afm: return "AFM"
                    case .coreai: return "Core AI"
                    }
                }()
                print("[ChatVM] loading \(kind) from \(loadURL.lastPathComponent)…")
            }
        }
        if verboseLogging { print("MODEL_LOAD_START \(Date().timeIntervalSince1970)") }

        let llamaOptions = LlamaOptions(extraEOSTokens: ["<|im_end|>", "<end_of_turn>"], verbose: true)
        // Resolve projector info next to the model (if any). Always start the
        // in‑process HTTP server bound to 127.0.0.1 for GGUF models so all GGUF
        // inference routes through the loopback server (single execution path).
        let shouldLoadVisionProjector = finalSettings?.loadVisionProjector ?? true
        let explicitMMProj: String? = shouldLoadVisionProjector
            ? ProjectorLocator.projectorPath(alongside: loadURL)
            : nil
        let hasMergedProjector: Bool = (detectedFmt == .gguf && shouldLoadVisionProjector)
            ? GGUFMetadata.hasMultimodalProjector(at: loadURL)
            : false
        if detectedFmt == .gguf {
            loadingProgressTracker.reportBackendProgress(0.15)
            if finalSettings == nil {
                finalSettings = ModelSettings.default(for: .gguf)
            }
            loadingProgressTracker.reportBackendProgress(0.22)
            let outcome = try await startGGUFLoopbackServer(
                modelURL: loadURL,
                settings: finalSettings ?? ModelSettings.default(for: .gguf),
                explicitMMProj: explicitMMProj,
                bypassRAMCheck: bypassRAMCheck
            )
            finalSettings = outcome.effectiveSettings
            pendingGGUFBridgeReservation = outcome.bridgeReservation
            pendingGGUFConfiguration = outcome.configuration
            let p = outcome.port

            if p > 0 {
                // This flag previously meant "vision is enabled via loopback".
                // GGUF inference now always routes through loopback, so treat it as
                // "loopback enabled" (UI image support is gated separately).
                LoopbackVisionState.setEnabled(true)
                let projName = explicitMMProj.map { URL(fileURLWithPath: $0).lastPathComponent } ?? (hasMergedProjector ? "merged" : "none")
                let templateLabel = TemplateDrivenModelSupport.templateLabel(modelURL: loadURL)
                if verboseLogging { print("[ChatVM] Started loopback llama.cpp server on 127.0.0.1:\(p) mmproj=\(projName)") }
                Task { await logger.log("[Loopback] start host=127.0.0.1 port=\(p) gguf=\(loadURL.lastPathComponent) mmproj=\(projName) template=\(templateLabel)") }
                loadingProgressTracker.reportBackendProgress(0.96)
            }
        }
        let contextOverride = finalSettings.map { settings -> Int in
            let clamped = max(1.0, min(settings.contextLength, Double(Int32.max)))
            return Int(clamped)
        }
        let threadOverride = finalSettings.map { settings -> Int in
            let requested = settings.cpuThreads > 0 ? settings.cpuThreads : ModelSettings.recommendedInferenceThreadCount
            // Hard-clamp so inference always leaves a core free for the UI.
            return min(max(1, requested), ModelSettings.maxInferenceThreadCount)
        }
        let llamaParameter = LlamaParameter(
            options: llamaOptions,
            contextLength: contextOverride,
            threadCount: threadOverride,
            mmproj: explicitMMProj,
            loadVisionProjector: shouldLoadVisionProjector,
            serverConfiguration: pendingGGUFConfiguration
        )

        if let f = format {
            switch f {
            case .mlx:
                print("[ChatVM] MLX load start: \(loadURL.path)")
                SettingsStore.shared.webSearchArmed = false
                loadingProgressTracker.reportBackendProgress(0.2)
                // Choose VLM vs Text based on model contents
                if MLXBridge.isVLMModel(at: loadURL) {
                    loadingProgressTracker.reportBackendProgress(0.34)
                    client = try await MLXBridge.makeVLMClient(url: loadURL, settings: finalSettings)
                } else {
                    loadingProgressTracker.reportBackendProgress(0.34)
                    client = try await MLXBridge.makeTextClient(url: loadURL, settings: finalSettings)
                }
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .mlx
            case .gguf:
                loadingProgressTracker.reportBackendProgress(0.35)
                guard let bridgeReservation = pendingGGUFBridgeReservation else {
                    throw NSError(
                        domain: "Noema",
                        code: 2002,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "The GGUF runtime is already in use.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        ]
                    )
                }
                client = try await AnyLLMClient(
                    NoemaLlamaClient.llama(
                        url: loadURL,
                        parameter: llamaParameter,
                        bridgeReservation: bridgeReservation
                    )
                )
                loadingProgressTracker.reportBackendProgress(0.96)
                loadedFormat = .gguf
            case .et:
                guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, visionOS 1.0, *) else {
                    throw NSError(
                        domain: "Noema",
                        code: -2,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "ET models are not supported on this platform.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        ]
                    )
                }
                loadingProgressTracker.reportBackendProgress(0.12)
                let artifacts = try resolveETLoadArtifacts(url: loadURL, settings: finalSettings)
                loadURL = artifacts.pteURL
                var etSettings = finalSettings ?? ModelSettings.default(for: .et)
                etSettings.etBackend = ETBackendDetector.effectiveBackend(userSelected: etSettings.etBackend, detected: nil)
                let likelyVision = artifacts.pteURL.lastPathComponent.lowercased().contains("vision")
                    || artifacts.pteURL.deletingLastPathComponent().lastPathComponent.lowercased().contains("vision")
                let etClient = ExecuTorchLLMClient(
                    modelPath: artifacts.pteURL.path,
                    tokenizerPath: artifacts.tokenizerURL.path,
                    isVision: likelyVision,
                    settings: etSettings
                )
                await etClient.syncSystemPrompt(systemPromptText)
                try await etClient.load()
                client = AnyLLMClient(etClient)
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .et
            case .ane:
                #if os(iOS) || os(visionOS)
                guard #available(iOS 18.0, visionOS 2.0, *) else {
                    throw NSError(
                        domain: "Noema",
                        code: -2,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "CML models require iOS 18 or visionOS 2.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        ]
                    )
                }
                loadingProgressTracker.reportBackendProgress(0.14)
                let resolved = try ANEModelResolver.resolve(modelURL: loadURL)
                let aneSettings = finalSettings ?? ModelSettings.default(for: .ane)
                let aneClient = try CoreMLLLMClient(resolvedModel: resolved, settings: aneSettings)
                await aneClient.syncSystemPrompt(systemPromptText)
                try await aneClient.load()
                let cmlLoadSummary = await aneClient.loadDiagnosticsSummary().map { " \($0)" } ?? ""
                let trimmedCMLLoadSummary = cmlLoadSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                inferenceBackendSummary = trimmedCMLLoadSummary.isEmpty ? nil : trimmedCMLLoadSummary
                Task {
                    await logger.log("[ChatVM][Load][CML] flavor=\(resolved.flavor.rawValue) source=\(resolved.sourceModelURL.lastPathComponent) compiled=\(resolved.compiledModelURL.lastPathComponent) templateSource=\(preparedPromptTemplateSource)\(cmlLoadSummary)")
                }
                client = AnyLLMClient(aneClient)
                loadURL = resolved.modelRoot
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .ane
                #else
                throw NSError(
                    domain: "Noema",
                    code: -2,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "CML models are supported only on iOS and visionOS.",
                            locale: LocalizationManager.preferredLocale()
                        )
                    ]
                )
                #endif
            case .afm:
                let afmClient = AFMLLMClient(
                    modelKind: prepared.appleModelKind ?? .onDevice,
                    guardrailsMode: AFMLLMClient.resolvedGuardrailsMode(from: finalSettings),
                    pccReasoningLevel: finalSettings?.pccReasoningLevel ?? .moderate,
                    onToolSummary: { [weak self] summary in
                        await MainActor.run {
                            self?.handleAFMToolSummary(summary)
                        }
                    }
                )
                activeAFMClient = afmClient
                activeAppleFoundationModelKind = prepared.appleModelKind ?? .onDevice
                await afmClient.syncSystemPrompt(systemPromptText)
                try await afmClient.load()
                client = AnyLLMClient(
                    textStream: { input in
                        try await afmClient.textStream(from: input)
                    },
                    cancel: { afmClient.cancelActive() },
                    unload: { afmClient.unload() },
                    syncSystemPrompt: { prompt in
                        await afmClient.syncSystemPrompt(prompt)
                    }
                )
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .afm
            case .coreai:
                loadingProgressTracker.reportBackendProgress(0.14)
                let resolved = try CoreAIModelResolver.resolve(modelURL: loadURL)
                let coreaiClient = CoreAILLMClient(
                    resolved: resolved,
                    settings: finalSettings ?? .default(for: .coreai)
                )
                await coreaiClient.syncSystemPrompt(systemPromptText)
                try await coreaiClient.load()
                client = AnyLLMClient(
                    textStream: { input in
                        try await coreaiClient.textStream(from: input)
                    },
                    textStreamWithProgress: { input, onPromptProgress in
                        try await coreaiClient.textStream(from: input, onPromptProgress: onPromptProgress)
                    },
                    cancel: nil,
                    unload: { coreaiClient.unload() },
                    syncSystemPrompt: { prompt in
                        await coreaiClient.syncSystemPrompt(prompt)
                    }
                )
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .coreai
            }
        } else {
            // Auto-detect format and load via appropriate client
            let detected = ModelFormat.detect(from: loadURL)
            switch detected {
            case .mlx:
                print("[ChatVM] MLX load start: \(loadURL.path)")
                SettingsStore.shared.webSearchArmed = false
                loadingProgressTracker.reportBackendProgress(0.2)
                if MLXBridge.isVLMModel(at: loadURL) {
                    loadingProgressTracker.reportBackendProgress(0.34)
                    client = try await MLXBridge.makeVLMClient(url: loadURL, settings: finalSettings)
                } else {
                    loadingProgressTracker.reportBackendProgress(0.34)
                    client = try await MLXBridge.makeTextClient(url: loadURL, settings: finalSettings)
                }
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .mlx
            case .gguf:
                loadingProgressTracker.reportBackendProgress(0.35)
                guard let bridgeReservation = pendingGGUFBridgeReservation else {
                    throw NSError(
                        domain: "Noema",
                        code: 2002,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "The GGUF runtime is already in use.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        ]
                    )
                }
                client = try await AnyLLMClient(
                    NoemaLlamaClient.llama(
                        url: loadURL,
                        parameter: llamaParameter,
                        bridgeReservation: bridgeReservation
                    )
                )
                loadingProgressTracker.reportBackendProgress(0.96)
                loadedFormat = .gguf
            case .et:
                guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, visionOS 1.0, *) else {
                    throw NSError(
                        domain: "Noema",
                        code: -2,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "ET models are not supported on this platform.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        ]
                    )
                }
                loadingProgressTracker.reportBackendProgress(0.12)
                let artifacts = try resolveETLoadArtifacts(url: loadURL, settings: finalSettings)
                loadURL = artifacts.pteURL
                var etSettings = finalSettings ?? ModelSettings.default(for: .et)
                etSettings.etBackend = ETBackendDetector.effectiveBackend(userSelected: etSettings.etBackend, detected: nil)
                let likelyVision = artifacts.pteURL.lastPathComponent.lowercased().contains("vision")
                    || artifacts.pteURL.deletingLastPathComponent().lastPathComponent.lowercased().contains("vision")
                let etClient = ExecuTorchLLMClient(
                    modelPath: artifacts.pteURL.path,
                    tokenizerPath: artifacts.tokenizerURL.path,
                    isVision: likelyVision,
                    settings: etSettings
                )
                await etClient.syncSystemPrompt(systemPromptText)
                try await etClient.load()
                client = AnyLLMClient(etClient)
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .et
            case .ane:
                #if os(iOS) || os(visionOS)
                guard #available(iOS 18.0, visionOS 2.0, *) else {
                    throw NSError(
                        domain: "Noema",
                        code: -2,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "CML models require iOS 18 or visionOS 2.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        ]
                    )
                }
                loadingProgressTracker.reportBackendProgress(0.14)
                let resolved = try ANEModelResolver.resolve(modelURL: loadURL)
                let aneSettings = finalSettings ?? ModelSettings.default(for: .ane)
                let aneClient = try CoreMLLLMClient(resolvedModel: resolved, settings: aneSettings)
                await aneClient.syncSystemPrompt(systemPromptText)
                try await aneClient.load()
                let cmlLoadSummary = await aneClient.loadDiagnosticsSummary().map { " \($0)" } ?? ""
                let trimmedCMLLoadSummary = cmlLoadSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                inferenceBackendSummary = trimmedCMLLoadSummary.isEmpty ? nil : trimmedCMLLoadSummary
                Task {
                    await logger.log("[ChatVM][Load][CML] flavor=\(resolved.flavor.rawValue) source=\(resolved.sourceModelURL.lastPathComponent) compiled=\(resolved.compiledModelURL.lastPathComponent) templateSource=\(preparedPromptTemplateSource)\(cmlLoadSummary)")
                }
                client = AnyLLMClient(aneClient)
                loadURL = resolved.modelRoot
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .ane
                #else
                throw NSError(
                    domain: "Noema",
                    code: -2,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "CML models are supported only on iOS and visionOS.",
                            locale: LocalizationManager.preferredLocale()
                        )
                    ]
                )
                #endif
            case .afm:
                let afmClient = AFMLLMClient(
                    modelKind: prepared.appleModelKind ?? .onDevice,
                    guardrailsMode: AFMLLMClient.resolvedGuardrailsMode(from: finalSettings),
                    pccReasoningLevel: finalSettings?.pccReasoningLevel ?? .moderate,
                    onToolSummary: { [weak self] summary in
                        await MainActor.run {
                            self?.handleAFMToolSummary(summary)
                        }
                    }
                )
                activeAFMClient = afmClient
                activeAppleFoundationModelKind = prepared.appleModelKind ?? .onDevice
                await afmClient.syncSystemPrompt(systemPromptText)
                try await afmClient.load()
                client = AnyLLMClient(
                    textStream: { input in
                        try await afmClient.textStream(from: input)
                    },
                    cancel: { afmClient.cancelActive() },
                    unload: { afmClient.unload() },
                    syncSystemPrompt: { prompt in
                        await afmClient.syncSystemPrompt(prompt)
                    }
                )
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .afm
            case .coreai:
                loadingProgressTracker.reportBackendProgress(0.14)
                let resolved = try CoreAIModelResolver.resolve(modelURL: loadURL)
                let coreaiClient = CoreAILLMClient(
                    resolved: resolved,
                    settings: finalSettings ?? .default(for: .coreai)
                )
                await coreaiClient.syncSystemPrompt(systemPromptText)
                try await coreaiClient.load()
                client = AnyLLMClient(
                    textStream: { input in
                        try await coreaiClient.textStream(from: input)
                    },
                    textStreamWithProgress: { input, onPromptProgress in
                        try await coreaiClient.textStream(from: input, onPromptProgress: onPromptProgress)
                    },
                    cancel: nil,
                    unload: { coreaiClient.unload() },
                    syncSystemPrompt: { prompt in
                        await coreaiClient.syncSystemPrompt(prompt)
                    }
                )
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .coreai
            }
        }

        currentKind = ModelKind.detect(id: url.lastPathComponent)
        usePrompt = true
        gemmaAutoTemplated = false
        loadedURL = loadURL
        loadedSettings = finalSettings ?? ModelSettings.default(for: loadedFormat ?? .gguf)
        promptTemplateSourceLabel = prepared.promptTemplateSource
            ?? ((loadedSettings?.promptTemplate?.isEmpty == false) ? "custom" : PromptTemplateSource.defaultTemplate.rawValue)

        modelLoaded = true
        AccessibilityAnnouncer.announceLocalized("Model loaded.")

        // Update image-input capability from stored metadata.
        // Only advertise image input when we *know* the selected model is vision-capable.
        var imageDetectNotes: [String] = []
        if let loadedModel = modelManager?.downloadedModels.first(where: { $0.url == loadURL }) {
            let storedVision = loadedModel.isMultimodal
            imageDetectNotes.append("store.isMultimodal=\(storedVision)")
            if storedVision {
                if loadedFormat == .gguf {
                    // For GGUF VLMs, require a projector either merged in the GGUF or present as a sibling file.
                    let projectorEnabled = loadedSettings?.loadVisionProjector ?? true
                    let hasProj = projectorEnabled && ((ProjectorLocator.projectorPath(alongside: loadURL) != nil) || GGUFMetadata.hasMultimodalProjector(at: loadURL))
                    supportsImageInput = hasProj
                    imageDetectNotes.append("gguf.projectorEnabled=\(projectorEnabled)")
                    imageDetectNotes.append("gguf.projector=\(hasProj)")
                } else {
                    supportsImageInput = true
                }
            } else if loadedFormat == .et {
                let inferredVision = ETModelResolver.isVisionIdentifier(loadedModel.modelID) || ETModelResolver.isLikelyVisionModel(at: loadURL)
                supportsImageInput = inferredVision
                imageDetectNotes.append("et.heuristic=\(inferredVision)")
                if inferredVision {
                    modelManager?.setCapabilities(
                        modelID: loadedModel.modelID,
                        quant: loadedModel.quant,
                        isMultimodal: true,
                        isToolCapable: true
                    )
                }
            } else {
                supportsImageInput = false
            }
        } else {
            if loadedFormat == .et {
                let slug = loadURL.deletingPathExtension().lastPathComponent
                supportsImageInput = ETModelResolver.isVisionIdentifier(slug) || ETModelResolver.isLikelyVisionModel(at: loadURL)
                imageDetectNotes.append("store.missing+et.heuristic=\(supportsImageInput)")
            } else {
                supportsImageInput = false
                imageDetectNotes.append("store.missing")
            }
        }
        // Apple Foundation Model gained on-device multimodal prompting on iOS 27.
        if loadedFormat == .afm {
            #if NOEMA_ENABLE_XCODE27_APIS
            if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                supportsImageInput = true
                imageDetectNotes.append("afm.vision=ios27")
            } else {
                supportsImageInput = false
                imageDetectNotes.append("afm.vision=unavailable")
            }
            #else
            supportsImageInput = false
            imageDetectNotes.append("afm.vision=sdk<27")
            #endif
        }
        Task { await logger.log("[Images][Capability] format=\(String(describing: loadedFormat)) supports=\(supportsImageInput) notes=\(imageDetectNotes.joined(separator: ","))") }

        // Persist current model format and function-calling capability for tool gating (e.g., web search)
        do {
            let d = UserDefaults.standard
            if let fmt = loadedFormat { d.set(fmt.rawValue, forKey: "currentModelFormat") }
            if loadedFormat == .afm {
                d.set(
                    (activeAppleFoundationModelKind ?? .onDevice).rawValue,
                    forKey: AppleFoundationModelKind.persistedCurrentKindKey
                )
            }
            d.set(false, forKey: "currentModelIsRemote")
            var supportsToolCalls = false
            let matchedModel = loadedURL.flatMap { u in modelManager?.downloadedModels.first(where: { $0.url == u }) }
            if let m = matchedModel { supportsToolCalls = m.isToolCapable }
            // Re-run the on-disk scan at load (independent of the downloadedModels match,
            // whose URL comparison can miss) so improved local detection — e.g. now scanning
            // chat_template.jinja for MLX — applies to already-imported models without re-import.
            if supportsToolCalls == false, let u = loadedURL, let fmt = loadedFormat {
                supportsToolCalls = ToolCapabilityDetector.isToolCapableLocal(url: u, format: fmt)
            }
            if supportsToolCalls == false, let m = matchedModel {
                supportsToolCalls = await ToolCapabilityDetector.isToolCapableCachedOrHeuristic(repoId: m.modelID)
            }
            if loadedFormat == .et || loadedFormat == .afm { supportsToolCalls = true }
            d.set(supportsToolCalls, forKey: "currentModelSupportsFunctionCalling")

            // Reasoning toggle capability + the loaded model's saved preference.
            var supportsReasoning = false
            if let u = loadedURL, let fmt = loadedFormat {
                supportsReasoning = ReasoningCapabilityDetector.isReasoningCapableLocal(url: u, format: fmt)
            }
            d.set(supportsReasoning, forKey: "currentModelSupportsReasoning")
            currentModelSupportsReasoning = supportsReasoning
            reasoningEnabled = loadedSettings?.reasoningEnabled ?? true

            await logger.log("[ChatVM][Tools] supportsFunctionCalling=\(supportsToolCalls) format=\(loadedFormat.map { $0.rawValue } ?? "nil") matched=\(matchedModel != nil) flag=\(matchedModel?.isToolCapable ?? false) localScan=\(loadedURL.flatMap { u in loadedFormat.map { ToolCapabilityDetector.isToolCapableLocal(url: u, format: $0) } } ?? false) url=\(loadedURL?.lastPathComponent ?? "nil")")
        }

        if verboseLogging { print("MODEL_LOAD_READY \(Date().timeIntervalSince1970)") }
        if verboseLogging { print("[ChatVM] client ready ✅") }
        if loadedFormat == .mlx { print("[ChatVM] MLX client ready ✅") }
        // Explicit Save/Load actions own durable settings changes; failed startup
        // handling must not rewrite the user's saved model settings.
    }

    func load(
        url: URL,
        settings: ModelSettings? = nil,
        format: ModelFormat? = nil,
        forceReload: Bool = false
    ) async -> Bool {
        await load(
            url: url,
            settings: settings,
            format: format,
            forceReload: forceReload,
            bypassRAMCheck: false
        )
    }

    func load(
        url: URL,
        settings: ModelSettings?,
        format: ModelFormat?,
        forceReload: Bool,
        bypassRAMCheck: Bool
    ) async -> Bool {
        lastLoadBlockedByRAMSafety = false
#if os(macOS)
        if RelayManagementViewModel.shared.relayHasLocalOwnership {
            loadError = String(
                localized: "Relay currently owns local model runtime. Unload Relay's local model before loading one in chat.",
                locale: LocalizationManager.preferredLocale()
            )
            return false
        }
#endif
        var fmt = format
        if fmt == nil {
            fmt = ModelFormat.detect(from: url)
        }
        // Enforce repository policy: GGUF files must always run through our
        // compiled llama.cpp loopback backend.
        if url.pathExtension.lowercased() == "gguf" {
            fmt = .gguf
        }
        if fmt == .et, ETModelResolver.pteURL(for: url) == nil, url.pathExtension.lowercased() == "gguf" {
            fmt = .gguf
        }

        // Noema Teams policy: block disallowed formats and disallowed specific models
        // here, at the single local-model load choke point.
        if EnterprisePolicyGate.isActive {
            let policyMessage = String(
                localized: "Blocked by your organization's policy.",
                locale: LocalizationManager.preferredLocale()
            )
            if let fmt, !EnterprisePolicyGate.allowsModelFormat(fmt) {
                loadError = policyMessage
                Task { await logger.log("[ChatVM][Load] blocked_by_policy format=\(fmt.rawValue)") }
                return false
            }
            let resolvedModelID = modelManager?.downloadedModels.first(where: {
                $0.url == url || url.path.hasPrefix($0.url.path)
            })?.modelID
            if !EnterprisePolicyGate.allowsModel(modelID: resolvedModelID) {
                loadError = policyMessage
                Task { await logger.log("[ChatVM][Load] blocked_by_policy modelID=\(resolvedModelID ?? "<unknown>")") }
                return false
            }
        }

        // Set the loading model name for the notification
        let modelName = displayLoadName(for: url, format: fmt)
        await MainActor.run {
            modelManager?.loadingModelName = modelName
            lastUnloadVerification = nil
        }
        Task {
            await logger.log("[ChatVM][Load] begin model=\(modelName) format=\(fmt?.displayName ?? "<auto>") forceReload=\(forceReload)")
        }

        do {
            try await ensureClient(
                url: url,
                settings: settings,
                format: fmt,
                forceReload: forceReload,
                bypassRAMCheck: bypassRAMCheck
            )
            let readinessTimeout: TimeInterval = (fmt == .gguf) ? 5.0 : 2.0
            guard await waitForChatInputReadiness(timeout: readinessTimeout) else {
                let message = "Model finished loading backend resources but never reached chat-ready state."
                loadError = message
                Task {
                    await logger.log("[ChatVM][Load] failed_ready model=\(modelName) timeout_s=\(String(format: "%.1f", readinessTimeout))")
                }
                await MainActor.run {
                    modelManager?.loadingModelName = nil
                }
                return false
            }
            self.promptTemplate = self.loadedSettings?.promptTemplate
            Haptics.success()
            AppSoundPlayer.play(.loadSuccess)
            Task {
                await logger.log("[ChatVM][Load] success model=\(modelName)")
            }

            await MainActor.run {
                modelManager?.loadingModelName = nil
            }

            return true
        } catch {
            // Surface the error to the UI so the user knows what failed.
            let nsError = error as NSError
            lastLoadBlockedByRAMSafety = nsError.domain == "Noema" && nsError.code == 2003
            if let diagnostic = error as? ETModelResolver.ArtifactDiagnostic {
                pendingETRepairCandidate = etRepairCandidate(for: url, diagnostic: diagnostic)
                loadError = diagnostic.userFacingMessage
            } else {
                pendingETRepairCandidate = nil
                loadError = UserFacingErrorFormatter.message(for: error, context: .localModel)
            }
            if verboseLogging { print("[ChatVM] ❌ \(error.localizedDescription)") }
            Task {
                await logger.log("[ChatVM][Load] failed model=\(modelName) error=\(error.localizedDescription)")
            }

            await MainActor.run {
                modelManager?.loadingModelName = nil
            }

            return false
        }
    }

    private func waitForChatInputReadiness(timeout: TimeInterval) async -> Bool {
        if canAcceptChatInput {
            return true
        }
        let started = Date()
        let deadline = started.addingTimeInterval(max(0.5, timeout))
        while Date() < deadline {
            if canAcceptChatInput {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return canAcceptChatInput
    }

    func activeClientForBenchmark() throws -> AnyLLMClient {
        guard let client else {
            throw NSError(domain: "Noema", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model client is not ready"])
        }
        return client
    }

    func makeBenchmarkInput(from rawPrompt: String) -> LLMInput {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if loadedFormat == .et {
            let userMessage = ChatMessage(role: "user", content: prompt)
            return LLMInput(.messages([userMessage]))
        }

        let history: [Msg] = [Msg(role: "🧑‍💻", text: prompt, timestamp: Date())]
        let systemPrompt = systemPromptText
        Task {
            await logger.log(Self.systemPromptMetadataSummary(systemPrompt))
        }
        let rendered = prepareForGeneration(messages: history, system: systemPrompt)
        switch rendered {
        case .messages(let messages):
            let chatMessages = messages.map { ChatMessage(role: $0.role, content: $0.content) }
            return LLMInput(.messages(chatMessages))
        case .plain(let text):
            return LLMInput(.plain(text))
        }
    }

    nonisolated static func guessLlamaVisionModel(from url: URL) -> Bool {
        ModelVisionDetector.guessLlamaVisionModel(from: url)
    }

    @discardableResult
    func detachClientAndUnloadResources() -> AnyLLMClient? {
        invalidateActiveRun()
        cancelAutoRoutingTask()
        // Ensure any in-flight loading HUD stops immediately when unloading/ejecting
        if loading {
            loading = false
        } else {
            loadingProgressTracker.completeLoading()
        }
        stillLoading = false

        // Ensure all async work stops before releasing the client to avoid leaks.
        currentContextTask?.cancel()
        currentContextTask = nil
        currentStreamTask?.cancel()
        currentStreamTask = nil
        cancelTurnScopedEscalationAndContinuation()
        titleTask?.cancel()
        titleTask = nil

        // Preserve rolling thought boxes across unloads. Finish any in-flight streams
        // so boxes transition to a completed state, and persist their state.
        for viewModel in rollingThoughtViewModels.values {
            if viewModel.phase != .complete { viewModel.finish() }
        }
        persistRollingThoughtsNow()

        if let service = remoteService {
            Task {
                await service.setTransportObserver(nil)
#if os(iOS) || os(visionOS)
                await service.setLANRefreshHandler(nil)
#endif
                await service.cancelActiveStream()
            }
        }
        remoteService = nil
        systemPromptToolAvailabilityOverride = nil
        if activeRemoteBackendID != nil {
            modelManager?.activeRemoteSession = nil
        }
        activeRemoteBackendID = nil
        activeRemoteModelID = nil
        remoteLoadingPending = false
        UserDefaults.standard.set(false, forKey: "currentModelIsRemote")
        UserDefaults.standard.set(false, forKey: "currentModelSupportsReasoning")
        currentModelSupportsReasoning = false

        let detachedClient = client
        client = nil
        modelLoaded = false
        loadedURL = nil
        loadedSettings = nil
        loadedFormat = nil
        activeAFMClient = nil
        activeAppleFoundationModelKind = nil
        promptTemplateSourceLabel = PromptTemplateSource.defaultTemplate.rawValue
        inferenceBackendSummary = nil
        return detachedClient
    }

    static func unloadDetachedClient(_ client: AnyLLMClient?) async {
        guard let client else { return }
        await client.unloadAndWait()
    }

    static func beginDetachedClientUnload(_ client: AnyLLMClient?) {
        guard let client else { return }
        Task {
            await client.unloadAndWait()
        }
    }

    func fetchToolSpecs() async -> [ToolSpec] {
        if !toolSpecsCache.isEmpty { return toolSpecsCache }
        await ToolRegistrar.shared.initializeTools()
        let specs = await MainActor.run { () -> [ToolSpec] in
            (try? ToolRegistry.shared.generateToolSpecs()) ?? []
        }
        toolSpecsCache = specs
        return specs
    }

    func fetchEnabledToolSpecs() async -> [ToolSpec] {
        let specs = await fetchToolSpecs()
        let availableNames = Set(await ToolManager.shared.availableTools)
        let permissions = activeToolPermissions
        let pdfOnlyDocumentAccess = isPDFOnlyDocumentAccess
        let remoteModel = UserDefaults.standard.bool(forKey: "currentModelIsRemote")
        let enabled = specs.filter {
            availableNames.contains($0.function.name)
                && permissions.allows(toolName: $0.function.name)
                && !(pdfOnlyDocumentAccess && $0.function.name == "noema.rag.search")
        }
#if os(macOS)
        let hasSelectedMCPTools = MCPServerManager.shared.servers.contains { server in
            permissions.selectedMCPServerIDs.contains(server.id)
                && server.state == .ready
                && (!remoteModel || server.configuration.policy.allowCloudModels)
                && server.tools.contains { server.configuration.policy.isToolEnabled($0.originalName) }
        }
        let filtered = enabled.filter {
            if $0.function.name == MCPFindTool.toolName || $0.function.name == MCPCallTool.toolName {
                return hasSelectedMCPTools
            }
            return !$0.function.name.hasPrefix("mcp_") || MCPServerManager.shared.isToolSelectable(
                    alias: $0.function.name,
                    selectedServerIDs: permissions.selectedMCPServerIDs,
                    remoteModel: remoteModel
                )
        }
#else
        let filtered = enabled
#endif
#if os(macOS)
        return MCPToolCatalogBudget.apply(to: filtered, usablePromptTokens: currentPromptBudget().usablePromptTokens)
#else
        return filtered
#endif
    }

    func toolAvailability(from specs: [ToolSpec]) -> ToolAvailability {
        let names = Set(specs.map(\.function.name))
        let pdfReadFromSpecs = names.contains("noema.pdf.read")
        return ToolAvailability(
            webSearch: names.contains("noema.web.retrieve"),
            python: names.contains("noema.python.execute"),
            memory: names.contains("noema.memory"),
            calculator: names.contains("noema.math.calculate"),
            unitConverter: names.contains("noema.units.convert"),
            // Derive on-device tools from the spec list a remote backend is actually offered,
            // so the remote-session prompt override (and the meter's guidanceDelta) surfaces the
            // same guidance. The single `calendar` field maps to either calendar tool.
            datasetSearch: names.contains("noema.rag.search"),
            pdfRead: pdfReadFromSpecs,
            chartRender: names.contains("noema.chart.render"),
            calendar: names.contains("noema.calendar.events") || names.contains("noema.calendar.addEvent")
        )
    }

    nonisolated func unload(reason: String = "explicit") async {
        let before = LiveMemoryPressureSnapshot.current()
        // Capture the current client so we can await a full teardown off the main actor.
        let captured = await MainActor.run { () -> (client: AnyLLMClient?, model: String, format: String) in
            let model = self.loadedURL?.lastPathComponent ?? self.modelManager?.loadedModel?.name ?? "none"
            let format = self.loadedFormat?.rawValue ?? "none"
            return (self.detachClientAndUnloadResources(), model, format)
        }
        await logger.log("[ModelUnload] begin reason=\(reason) model=\(captured.model) format=\(captured.format) hadClient=\(captured.client != nil)")
        await Self.unloadDetachedClient(captured.client)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let after = LiveMemoryPressureSnapshot.current()
        let result = ModelUnloadVerifier.evaluate(before: before, after: after)
        await MainActor.run {
            self.lastUnloadVerification = result
        }
        Task {
            await logger.log("[ModelUnloadVerification] \(result.logSummary)")
        }
    }

    /// Memory/background policy must not race a send between an idle check and
    /// client detachment. Both happen in one MainActor transaction; teardown
    /// then continues off the UI actor.
    @discardableResult
    nonisolated func unloadIfIdle(reason: String = "idle-policy") async -> Bool {
        guard !Task.isCancelled else { return false }
        let before = LiveMemoryPressureSnapshot.current()
        let unloadGeneration = UUID()
        let captured = await MainActor.run {
            () -> (allowed: Bool, client: AnyLLMClient?, model: String, format: String, blocker: String) in
            guard !Task.isCancelled else {
                return (false, nil, "none", "none", "task-cancelled")
            }
            guard self.idleUnloadGeneration == nil else {
                return (false, nil, "none", "none", "unload-in-progress")
            }
            guard !self.isStreaming,
                  !self.sendInFlight,
                  self.autoRoutingStage != .deciding else {
                var blockers: [String] = []
                if self.isStreaming { blockers.append("streaming") }
                if self.sendInFlight { blockers.append("send-in-flight") }
                if self.autoRoutingStage == .deciding { blockers.append("routing") }
                return (false, nil, "none", "none", blockers.joined(separator: "+"))
            }
            guard self.client != nil || self.modelLoaded || self.loadedURL != nil else {
                return (false, nil, "none", "none", "no-resident-client")
            }
            self.idleUnloadGeneration = unloadGeneration
            let model = self.loadedURL?.lastPathComponent ?? self.modelManager?.loadedModel?.name ?? "unknown"
            let format = self.loadedFormat?.rawValue ?? "unknown"
            return (true, self.detachClientAndUnloadResources(), model, format, "")
        }
        guard captured.allowed else {
            await logger.log("[ModelUnload] skipped reason=\(reason) blocker=\(captured.blocker)")
            return false
        }

        await logger.log("[ModelUnload] begin reason=\(reason) model=\(captured.model) format=\(captured.format) hadClient=\(captured.client != nil)")
        await Self.unloadDetachedClient(captured.client)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let after = LiveMemoryPressureSnapshot.current()
        let result = ModelUnloadVerifier.evaluate(before: before, after: after)
        await MainActor.run {
            self.lastUnloadVerification = result
            if self.idleUnloadGeneration == unloadGeneration {
                self.idleUnloadGeneration = nil
            }
        }
        Task {
            await logger.log("[ModelUnloadVerification] \(result.logSummary)")
        }
        return true
    }

}

extension ChatVM: FlashcardGeneratingViewModel {
    func makeFlashcardInput(system: String, user: String) -> LLMInput {
        let prompt = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if loadedFormat == .et {
            let combined = system.isEmpty ? prompt : system + "\n\n" + prompt
            return LLMInput(.messages([ChatMessage(role: "user", content: combined)]))
        }

        let history: [Msg] = [Msg(role: "🧑‍💻", text: prompt, timestamp: Date())]
        let rendered = prepareForGeneration(messages: history, system: system)
        switch rendered {
        case .messages(let messages):
            let chatMessages = messages.map { ChatMessage(role: $0.role, content: $0.content) }
            return LLMInput(.messages(chatMessages))
        case .plain(let text):
            return LLMInput(.plain(text))
        }
    }
}
#endif
