import SwiftUI

@_silgen_name("app_available_memory")
private func live_memory_available_bytes() -> UInt

@_silgen_name("app_memory_footprint")
private func live_memory_footprint_bytes() -> UInt

struct LiveMemoryPressureSnapshot: Equatable {
    let footprintBytes: Int64
    let availableBytes: Int64?
    let budgetBytes: Int64?
    let thermalState: ProcessInfo.ThermalState
    let sampledAt: Date

    static func current(info: DeviceRAMInfo = DeviceRAMInfo.current()) -> Self {
        let available = Int64(live_memory_available_bytes())
        return Self(
            footprintBytes: max(0, Int64(live_memory_footprint_bytes())),
            availableBytes: available > 0 ? available : nil,
            budgetBytes: info.conservativeLimitBytes(),
            thermalState: ProcessInfo.processInfo.thermalState,
            sampledAt: Date()
        )
    }

    var budgetProgress: Double {
        guard let budgetBytes, budgetBytes > 0 else { return 0 }
        return min(1, max(0, Double(footprintBytes) / Double(budgetBytes)))
    }

    var availableProgress: Double {
        guard let availableBytes, availableBytes > 0 else { return 0 }
        let total = Double(footprintBytes + availableBytes)
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(footprintBytes) / total))
    }

    var pressure: MemoryPressureLevel {
        if thermalState == .critical { return .critical }
        if thermalState == .serious { return .high }
        if let availableBytes {
            if availableBytes < 256 * 1024 * 1024 { return .critical }
            if availableBytes < 512 * 1024 * 1024 { return .high }
            if availableBytes < 1024 * 1024 * 1024 { return .elevated }
        }
        switch budgetProgress {
        case 0..<0.70:
            return .comfortable
        case 0.70..<0.88:
            return .elevated
        case 0.88..<0.98:
            return .high
        default:
            return .critical
        }
    }
}

enum MemoryPressureLevel {
    case comfortable
    case elevated
    case high
    case critical

    var title: LocalizedStringKey {
        switch self {
        case .comfortable: return "Comfortable"
        case .elevated: return "Elevated"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    var tint: Color {
        switch self {
        case .comfortable: return .green
        case .elevated: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }
}

struct LiveMemoryPressureMeter: View {
    let modelEstimateBytes: Int64?
    let modelAlreadyLoaded: Bool
    var sampleInterval: TimeInterval = 1.0

    @State private var snapshot = LiveMemoryPressureSnapshot.current()
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ring

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(snapshot.pressure.tint)
                            .frame(width: 9, height: 9)
                        Text(snapshot.pressure.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(snapshot.pressure.tint)
                    }

                    Text(memorySummary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let modelEstimateBytes {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(LocalizedStringKey("Selected Model Margin"))
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(verbatim: modelMarginText(estimateBytes: modelEstimateBytes))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(modelMarginColor(estimateBytes: modelEstimateBytes))
                    }

                    ProgressView(value: modelMarginProgress(estimateBytes: modelEstimateBytes))
                        .tint(modelMarginColor(estimateBytes: modelEstimateBytes))
                        .accessibilityLabel(LocalizedStringKey("Selected Model Margin"))
                }
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            refresh()
        }
#if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            refresh()
        }
#endif
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 10)
            Circle()
                .trim(from: 0, to: snapshot.budgetBytes == nil ? snapshot.availableProgress : snapshot.budgetProgress)
                .stroke(snapshot.pressure.tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(Int((snapshot.budgetBytes == nil ? snapshot.availableProgress : snapshot.budgetProgress) * 100))%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 64, height: 64)
        .accessibilityLabel(LocalizedStringKey("Memory Pressure"))
    }

    private var memorySummary: String {
        let footprint = memoryString(snapshot.footprintBytes)
        if let available = snapshot.availableBytes {
            return String.localizedStringWithFormat(
                String(localized: "%@ used, %@ available"),
                footprint,
                memoryString(available)
            )
        }
        if let budget = snapshot.budgetBytes {
            return String.localizedStringWithFormat(
                String(localized: "%@ of %@ budget"),
                footprint,
                memoryString(budget)
            )
        }
        return footprint
    }

    private func modelMarginText(estimateBytes: Int64) -> String {
        let remaining = modelMarginBytes(estimateBytes: estimateBytes)
        if remaining >= 0 {
            return String.localizedStringWithFormat(
                String(localized: "%@ headroom"),
                memoryString(remaining)
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "%@ over"),
            memoryString(abs(remaining))
        )
    }

    private func modelMarginBytes(estimateBytes: Int64) -> Int64 {
        let incrementalEstimate = modelAlreadyLoaded ? 0 : estimateBytes
        if let available = snapshot.availableBytes {
            return available - incrementalEstimate
        }
        if let budget = snapshot.budgetBytes {
            return budget - snapshot.footprintBytes - incrementalEstimate
        }
        return -incrementalEstimate
    }

    private func modelMarginProgress(estimateBytes: Int64) -> Double {
        guard let budget = snapshot.budgetBytes, budget > 0 else {
            return modelMarginBytes(estimateBytes: estimateBytes) >= 0 ? 1 : 0
        }
        let projected = snapshot.footprintBytes + (modelAlreadyLoaded ? 0 : estimateBytes)
        return min(1, max(0, Double(projected) / Double(budget)))
    }

    private func modelMarginColor(estimateBytes: Int64) -> Color {
        let margin = modelMarginBytes(estimateBytes: estimateBytes)
        if margin < 0 { return .red }
        if margin < 512 * 1024 * 1024 { return .orange }
        return .green
    }

    private func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { _ in
            Task { @MainActor in
                refresh()
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        withAnimation(.easeInOut(duration: 0.2)) {
            snapshot = LiveMemoryPressureSnapshot.current()
        }
    }

    private func memoryString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
