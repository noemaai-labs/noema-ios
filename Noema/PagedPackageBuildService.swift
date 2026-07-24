#if os(macOS)

import Foundation
import NoemaPackages

/// UI-facing phases of a package build. The native converter reports finer
/// stages ("resident"/"experts" both surface as `.extracting`).
enum PagedPackageBuildPhase: Int, CaseIterable, Sendable {
    case preparing
    case extracting
    case verifying
    case finishing
    case finished
}

enum PagedPackageBuildService {
    /// "<model-stem>.noema-paged" next to the source GGUF.
    static func destinationURL(forSourceGGUF url: URL) -> URL {
        url.deletingPathExtension()
            .appendingPathExtension(NoemaPagedPackageManifest.packageDirectoryExtension)
    }

    /// The Stored context menu offers a build only for downloaded GGUF MoE
    /// models with a whitelisted architecture that are not themselves a paged
    /// install already.
    static func canCreatePackage(for model: LocalModel) -> Bool {
        guard model.format == .gguf, model.isDownloaded else { return false }
        guard let moeInfo = model.moeInfo, moeInfo.isMoE else { return false }
        // Older installed records can have complete MoE geometry without the
        // architecture field that was added later. `architectureFamily` is
        // independently refreshed from the GGUF header whenever LocalModel is
        // rebuilt, so use it as the live fallback for the context-menu gate.
        let architectureIsSupported = [moeInfo.architecture, model.architectureFamily]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? nil : normalized
            }
            .contains { NoemaPagedPackage.supportedArchitectures.contains($0) }
        guard architectureIsSupported else {
            return false
        }
        return !OverfitPagedInstallCache.isPaged(model.url)
    }

    /// Creates the Stored record for a package derived from an already
    /// installed GGUF. The package stays beside its source, avoiding a second
    /// multi-gigabyte copy, while the distinct quant label lets both versions
    /// coexist and be deleted independently.
    static func installedModel(
        for package: NoemaPagedPackage,
        sourceModel: LocalModel,
        installDate: Date = Date()
    ) -> InstalledModel {
        let sourceQuant = sourceModel.quant.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantLabel = sourceQuant.isEmpty ? "Paged" : "\(sourceQuant) · Paged"
        let packageBytes = Int64(clamping: package.totalSizeBytes)

        return InstalledModel(
            modelID: sourceModel.modelID,
            quantLabel: quantLabel,
            parameterCountLabel: sourceModel.parameterCountLabel,
            url: package.residentGGUFURL,
            format: .gguf,
            sizeBytes: packageBytes,
            lastUsed: nil,
            installDate: installDate,
            checksum: nil,
            isFavourite: false,
            totalLayers: sourceModel.totalLayers,
            isMultimodal: sourceModel.isMultimodal,
            isToolCapable: sourceModel.isToolCapable,
            moeInfo: sourceModel.moeInfo,
            pagedPackageFingerprint: package.manifest.fingerprint,
            pagedPackageBytes: packageBytes
        )
    }

    /// Native stage → UI phase de-duplication so the main actor only hears
    /// phase transitions, not every progress tick.
    private final class PhaseRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var last: PagedPackageBuildPhase?
        private let onPhase: @Sendable (PagedPackageBuildPhase) -> Void

        init(_ onPhase: @escaping @Sendable (PagedPackageBuildPhase) -> Void) {
            self.onPhase = onPhase
        }

        func post(_ phase: PagedPackageBuildPhase) {
            lock.lock()
            let changed = last != phase
            last = phase
            lock.unlock()
            if changed {
                onPhase(phase)
            }
        }
    }

    private static func phase(forNativeStage stage: String) -> PagedPackageBuildPhase {
        switch stage {
        case "resident", "experts": return .extracting
        case "verifying": return .verifying
        case "finishing": return .finishing
        default: return .preparing
        }
    }

    /// Converts `sourceGGUF` into a sibling `.noema-paged` package and returns
    /// the loaded, structurally validated package. Throws
    /// `LlamaServerBridge.PagedConvertError` on native refusal/failure and
    /// `CancellationError` when the surrounding task is cancelled.
    @discardableResult
    static func build(
        sourceGGUF: URL,
        onPhase: @escaping @Sendable (PagedPackageBuildPhase) -> Void
    ) async throws -> NoemaPagedPackage {
        let destination = destinationURL(forSourceGGUF: sourceGGUF)
        let relay = PhaseRelay(onPhase)
        return try await withThrowingTaskGroup(of: NoemaPagedPackage.self) { group in
            group.addTask {
                relay.post(.preparing)
                try LlamaServerBridge.pagedConvert(
                    sourceGGUF: sourceGGUF,
                    destinationDirectory: destination
                ) { _, stage in
                    relay.post(Self.phase(forNativeStage: stage))
                }
                // Multi-gigabyte expert sidecars must never ride along in
                // device backups. The post-build UI handles registration.
                PagedPackageLocator.excludeFromBackupIfNeeded(destination)
                let package = try NoemaPagedPackage.load(at: destination)
                relay.post(.finished)
                return package
            }
            guard let package = try await group.next() else {
                throw CancellationError()
            }
            return package
        }
    }
}

#endif
