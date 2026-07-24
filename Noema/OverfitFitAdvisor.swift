import Foundation
import NoemaPackages

/// Remote manifests are the one trustworthy way to estimate a paged package
/// before download: Hub file totals describe disk use, while the manifest's
/// resident/expert split describes the launch working set.
actor OverfitRemoteManifestStore {
    static let shared = OverfitRemoteManifestStore()

    enum LoadError: LocalizedError {
        case oversized
        case unsupportedVersion(Int)
        case invalidGeometry

        var errorDescription: String? {
            switch self {
            case .oversized:
                return "The paged manifest is too large."
            case .unsupportedVersion(let version):
                return "Unsupported paged manifest version \(version)."
            case .invalidGeometry:
                return "The paged manifest has invalid model geometry."
            }
        }
    }

    private var cache: [URL: NoemaPagedPackageManifest] = [:]
    private static let maximumManifestBytes = 256 * 1024 * 1024

    func manifest(at url: URL, token: String?) async throws -> NoemaPagedPackageManifest {
        if let cached = cache[url] { return cached }
        guard !NetworkKillSwitch.isEnabled else { throw URLError(.notConnectedToInternet) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        NetworkKillSwitch.track(session: URLSession.shared)
        let (data, response) = try await URLSession.shared.data(for: HFEndpoint.rewrite(request))
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard data.count <= Self.maximumManifestBytes else { throw LoadError.oversized }
        let manifest = try JSONDecoder().decode(NoemaPagedPackageManifest.self, from: data)
        guard manifest.formatVersion == NoemaPagedPackageManifest.currentFormatVersion else {
            throw LoadError.unsupportedVersion(manifest.formatVersion)
        }
        guard manifest.resident.sizeBytes > 0,
              !manifest.expertFiles.isEmpty,
              manifest.model.expertCount > 0,
              manifest.model.expertsUsedDefault > 0,
              manifest.model.expertsUsedDefault <= manifest.model.expertCount,
              manifest.model.moeLayerCount > 0,
              manifest.model.totalLayerCount >= manifest.model.moeLayerCount else {
            throw LoadError.invalidGeometry
        }
        cache[url] = manifest
        return manifest
    }
}

struct OverfitRemotePackageEstimate: Equatable, Sendable {
    let status: ModelDeviceFitAssessment.Status
    let architectureSupported: Bool
    let packageStorageBytes: Int64
    let residentBytes: Int64
    let expertBankBytes: Int64
    let stagingBytes: Int64
    let workingSetBytes: Int64
    let budgetBytes: Int64?
    let contextCapTokens: Int
}

enum OverfitRemotePackageAdvisor {
    static func assess(
        manifest: NoemaPagedPackageManifest,
        manifestBytes: Int64 = 0,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        availableHeadroomBytes: Int64? = nil,
        budgetBytes: Int64? = ModelRAMAdvisor.currentMemoryBudgetSnapshot().bytes
    ) -> OverfitRemotePackageEstimate {
        let launch = OverfitPlanResolver.remoteEstimateParameters(
            for: manifest,
            physicalMemoryBytes: physicalMemoryBytes,
            availableHeadroomBytes: availableHeadroomBytes
        )
        let residentBytes = Int64(clamping: manifest.resident.sizeBytes)
        let stagingBytes = ModelRAMAdvisor.pagedStagingEstimateBytes
        let moeInfo = MoEInfo(
            isMoE: true,
            expertCount: Int(manifest.model.expertCount),
            defaultUsed: Int(manifest.model.expertsUsedDefault),
            moeLayerCount: Int(manifest.model.moeLayerCount),
            totalLayerCount: Int(manifest.model.totalLayerCount),
            hiddenSize: nil,
            feedForwardSize: nil,
            vocabSize: nil,
            architecture: manifest.model.architecture
        )
        let residentRuntime = ModelRAMAdvisor.estimateBreakdown(
            format: .gguf,
            sizeBytes: residentBytes,
            contextLength: launch.contextCap,
            layerCount: Int(manifest.model.totalLayerCount),
            moeInfo: moeInfo
        ).estimate
        let workingSet = saturatedSum([
            residentRuntime,
            launch.bankBudgetBytes,
            stagingBytes
        ])
        let architectureSupported = NoemaPagedPackage.supportedArchitectures
            .contains(manifest.model.architecture)
        let status: ModelDeviceFitAssessment.Status = {
            guard architectureSupported else { return .unlikely }
            guard let budgetBytes, budgetBytes > 0 else { return .works }
            if workingSet <= Int64(Double(budgetBytes) * 0.85) { return .works }
            if workingSet <= budgetBytes { return .tight }
            return .unlikely
        }()
        let expertBytes = manifest.expertFiles.reduce(Int64(0)) { total, entry in
            saturatedSum([total, Int64(clamping: entry.sizeBytes)])
        }
        let storageBytes = saturatedSum([
            residentBytes,
            expertBytes,
            max(0, manifestBytes)
        ])
        return OverfitRemotePackageEstimate(
            status: status,
            architectureSupported: architectureSupported,
            packageStorageBytes: storageBytes,
            residentBytes: residentBytes,
            expertBankBytes: launch.bankBudgetBytes,
            stagingBytes: stagingBytes,
            workingSetBytes: workingSet,
            budgetBytes: budgetBytes,
            contextCapTokens: launch.contextCap
        )
    }

    private static func saturatedSum(_ values: [Int64]) -> Int64 {
        values.reduce(Int64(0)) { total, value in
            let value = max(0, value)
            return total > Int64.max - value ? Int64.max : total + value
        }
    }
}

struct OverfitFitAssessment: Equatable, Sendable {
    let classification: OverfitFitClassification
    /// Storage-bound ceiling on decode speed; nil when no calibration exists.
    let predictedFloorTokensPerSecond: Double?
    let storageAlignedReadMBps: Double?
    let requiredResidentBytes: UInt64?
    let bankBytes: UInt64?
    let availableMemoryBytes: UInt64?
    /// Non-localized diagnostic detail for logs; UI strings come from the
    /// classification.
    let detail: String
}

enum OverfitFitAdvisor {
    struct Inputs {
        var package: NoemaPagedPackage
        var memoryEstimate: LlamaServerBridge.MemoryEstimate?
        var availableMemoryBytes: UInt64
        var storageAlignedReadMBps: Double?
        var canary: OverfitCanaryRecord?
        var mode: LlamaServerBridge.PagedMode
    }

    /// Interactive/slow floors mirror ModelDeviceFitAdvisor's measured
    /// thresholds (works >= 8 tok/s, tight >= 2 tok/s).
    static let interactiveFloorTokensPerSecond = 8.0
    static let slowFloorTokensPerSecond = 2.0
    /// Memory the paged plan must leave untouched on top of the estimate.
    static let safetyReserveBytes: UInt64 = 512 * 1024 * 1024

    static func assess(_ inputs: Inputs) -> OverfitFitAssessment {
        let manifest = inputs.package.manifest

        guard inputs.package.isArchitectureSupported else {
            return OverfitFitAssessment(
                classification: .unsupported,
                predictedFloorTokensPerSecond: nil,
                storageAlignedReadMBps: inputs.storageAlignedReadMBps,
                requiredResidentBytes: nil,
                bankBytes: nil,
                availableMemoryBytes: inputs.availableMemoryBytes,
                detail: "architecture \(manifest.model.architecture) not whitelisted")
        }

        // A valid canary is the strongest signal: measured latency wins over
        // every prediction.
        if let canary = inputs.canary {
            return OverfitFitAssessment(
                classification: canary.classification,
                predictedFloorTokensPerSecond: canary.generationRate,
                storageAlignedReadMBps: canary.storageAlignedReadMBps,
                requiredResidentBytes: inputs.memoryEstimate.map { $0.totalBytes + safetyReserveBytes },
                bankBytes: inputs.memoryEstimate?.paged?.bankBytes,
                availableMemoryBytes: inputs.availableMemoryBytes,
                detail: "measured by canary \(canary.completedAt)")
        }

        // Memory leg.
        var required: UInt64?
        if let estimate = inputs.memoryEstimate {
            required = estimate.totalBytes + (estimate.paged?.stagingBytes ?? 0) + safetyReserveBytes
            if required! > inputs.availableMemoryBytes {
                return OverfitFitAssessment(
                    classification: inputs.mode == .residentBank ? .relayRecommended : .offlineOnly,
                    predictedFloorTokensPerSecond: nil,
                    storageAlignedReadMBps: inputs.storageAlignedReadMBps,
                    requiredResidentBytes: required,
                    bankBytes: estimate.paged?.bankBytes,
                    availableMemoryBytes: inputs.availableMemoryBytes,
                    detail: "resident set exceeds available memory")
            }
        }

        // Storage leg (streamed mode only; the parity bank never misses).
        var floor: Double?
        if inputs.mode == .streamed {
            let bytesMissed = worstCaseBytesMissedPerToken(manifest: manifest)
            if let mbps = inputs.storageAlignedReadMBps, mbps > 0, bytesMissed > 0 {
                floor = (mbps * 1_000_000.0) / Double(bytesMissed)
            }
            guard let floor else {
                return OverfitFitAssessment(
                    classification: .pagedSlow,
                    predictedFloorTokensPerSecond: nil,
                    storageAlignedReadMBps: inputs.storageAlignedReadMBps,
                    requiredResidentBytes: required,
                    bankBytes: inputs.memoryEstimate?.paged?.bankBytes,
                    availableMemoryBytes: inputs.availableMemoryBytes,
                    detail: "no storage calibration; canary required")
            }
            let classification: OverfitFitClassification =
                floor >= interactiveFloorTokensPerSecond ? .pagedInteractive
                : floor >= slowFloorTokensPerSecond ? .pagedSlow
                : .offlineOnly
            return OverfitFitAssessment(
                classification: classification,
                predictedFloorTokensPerSecond: floor,
                storageAlignedReadMBps: inputs.storageAlignedReadMBps,
                requiredResidentBytes: required,
                bankBytes: inputs.memoryEstimate?.paged?.bankBytes,
                availableMemoryBytes: inputs.availableMemoryBytes,
                detail: "predicted from worst-case miss traffic")
        }

        return OverfitFitAssessment(
            classification: .pagedInteractive,
            predictedFloorTokensPerSecond: nil,
            storageAlignedReadMBps: inputs.storageAlignedReadMBps,
            requiredResidentBytes: required,
            bankBytes: inputs.memoryEstimate?.paged?.bankBytes,
            availableMemoryBytes: inputs.availableMemoryBytes,
            detail: "resident-bank mode; no storage dependence")
    }

    /// Worst case: every routed expert misses on every layer for one token.
    static func worstCaseBytesMissedPerToken(manifest: NoemaPagedPackageManifest) -> UInt64 {
        var perLayerFamilies: [UInt32: UInt64] = [:]
        var counted: Set<String> = []
        for record in manifest.records {
            let familyKey = "\(record.layer)/\(record.family.rawValue)"
            if counted.insert(familyKey).inserted {
                perLayerFamilies[record.layer, default: 0] += record.length
            }
        }
        let k = UInt64(manifest.model.expertsUsedDefault)
        return perLayerFamilies.values.reduce(0) { $0 + $1 * k }
    }
}
