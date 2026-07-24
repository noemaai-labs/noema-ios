import Foundation
import NoemaPackages

@_silgen_name("app_memory_footprint")
private func c_app_memory_footprint() -> UInt

// Int raw values drive the canary progress sheet's step ordering.
enum OverfitCanaryPhase: Int, CaseIterable, Sendable {
    case validating
    case measuringStorage
    case loadingModel
    case generating
    case finished
}

enum OverfitCanaryError: LocalizedError {
    case launchRefused(String)
    case planNotPaged
    case serverStartFailed
    case serverNeverBecameReady
    case generationBusy
    case generationFailed(String)
    case noTokensProduced

    // Diagnostic strings; user-facing presentation is owned by the canary UI.
    var errorDescription: String? {
        switch self {
        case .launchRefused(let detail): return detail
        case .planNotPaged: return "canary requires a paged launch plan"
        case .serverStartFailed: return "canary server failed to start"
        case .serverNeverBecameReady: return "canary server never became ready"
        case .generationBusy: return "another generation owns the loopback bridge"
        case .generationFailed(let detail): return "canary generation failed: \(detail)"
        case .noTokensProduced: return "canary generation produced no tokens"
        }
    }
}

final class OverfitCanaryService {
    private init() {}

    /// Fixed English prompt: the canary measures the runtime, not the model,
    /// so every run on every device asks for exactly the same work.
    static let canaryPrompt = "List ten common uses for a public library, one per line, using plain short sentences."
    static let canaryContextSize: Int32 = 2048
    static let canaryPredictTokens = 64

    private static let readinessTimeout: TimeInterval = 300
    private static let readinessIntervalNanos: UInt64 = 200_000_000

    static func run(
        package: NoemaPagedPackage,
        modelURL: URL,
        settings: ModelSettings,
        progress: @escaping @Sendable (OverfitCanaryPhase) -> Void
    ) async throws -> OverfitCanaryRecord {
        progress(.validating)
        try package.validate(level: .spotCheck)

        progress(.measuringStorage)
        let expertsURL = package.directoryURL
            .appendingPathComponent(package.manifest.expertFiles[0].path)
        let storageSample = try OverfitStorageCalibrationStore.sampleAlignedReadDual(fileURL: expertsURL)
        let device = OverfitEnvironmentIdentity.deviceModelIdentifier
        let volume = OverfitEnvironmentIdentity.volumeIdentifier(for: expertsURL)
        OverfitStorageCalibrationStore.shared.save(OverfitStorageCalibrationRecord(
            deviceModelIdentifier: device,
            volumeIdentifier: volume,
            alignedReadMBps: storageSample.nocache.megabytesPerSecond,
            cachedReadMBps: storageSample.cached.megabytesPerSecond,
            sampleBytes: storageSample.nocache.bytesRead,
            sampledAt: Date()
        ))

        progress(.loadingModel)
        let (resolved, plan) = await MainActor.run {
            GGUFServerConfigurationResolver.resolveWithPlan(
                modelURL: modelURL,
                settings: settings,
                mmprojPath: nil,
                contextShiftEnabled: false,
                purpose: .canary
            )
        }
        switch plan {
        case .paged:
            break
        case .resident:
            throw OverfitCanaryError.planNotPaged
        case .refused(let reason):
            throw OverfitCanaryError.launchRefused(OverfitPlanResolver.refusalMessage(reason))
        }
        let configuration = canaryConfiguration(from: resolved)

        // Boot with the same env-decided F_NOCACHE state a real launch would
        // use, refreshed from the record just saved: the measured
        // classification then reflects the shipping I/O configuration, and a
        // stale env value from an earlier launch cannot leak into this run.
        OverfitStorageCalibrationStore.shared.applyNoCacheEnvironment(
            packageDirectory: package.directoryURL
        )

        guard let lease = await NoemaLlamaClient.startStandaloneLoopbackServer(
            with: configuration,
            visionEnabled: false
        ) else {
            throw OverfitCanaryError.serverStartFailed
        }

        let outcome: GenerationOutcome
        do {
            let ready = await LoopbackReadinessProbe.run(
                timeout: readinessTimeout,
                intervalNanos: readinessIntervalNanos,
                bridgeReady: {
                    LlamaServerBridge.port() == lease.port
                        && !LlamaServerBridge.isLoading()
                        && LlamaServerBridge.loadProgress() >= 1.0
                },
                healthStatus: { await healthStatus(port: lease.port) }
            )
            guard ready.ready else { throw OverfitCanaryError.serverNeverBecameReady }

            progress(.generating)
            outcome = try await generate(lease: lease)
        } catch {
            await NoemaLlamaClient.stopStandaloneLoopbackServer(ifOwned: lease)
            throw error
        }
        await NoemaLlamaClient.stopStandaloneLoopbackServer(ifOwned: lease)

        let latencySample = OverfitLatencyClassifier.summarize(
            interTokenLatenciesMs: outcome.interTokenLatenciesMs
        )
        let classification: OverfitFitClassification
        if let latencySample {
            classification = OverfitLatencyClassifier.classify(latencySample)
        } else if outcome.generationRate >= OverfitFitAdvisor.interactiveFloorTokensPerSecond {
            classification = .pagedInteractive
        } else if outcome.generationRate >= OverfitFitAdvisor.slowFloorTokensPerSecond {
            classification = .pagedSlow
        } else {
            classification = .offlineOnly
        }

        let record = OverfitCanaryRecord(
            packageFingerprint: package.manifest.fingerprint,
            deviceModelIdentifier: device,
            volumeIdentifier: volume,
            nativeContractVersion: OverfitEnvironmentIdentity.nativeContractVersion,
            appBuild: OverfitEnvironmentIdentity.appBuild,
            completedAt: Date(),
            storageAlignedReadMBps: storageSample.nocache.megabytesPerSecond,
            promptRate: outcome.promptRate,
            generationRate: outcome.generationRate,
            timeToFirstToken: outcome.timeToFirstToken,
            latency: latencySample,
            bankHitRate: outcome.bankHitRate,
            missesPerToken: outcome.missesPerToken,
            peakMemoryBytes: outcome.peakMemoryBytes,
            thermalStateRaw: ProcessInfo.processInfo.thermalState.rawValue,
            classification: classification
        )
        OverfitCanaryStore.shared.save(record)
        progress(.finished)
        return record
    }

