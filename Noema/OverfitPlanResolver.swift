import Foundation
import NoemaPackages

enum OverfitRefusalReason: Equatable {
    /// The install is a paged package but the per-model Overfit mode is off.
    case modeOff
    /// The package failed validation or names an unsupported architecture.
    case packageInvalid(String)
    /// The launch context cannot host paged execution (utility loads such as
    /// the standalone VLM path in v1).
    case unsupportedPurpose
}

struct PagedLaunchParameters: Equatable {
    let packageDirectory: URL
    let manifestPath: String
    let mode: LlamaServerBridge.PagedMode
    let contextCap: Int32
    let trace: Bool
    /// Streamed-bank cache budget; the native side derives slots per layer
    /// from it and fails closed below the K+2 floor.
    let bankBudgetMiB: Int32
    let prefetch: Bool
}

/// The launch-derived values the catalog can know before a package exists on
/// disk. Keeping this next to the resolver prevents Explore from growing a
/// subtly different phone/tablet/Mac bank policy.
struct PagedRemoteEstimateParameters: Equatable, Sendable {
    let contextCap: Int
    let bankBudgetBytes: Int64
}

enum OverfitLaunchPurpose {
    case chat
    case relay
    case utility
    case canary
}

enum OverfitPlan: Equatable {
    case resident
    case paged(PagedLaunchParameters)
    case refused(OverfitRefusalReason)

    var isPaged: Bool {
        if case .paged = self { return true }
        return false
    }
}

enum OverfitPlanResolver {
    /// Conservative context ceiling for paged launches. Mac keeps the Stage 1
    /// value; phone/tablet-class devices halve it because paged KV shares a
    /// per-process allocation limit that is far below physical RAM.
#if os(macOS) || targetEnvironment(macCatalyst)
    private static let stage1ContextCap: Int32 = 8192
    /// Bank budget on Mac: half of physical RAM, clamped [2 GiB, 32 GiB].
    /// Bigger banks raise the prefill micro-batch clamp and decode hit rates;
    /// the honest estimator and the memory governor bound the risk.
    private static let bankBudgetFloorMiB: Int64 = 2048
    private static let bankBudgetCeilingMiB: Int64 = 32_768
    /// Exact sizing already includes the runtime transient reserve. Keep an
    /// additional margin for app/UI allocations that may arrive after model
    /// planning but before or during generation.
    static let adaptivePagedBankReserveMiB: Int64 = 1024
    /// Deep I/O on Mac NVMe: 4 workers × 12 staging buffers approaches the
    /// drive's native queue depth; native clamps are [1,4] / [1,16].
    static let pagedIOThreads: Int32 = 4
    static let pagedIODepth: Int32 = 12
    static let preferredPagedWaveUbatch: Int32 = 1024
    static let conservativePagedWaveUbatch: Int32 = 512
    /// Context checkpoints for streamed paged launches. Hybrid/recurrent
    /// architectures (qwen35moe's gated-delta-net layers) cannot roll a
    /// sequence back partially, so plain slot prefix reuse never fires —
    /// without checkpoints every follow-up turn re-prefills the whole
    /// transcript (measured: 45.8 s turn-2 TTFT at 0.976 prefix similarity).
    /// Each checkpoint snapshots the non-rollback-able state per slot, which
    /// on 100B-class models can run tens to hundreds of MB — hence a small
    /// count, smaller still under jetsam.
    static let pagedCtxCheckpoints: Int32 = 8
#else
    private static let stage1ContextCap: Int32 = 4096
    /// Bank budget on iOS/visionOS: a third of the *live allocatable headroom*
    /// (not physical RAM — jetsam caps the process well below it), clamped
    /// [1 GiB, 8 GiB]. The floor keeps the native K+2 slot minimum reachable
    /// on 4 GB phones; the ceiling bounds even 16 GB iPads and bogus readings.
    private static let bankBudgetFloorMiB: Int64 = 1024
    private static let bankBudgetCeilingMiB: Int64 = 8192
    /// Extra post-sizing jetsam margin. On the measured iPhone 17 Pro launch,
    /// this still converts roughly 900 MiB of otherwise idle headroom into ten
    /// additional Gemma expert slots per layer.
    static let adaptivePagedBankReserveMiB: Int64 = 384
    /// Four workers keep modern iPhone/iPad NVMe busy while a depth of eight
    /// bounds the staging pool below the Mac 4 × 12 shape. Native exact
    /// sizing charges both staging buffers and per-worker coalescing scratch.
    static let pagedIOThreads: Int32 = 4
    static let pagedIODepth: Int32 = 8
    /// Settings previews and canaries use 512. A committed launch tries 1024
    /// first and falls back through exact-sized candidates; if sizing itself
    /// is unavailable, 256 is the fail-open phone ceiling.
    static let preferredPagedWaveUbatch: Int32 = 512
    static let conservativePagedWaveUbatch: Int32 = 256
    /// See the macOS note: fewer checkpoints on phones/tablets because each
    /// one is a full snapshot of the hybrid layers' non-rollback-able state.
    static let pagedCtxCheckpoints: Int32 = 4
#endif

