import NoemaPackages
import os
import SwiftUI

struct ModelDeviceFitAssessment: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case benchmark
        case estimate
    }

    enum Status: Equatable, Sendable {
        case works
        case tight
        case unlikely
    }

    let source: Source
    let status: Status
    let generationRate: Double?
    let timeToFirstToken: TimeInterval?
    let peakMemoryBytes: Int64?
    let estimatedBytes: Int64?
    let budgetBytes: Int64?
}

enum ModelDeviceFitAdvisor {
    /// `modelURL` opts the estimate into Noema Overfit awareness: when it
    /// points inside a `.noema-paged` install, the working set is judged by
    /// the paged runtime (resident + bank budget + staging), not by
    /// `sizeBytes` — which for paged installs is either the resident file
    /// alone or the multi-gigabyte package total, both dishonest.
    static func assess(
        format: ModelFormat,
        sizeBytes: Int64,
        contextLength: Int = 4096,
        layerCount: Int? = nil,
        moeInfo: MoEInfo? = nil,
        modelURL: URL? = nil,
        benchmark: ModelBenchmarkResult? = nil
    ) -> ModelDeviceFitAssessment {
        if let benchmark {
            return benchmarkAssessment(benchmark)
        }

        let runtimeConfiguration: ModelRAMAdvisor.RuntimeConfiguration = {
            guard format == .gguf, let modelURL,
                  ModelRAMAdvisor.pagedEstimateFigures(forModelPath: modelURL.path) != nil else {
                return .conservativeDefault
            }
            var configuration = ModelRAMAdvisor.RuntimeConfiguration.conservativeDefault
            configuration.modelPath = modelURL.path
            return configuration
        }()
        let (estimate, budget) = ModelRAMAdvisor.estimateAndBudget(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            runtimeConfiguration: runtimeConfiguration
        )
        let status: ModelDeviceFitAssessment.Status = {
            guard let budget, budget > 0 else { return .works }
            if estimate <= Int64(Double(budget) * 0.85) { return .works }
            if estimate <= budget { return .tight }
            return .unlikely
        }()

        return ModelDeviceFitAssessment(
            source: .estimate,
            status: status,
            generationRate: nil,
            timeToFirstToken: nil,
            peakMemoryBytes: nil,
            estimatedBytes: estimate,
            budgetBytes: budget
        )
    }

    private static func benchmarkAssessment(_ benchmark: ModelBenchmarkResult) -> ModelDeviceFitAssessment {
        let rate = benchmark.generationRate
        let latency = benchmark.timeToFirstToken
        let status: ModelDeviceFitAssessment.Status = {
            if rate >= 8, latency <= 8 { return .works }
            if rate >= 2, latency <= 15 { return .tight }
            return .unlikely
        }()

        return ModelDeviceFitAssessment(
            source: .benchmark,
            status: status,
            generationRate: rate,
            timeToFirstToken: latency,
            peakMemoryBytes: benchmark.peakMemoryBytes,
            estimatedBytes: nil,
            budgetBytes: nil
        )
    }
}

enum CuratedModelDeviceFit {
    enum Status: Equatable {
        case fits
        case tooLarge
        case unknown
    }

    /// Curated cards use a slightly smaller slice of the normal per-app budget
    /// so a model that only barely fits is not presented as a comfortable default.
    static let safetyMargin = 0.92

    static func status(
        for record: ModelRecord,
        format: ModelFormat? = nil,
        budgetBytes: Int64? = DeviceRAMInfo.current().conservativeLimitBytes()
    ) -> Status {
        guard record.hasInstallableQuant,
              let minimumRAM = record.minimumRAMBytes(for: format),
              minimumRAM > 0,
              let budgetBytes,
              budgetBytes > 0 else {
            return .unknown
        }

        return Double(minimumRAM) <= Double(budgetBytes) * safetyMargin
            ? .fits
            : .tooLarge
    }

    /// Unknown devices keep the catalog visible because hiding every model would
    /// be less useful than falling back to the existing unfiltered experience.
    static func shouldShowByDefault(
        _ record: ModelRecord,
        format: ModelFormat? = nil,
        budgetBytes: Int64? = DeviceRAMInfo.current().conservativeLimitBytes()
    ) -> Bool {
        switch status(for: record, format: format, budgetBytes: budgetBytes) {
        case .fits, .unknown:
            return true
        case .tooLarge:
            return false
        }
    }
}

/// Honest fit label for a paged install: the stored canary verdict for this
/// exact package + device + volume + contract + build, or nil when no canary
/// has run yet. Callers must render the neutral PAGED chip for nil — any
/// concrete classification would be a guess.
enum OverfitPagedFitCache {
    private struct PackageIdentity {
        let fingerprint: String
        let volume: String
    }

    /// Fingerprint + volume resolution loads the package manifest and stats
    /// the mount (disk I/O), so identities memoize per canonical path — same
    /// lifecycle argument as OverfitPagedInstallCache: a package only changes
    /// through a re-download (new URL) or an app restart. `nil` = the URL is
    /// not inside a readable paged package.
    private static let identities = OSAllocatedUnfairLock<[String: PackageIdentity?]>(initialState: [:])
    /// Found verdicts memoize; a missing record is re-queried each time (the
    /// canary store is UserDefaults-backed, no disk I/O) so a canary that
    /// finishes this session surfaces in list rows without a restart.
    private static let classifications = OSAllocatedUnfairLock<[String: OverfitFitClassification]>(initialState: [:])

