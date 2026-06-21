import SwiftUI

struct ModelDeviceFitAssessment: Equatable {
    enum Source: Equatable {
        case benchmark
        case estimate
    }

    enum Status: Equatable {
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
    static func assess(
        format: ModelFormat,
        sizeBytes: Int64,
        contextLength: Int = 4096,
        layerCount: Int? = nil,
        moeInfo: MoEInfo? = nil,
        benchmark: ModelBenchmarkResult? = nil
    ) -> ModelDeviceFitAssessment {
        if let benchmark {
            return benchmarkAssessment(benchmark)
        }

        let (estimate, budget) = ModelRAMAdvisor.estimateAndBudget(
            format: format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo
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

struct ModelDeviceFitBadge: View {
    let assessment: ModelDeviceFitAssessment
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
                HStack {
                    Spacer()
                    Button(LocalizedStringKey("OK")) { showInfo = false }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(maxWidth: 360, alignment: .leading)
            .presentationDetents([.fraction(0.25)])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
        }
    }

    private var title: LocalizedStringKey {
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