    /// User-visible context ceiling for every paged launch on this platform.
    /// Settings normalization reads this same value so the UI cannot persist a
    /// context that the launch path would silently clamp.
    static var pagedContextCapTokens: Int {
        max(1, Int(stage1ContextCap))
    }

    /// Initial wave graph used by synchronous configuration resolution. The
    /// committed load path subsequently tries the full descending candidate
    /// set against native no-allocation sizing and live process headroom.
    static func initialPagedWaveUbatch(requested: Int32, contextCap: Int32) -> Int32 {
        let cap = max(1, contextCap)
        return min(cap, max(min(2, cap), max(requested, preferredPagedWaveUbatch)))
    }

    /// Largest-TTFT-win-first candidate order. Every step halves the compute
    /// graph while preserving multi-token wave execution.
    static func pagedWaveUbatchCandidates(contextCap: Int32) -> [Int32] {
        let cap = max(1, contextCap)
        if cap == 1 { return [1] }
        var candidates: [Int32] = []
        for value: Int32 in [1024, 512, 256, 128, 64, 32, 16, 8, 4, 2] {
            let bounded = min(value, cap)
            if bounded >= 2, !candidates.contains(bounded) {
                candidates.append(bounded)
            }
        }
        return candidates.sorted(by: >)
    }

    /// Grows a baseline bank only from headroom proven by the exact native
    /// no-allocation estimate. The estimate's own transient reserve remains
    /// charged; this helper additionally leaves `adaptivePagedBankReserveMiB`
    /// unused for asynchronous app allocations and estimator drift.
    static func expandedPagedBankBudgetMiB(currentMiB: Int32,
                                            requiredBytes: Int64?,
                                            availableBytes: Int64?) -> Int32 {
        let current = max(0, Int64(currentMiB))
        guard let requiredBytes, requiredBytes > 0,
              let availableBytes, availableBytes > requiredBytes else {
            return Int32(clamping: current)
        }
        let mib: Int64 = 1_048_576
        let reserveBytes = adaptivePagedBankReserveMiB * mib
        let provenGrowthBytes = availableBytes - requiredBytes - reserveBytes
        guard provenGrowthBytes >= mib else {
            return Int32(clamping: current)
        }
        let grown = current + provenGrowthBytes / mib
        return Int32(clamping: min(grown, bankBudgetCeilingMiB))
    }

    static var adaptivePagedBankReserveBytes: Int64 {
        adaptivePagedBankReserveMiB * 1_048_576
    }

    static func plan(modelURL: URL,
                     settings: ModelSettings,
                     purpose: OverfitLaunchPurpose) -> OverfitPlan {
        guard let packageDirectory = PagedPackageLocator.enclosingPackage(for: modelURL) else {
            return .resident
        }
        guard settings.overfitMode != .off else {
            return .refused(.modeOff)
        }
        guard purpose != .utility else {
            return .refused(.unsupportedPurpose)
        }
        do {
            let package = try NoemaPagedPackage.load(at: packageDirectory)
            guard package.isArchitectureSupported else {
                return .refused(.packageInvalid(
                    "architecture '\(package.manifest.model.architecture)' is not supported by Overfit"))
            }
            PagedPackageLocator.excludeFromBackupIfNeeded(packageDirectory)
            let bankBudgetMiB = resolvedBankBudgetMiB(
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                availableHeadroomBytes: currentAvailableHeadroomBytes(),
                totalExpertBytes: totalExpertBytes(of: package.manifest))
            return .paged(PagedLaunchParameters(
                packageDirectory: packageDirectory,
                manifestPath: package.manifestURL.path,
                mode: .streamed,
                contextCap: stage1ContextCap,
                trace: purpose == .canary,
                bankBudgetMiB: bankBudgetMiB,
                // Prefetch trades battery for latency; Low Power Mode is an
                // explicit request to make the opposite trade.
                prefetch: !ProcessInfo.processInfo.isLowPowerModeEnabled))
        } catch {
            return .refused(.packageInvalid(error.localizedDescription))
        }
    }