    /// The plan's paged configuration, tightened to canary scale: a small
    /// fixed context and no context shift keep the measurement short and
    /// identical across runs.
    private static func canaryConfiguration(
        from resolved: LlamaServerBridge.StartConfiguration
    ) -> LlamaServerBridge.StartConfiguration {
        LlamaServerBridge.StartConfiguration(
            host: resolved.host,
            preferredPort: resolved.preferredPort,
            ggufPath: resolved.ggufPath,
            mmprojPath: nil,
            mtpPath: nil,
            chatTemplateFile: resolved.chatTemplateFile,
            reasoningBudget: resolved.reasoningBudget,
            contextSize: min(resolved.contextSize, canaryContextSize),
            contextShift: false,
            gpuLayers: resolved.gpuLayers,
            threads: resolved.threads,
            threadsBatch: resolved.threadsBatch,
            batchSize: resolved.batchSize,
            ubatchSize: resolved.ubatchSize,
            useMmap: resolved.useMmap,
            useMlock: resolved.useMlock,
            warmup: false,
            kvOffload: resolved.kvOffload,
            unifiedKVCache: resolved.unifiedKVCache,
            flashAttention: resolved.flashAttention,
            cacheTypeK: resolved.cacheTypeK,
            cacheTypeV: resolved.cacheTypeV,
            parallelSlots: 1,
            tensorOverride: resolved.tensorOverride,
            cpuMoE: resolved.cpuMoE,
            moeExpertCount: resolved.moeExpertCount,
            yarnScale: resolved.yarnScale,
            yarnOriginalContext: resolved.yarnOriginalContext,
            yarnBetaFast: resolved.yarnBetaFast,
            yarnBetaSlow: resolved.yarnBetaSlow,
            cacheRamMiB: 0,
            ctxCheckpoints: 0,
            speculativeType: nil,
            specDraftNMax: nil,
            specDraftNMin: nil,
            specDraftPMin: nil,
            specDynamic: false,
            useJinja: resolved.useJinja,
            pagedMode: resolved.pagedMode,
            pagedManifestPath: resolved.pagedManifestPath,
            pagedSlotsPerLayer: resolved.pagedSlotsPerLayer,
            pagedBankBudgetMiB: resolved.pagedBankBudgetMiB,
            pagedIOThreads: resolved.pagedIOThreads,
            pagedIODepth: resolved.pagedIODepth,
            pagedIOTimeoutMs: resolved.pagedIOTimeoutMs,
            pagedPrefetch: resolved.pagedPrefetch,
            pagedOracleAllHit: resolved.pagedOracleAllHit,
            pagedTrace: resolved.pagedTrace,
            pagedTracePath: resolved.pagedTracePath,
            pagedVerifyChecksums: resolved.pagedVerifyChecksums,
            pagedTelemetryIntervalMs: resolved.pagedTelemetryIntervalMs,
            pagedWaves: resolved.pagedWaves,
            pagedExpertMajor: resolved.pagedExpertMajor
        )
    }

    // MARK: - Generation