    static func classification(forModelAt url: URL) -> OverfitFitClassification? {
        let key = url.standardizedFileURL.path
        if let cached = classifications.withLock({ $0[key] }) {
            return cached
        }
        guard let identity = identity(forKey: key, modelURL: url) else { return nil }
        guard let record = OverfitCanaryStore.shared.record(
            fingerprint: identity.fingerprint,
            device: OverfitEnvironmentIdentity.deviceModelIdentifier,
            volume: identity.volume,
            contractVersion: OverfitEnvironmentIdentity.nativeContractVersion,
            appBuild: OverfitEnvironmentIdentity.appBuild
        ) else {
            return nil
        }
        classifications.withLock { $0[key] = record.classification }
        return record.classification
    }

    static func invalidate() {
        identities.withLock { $0.removeAll() }
        classifications.withLock { $0.removeAll() }
    }

    private static func identity(forKey key: String, modelURL: URL) -> PackageIdentity? {
        if let cached = identities.withLock({ $0[key] }) {
            return cached
        }
        let resolved: PackageIdentity? = {
            guard let package = PagedPackageLocator.enclosingPackage(for: modelURL),
                  let loaded = try? NoemaPagedPackage.load(at: package) else {
                return nil
            }
            return PackageIdentity(
                fingerprint: loaded.manifest.fingerprint,
                volume: OverfitEnvironmentIdentity.volumeIdentifier(for: package)
            )
        }()
        identities.withLock { $0[key] = resolved }
        return resolved
    }
}

struct ModelDeviceFitBadge: View {
    let assessment: ModelDeviceFitAssessment
    /// Overfit paged-install classification. When set (and not resident), the
    /// badge label/palette speaks for the paged plan; the popover detail keeps
    /// the underlying memory/benchmark numbers.
    var pagedClassification: OverfitFitClassification? = nil
    @State private var showInfo = false
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: { showInfo = true }) {
            Label(title, systemImage: symbol)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(color.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey("Works on this device"))
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(color)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
#if !os(macOS)
                HStack {
                    Spacer()
                    Button(LocalizedStringKey("OK")) { showInfo = false }
                        .buttonStyle(.borderedProminent)
                }
#endif
            }
            .padding(16)
            .frame(maxWidth: 360, alignment: .leading)
#if !os(macOS)
            .presentationDetents([.fraction(0.25)])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
#endif
        }
    }

    /// Label/tint/symbol override for paged installs. `.residentInteractive`
    /// intentionally returns nil — the model runs fully resident, so the
    /// existing assessment labels remain the honest description.
    private var pagedBadge: (title: LocalizedStringKey, color: Color, symbol: String)? {
        guard let pagedClassification else { return nil }
        switch pagedClassification {
        case .residentInteractive:
            return nil
        case .pagedInteractive:
            return ("Paged — interactive", .green, "checkmark.circle.fill")
        case .pagedSlow:
            return ("Paged — slow", .orange, "gauge.with.dots.needle.33percent")
        case .offlineOnly:
            return ("Too slow on this device", .red, "exclamationmark.triangle.fill")
        case .relayRecommended:
            return ("Relay recommended", .teal, "antenna.radiowaves.left.and.right")
        case .unsupported:
            return ("Not supported for this model", .gray, "xmark.circle")
        }
    }

    private var title: LocalizedStringKey {
        if let pagedBadge { return pagedBadge.title }
        switch (assessment.source, assessment.status) {
        case (.benchmark, .works):
            return "Works here"
        case (.benchmark, .tight):
            return "Measured tight"
        case (.benchmark, .unlikely):
            return "Measured slow"
        case (.estimate, .works):
            return "Likely works"
        case (.estimate, .tight):
            return "Tight fit"
        case (.estimate, .unlikely):
            return "May not fit"
        }
    }

    private var accessibilityLabel: LocalizedStringKey {
        if let pagedBadge { return pagedBadge.title }
        switch assessment.status {
        case .works:
            return "Model works on this device"
        case .tight:
            return "Model may be tight on this device"
        case .unlikely:
            return "Model may not work well on this device"
        }
    }

    private var symbol: String {
        if let pagedBadge { return pagedBadge.symbol }
        switch assessment.status {
        case .works:
            return "checkmark.circle.fill"
        case .tight:
            return "gauge.with.dots.needle.33percent"
        case .unlikely:
            return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        if let pagedBadge { return pagedBadge.color }
        switch assessment.status {
        case .works:
            return .green
        case .tight:
            return .orange
        case .unlikely:
            return .red
        }
    }

    private var detailText: String {
        switch assessment.source {
        case .benchmark:
            let speed = String.localizedStringWithFormat(
                String(localized: "%.1f tok/s generation", locale: locale),
                assessment.generationRate ?? 0
            )
            let first = String.localizedStringWithFormat(
                String(localized: "%.2fs first token", locale: locale),
                assessment.timeToFirstToken ?? 0
            )
            let memory = assessment.peakMemoryBytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory)
            } ?? String(localized: "Unknown", locale: locale)
            return String.localizedStringWithFormat(
                String(localized: "Benchmarked on this device: %@ · %@ · %@ peak memory.", locale: locale),
                speed,
                first,
                memory
            )
        case .estimate:
            let estimate = assessment.estimatedBytes.map { localizedMemoryString($0) } ?? "--"
            let budget = assessment.budgetBytes.map { localizedMemoryString($0) } ?? "--"
            return String.localizedStringWithFormat(
                String(localized: "Estimated for this device: %@ working set against %@ memory budget.", locale: locale),
                estimate,
                budget
            )
        }
    }

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
}
