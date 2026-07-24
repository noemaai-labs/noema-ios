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

#if os(macOS)
/// A deliberately low-frequency toolbar readout for Noema's current physical
/// footprint. Mach sampling is inexpensive, but the relaxed timer keeps it off
/// hot rendering and inference paths.
struct MacRAMUsageIndicator: View {
    private static let sampleInterval: TimeInterval = 3
    private static let physicalMemoryBytes = max(0, Int64(ProcessInfo.processInfo.physicalMemory))

    // Start sampling only once SwiftUI mounts the toolbar item. Keeping the
    // state initializer inert avoids Mach calls during ordinary view rebuilds.
    @State private var footprintBytes: Int64 = 0
    @State private var timer: Timer?

    private var progress: Double {
        guard Self.physicalMemoryBytes > 0 else { return 0 }
        return min(1, max(0, Double(footprintBytes) / Double(Self.physicalMemoryBytes)))
    }

    private var tint: Color {
        switch progress {
        case 0..<0.70: return ChatTheme.readyTint
        case 0.70..<0.88: return Color.yellow
        case 0.88..<0.96: return ChatTheme.busyTint
        default: return Color.red
        }
    }

    private var usedText: String {
        memoryString(footprintBytes)
    }

    private var totalText: String {
        memoryString(Self.physicalMemoryBytes)
    }

    private var accessibilitySummary: String {
        let usage = String.localizedStringWithFormat(
            String(localized: "%@ used, %@ available"),
            usedText,
            totalText
        )
        return "\(String(localized: "App Memory Usage (estimated)")): \(usage)"
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)

            Text(LocalizedStringKey("RAM"))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.3)
                .foregroundStyle(.secondary)

            Rectangle()
                .fill(ChatTheme.hairlineStrong)
                .frame(width: 1, height: 12)

            Text(verbatim: "\(usedText) / \(totalText)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(0.82))
        }
        .frame(height: 30)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ChatTheme.quietSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(ChatTheme.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey("RAM")))
        .accessibilityValue(Text(verbatim: accessibilitySummary))
        .help(accessibilitySummary)
        .onAppear(perform: startSampling)
        .onDisappear(perform: stopSampling)
    }

    private func startSampling() {
        refresh()
        guard timer == nil else { return }

        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { _ in
            Task { @MainActor in
                refresh()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopSampling() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        footprintBytes = max(0, Int64(live_memory_footprint_bytes()))
    }

    private func memoryString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
#endif