    private struct GenerationOutcome {
        let promptRate: Double
        let generationRate: Double
        let timeToFirstToken: TimeInterval
        let interTokenLatenciesMs: [Double]
        let bankHitRate: Double
        let missesPerToken: Double
        let peakMemoryBytes: Int64
    }

    private struct CanaryChunk: Decodable {
        let content: String?
        let stop: Bool?
        let timings: LoopbackSpeculativeTimings?
    }

    private static func generate(
        lease: NoemaLlamaClient.StandaloneLoopbackLease
    ) async throws -> GenerationOutcome {
        guard let reservation = NoemaLlamaClient.reserveStandaloneLoopbackGeneration(for: lease) else {
            throw OverfitCanaryError.generationBusy
        }
        defer { reservation.release() }

        // The grammar constrains output to printable ASCII: this fork
        // chat-parses even /completion output, and synthetic fixture models
        // can otherwise emit bytes that trip that parser. It is harmless for
        // real models.
        let body: [String: Any] = [
            "prompt": canaryPrompt,
            "stream": true,
            "n_predict": canaryPredictTokens,
            "temperature": 0,
            "seed": 42,
            "cache_prompt": false,
            "grammar": "root ::= [ -~]*"
        ]
        guard let url = URL(string: "http://127.0.0.1:\(lease.port)/completion") else {
            throw OverfitCanaryError.generationFailed("invalid loopback URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 600

        let session = makeLoopbackSession()
        defer { session.finishTasksAndInvalidate() }

        let started = Date()
        var firstTokenDate: Date?
        var previousTokenDate: Date?
        var interTokenLatenciesMs: [Double] = []
        var tokenEvents = 0
        var finalTimings: LoopbackSpeculativeTimings?
        var peakFootprint = Int64(c_app_memory_footprint())

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OverfitCanaryError.generationFailed("HTTP \(http.statusCode)")
        }
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                guard payload != "[DONE]", let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(CanaryChunk.self, from: data) else {
                    continue
                }
                if chunk.content != nil {
                    let now = Date()
                    if firstTokenDate == nil {
                        firstTokenDate = now
                    } else if let previousTokenDate {
                        interTokenLatenciesMs.append(now.timeIntervalSince(previousTokenDate) * 1000)
                    }
                    previousTokenDate = now
                    tokenEvents += 1
                }
                if let timings = chunk.timings {
                    finalTimings = timings
                }
                peakFootprint = max(peakFootprint, Int64(c_app_memory_footprint()))
                if chunk.stop == true { break }
            }
        } catch {
            throw OverfitCanaryError.generationFailed(error.localizedDescription)
        }

        guard let firstTokenDate, tokenEvents > 0 else {
            throw OverfitCanaryError.noTokensProduced
        }
        let timeToFirstToken = firstTokenDate.timeIntervalSince(started)
        let generationDuration = (previousTokenDate ?? firstTokenDate).timeIntervalSince(firstTokenDate)
        let generationTokens = finalTimings?.predictedN.flatMap { $0 > 0 ? $0 : nil } ?? tokenEvents
        let generationRate = finalTimings?.predictedPerSecond.flatMap { $0 > 0 ? $0 : nil }
            ?? (generationDuration > 0 ? Double(generationTokens) / generationDuration : 0)
        let promptRate = finalTimings?.promptPerSecond.flatMap { $0 > 0 ? $0 : nil }
            ?? (timeToFirstToken > 0
                ? Double(finalTimings?.promptN ?? 0) / timeToFirstToken
                : 0)

        // Read paged telemetry before the server is torn down.
        var bankHitRate = 1.0
        var missesPerToken = 0.0
        if let statsJSON = LlamaServerBridge.pagedStatsJSON(),
           let stats = ModelBenchmarkService.pagedMetrics(
               fromStatsJSON: statsJSON,
               interTokenLatenciesMs: interTokenLatenciesMs,
               generationTokens: generationTokens,
               thermalStateRaw: ProcessInfo.processInfo.thermalState.rawValue
           ) {
            let lookups = stats.bankHits + stats.bankMisses
            bankHitRate = lookups > 0 ? Double(stats.bankHits) / Double(lookups) : 1.0
            missesPerToken = stats.missesPerToken
        }

        return GenerationOutcome(
            promptRate: promptRate,
            generationRate: generationRate,
            timeToFirstToken: timeToFirstToken,
            interTokenLatenciesMs: interTokenLatenciesMs,
            bankHitRate: bankHitRate,
            missesPerToken: missesPerToken,
            peakMemoryBytes: peakFootprint
        )
    }

    private static func healthStatus(port: Int32) async -> Int? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        let session = makeLoopbackSession()
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    private static func makeLoopbackSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [AnyHashable: Any]()
        let session = URLSession(configuration: configuration)
        NetworkKillSwitch.track(session: session)
        return session
    }
}