    /// Bank-budget policy, kept pure so tests can pin the platform bounds.
    /// Mac budgets from physical RAM; iOS/visionOS budget from live headroom.
    /// Either way the result never exceeds the package's total expert payload:
    /// once every expert fits, extra bank cache is unusable by construction.
    static func resolvedBankBudgetMiB(physicalMemoryBytes: UInt64,
                                      availableHeadroomBytes: Int64,
                                      totalExpertBytes: Int64) -> Int32 {
        let mib: Int64 = 1024 * 1024
#if os(macOS) || targetEnvironment(macCatalyst)
        let sourceMiB = Int64(clamping: physicalMemoryBytes / UInt64(mib)) / 2
#else
        let sourceMiB = max(0, availableHeadroomBytes) / mib / 3
#endif
        var budgetMiB = min(max(sourceMiB, bankBudgetFloorMiB), bankBudgetCeilingMiB)
        if totalExpertBytes > 0 {
            let expertCapMiB = totalExpertBytes / mib + (totalExpertBytes % mib == 0 ? 0 : 1)
            budgetMiB = min(budgetMiB, max(1, expertCapMiB))
        }
        return Int32(clamping: budgetMiB)
    }

    static func remoteEstimateParameters(
        for manifest: NoemaPagedPackageManifest,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        availableHeadroomBytes: Int64? = nil
    ) -> PagedRemoteEstimateParameters {
        let budgetMiB = resolvedBankBudgetMiB(
            physicalMemoryBytes: physicalMemoryBytes,
            availableHeadroomBytes: availableHeadroomBytes ?? currentAvailableHeadroomBytes(),
            totalExpertBytes: totalExpertBytes(of: manifest)
        )
        return PagedRemoteEstimateParameters(
            contextCap: max(1, Int(stage1ContextCap)),
            bankBudgetBytes: Int64(budgetMiB) * 1_048_576
        )
    }

    /// Sum of the streamed expert payload, saturating rather than trapping on
    /// a hostile manifest.
    private static func totalExpertBytes(of manifest: NoemaPagedPackageManifest) -> Int64 {
        manifest.expertFiles.reduce(Int64(0)) { total, file in
            let size = Int64(clamping: file.sizeBytes)
            return total > Int64.max - size ? Int64.max : total + size
        }
    }

    /// Bytes this process can still allocate before hitting its limit.
    /// `currentMemoryBudgetSnapshot` reports the *total* process allocation
    /// limit (live limit = os_proc_available_memory + footprint when the OS
    /// reading is present, device-table budget otherwise), so subtracting the
    /// current footprint converts either flavor back into headroom.
    private static func currentAvailableHeadroomBytes() -> Int64 {
#if os(macOS) || targetEnvironment(macCatalyst)
        return 0 // Unused: the Mac budget derives from physical RAM.
#else
        guard let limitBytes = ModelRAMAdvisor.currentMemoryBudgetSnapshot().bytes,
              limitBytes > 0 else { return 0 }
        return max(0, limitBytes - max(0, ModelRAMAdvisor.processFootprintBytes()))
#endif
    }

    /// Localized user-facing message for a refused launch.
    static func refusalMessage(_ reason: OverfitRefusalReason) -> String {
        switch reason {
        case .modeOff:
            return String(localized: "This model is a paged package and requires Overfit to run.",
                          locale: LocalizationManager.preferredLocale())
        case .unsupportedPurpose:
            return String(localized: "Paged models cannot be used for this task yet.",
                          locale: LocalizationManager.preferredLocale())
        case .packageInvalid(let detail):
            let base = String(localized: "Paged package failed verification. Re-download the model.",
                              locale: LocalizationManager.preferredLocale())
            return "\(base) (\(detail))"
        }
    }
}
