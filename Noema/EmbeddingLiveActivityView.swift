import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// In-app "live activity" surfaced while datasets are prepared in the
/// background (extraction → compression → embedding). Tracks every dataset
/// with an active pipeline at once, collapses to a compact pill, and lingers
/// briefly on terminal states before dismissing itself.
struct EmbeddingLiveActivityView: View {
    @ObservedObject var datasetManager: DatasetManager

    @EnvironmentObject private var tabRouter: TabRouter
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    @State private var entries: [Entry] = []
    @State private var isVisible = false
    @State private var isCollapsed = false
    @State private var removalTasks: [String: Task<Void, Never>] = [:]
    @State private var batteryConfirmDatasetID: String?
    @State private var stopConfirmDatasetID: String?
    #if os(iOS)
    @State private var keyboardVisible = false
    #endif

    private static let activeBlue = Color(red: 0.07, green: 0.56, blue: 1.0)

    private let cardWidth: CGFloat = {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? 460 : 0
        #else
        return 420
        #endif
    }()

    private let outerHorizontalPadding: CGFloat = {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? 0 : 16
        #else
        return 0
        #endif
    }()

    private let collapsedPillWidth: CGFloat = {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? 264 : 212
        #else
        return 248
        #endif
    }()

    var body: some View {
        Group {
            if !entries.isEmpty {
                container
                    .scaleEffect(isVisible ? 1.0 : 0.94)
                    .opacity(isVisible ? 1.0 : 0.0)
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isVisible)
                    .transition(.opacity)
            }
        }
        .onChangeCompat(of: signature, initial: true) { _, _ in
            sync()
        }
        .onDisappear {
            for task in removalTasks.values { task.cancel() }
            removalTasks = [:]
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                keyboardVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                keyboardVisible = false
            }
        }
        #endif
    }

    /// The collapsed pill is pinned top-trailing — the same corner that hosts the
    /// keyboard's dismiss affordance and, on the Explore tab, the model-type
    /// toggle. While either is on screen the pill would cover that control, so
    /// nudge it down to keep the control tappable. Only applies while collapsed —
    /// the expanded card sits lower.
    private var collapsedTopTrailingDrop: CGFloat {
        guard isCollapsed else { return 0 }
        #if os(iOS) || os(visionOS)
        var covered = tabRouter.selection == .explore
        #if os(iOS)
        covered = covered || keyboardVisible
        #endif
        return covered ? 48 : 0
        #else
        return 0
        #endif
    }

    // MARK: - Layout

    private var container: some View {
        Group {
            if isCollapsed {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    collapsedPill
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)),
                                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .trailing))
                            )
                        )
                }
            } else {
                expandedCard
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)),
                            removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing))
                        )
                    )
            }
        }
        .frame(maxWidth: cardWidth == 0 ? .infinity : cardWidth, alignment: isCollapsed ? .trailing : .center)
        .padding(.horizontal, outerHorizontalPadding)
        .padding(.top, collapsedTopTrailingDrop)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isCollapsed)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: tabRouter.selection)
        .contextMenu {
            Button(role: .destructive) {
                dismissTransientEntries()
            } label: {
                Label(LocalizedStringKey("Dismiss"), systemImage: "xmark.circle")
            }
        }
        .confirmationDialog(
            LocalizedStringKey("Proceed on battery power?"),
            isPresented: Binding(
                get: { batteryConfirmDatasetID != nil },
                set: { if !$0 { batteryConfirmDatasetID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("Proceed")) {
                if let id = batteryConfirmDatasetID {
                    datasetManager.startEmbeddingForID(id)
                }
                batteryConfirmDatasetID = nil
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                batteryConfirmDatasetID = nil
            }
        } message: {
            Text(LocalizedStringKey("Embedding is resource intensive. For best performance, plug in your device. Do you want to proceed on battery?"))
        }
        .confirmationDialog(
            LocalizedStringKey("Cancel Embedding?"),
            isPresented: Binding(
                get: { stopConfirmDatasetID != nil },
                set: { if !$0 { stopConfirmDatasetID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("Cancel Embedding"), role: .destructive) {
                if let id = stopConfirmDatasetID {
                    datasetManager.cancelProcessingForID(id)
                }
                stopConfirmDatasetID = nil
            }
            Button(LocalizedStringKey("Continue"), role: .cancel) {
                stopConfirmDatasetID = nil
            }
        } message: {
            Text(LocalizedStringKey("You can restart this process in the dataset details at any time."))
        }
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Rectangle()
                            .fill(AppTheme.separator)
                            .frame(height: 0.8)
                    }
                    row(for: entry)
                }
            }

            if let footnote = stayInAppFootnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: cardWidth == 0 ? .infinity : cardWidth)
        .glassPill(cornerRadius: 22)
#if !os(macOS)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.24), lineWidth: 0.8)
        )
#endif
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: entries.map(\.id))
    }

    private var header: some View {
        Button {
            setCollapsed(true)
        } label: {
            HStack(spacing: 9) {
                LiveActivityDot(color: dotColor, isPulsing: hasActiveWork)

                Text(headerTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                    .compactStatusText(minimumScaleFactor: 0.78)

                Spacer(minLength: 8)

                Text(aggregatePercentText)
                    .activityStatFont()
                    .monospacedDigit()
                    .foregroundStyle(secondaryTextColor)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(for entry: Entry) -> some View {
        let presentation = DatasetIndexingPresentation.make(for: entry.status, locale: locale)

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: presentation.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor(for: presentation))
                    .frame(width: 16, height: 16)

                Text(entry.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                    .compactStatusText(minimumScaleFactor: 0.76)

                Spacer(minLength: 8)

                ZStack(alignment: .trailing) {
                    Text("100% · ~88m 88s")
                        .activityStatFont()
                        .monospacedDigit()
                        .compactStatusText(minimumScaleFactor: 0.72)
                        .hidden()

                    Text(presentation.progressText)
                        .activityStatFont()
                        .monospacedDigit()
                        .foregroundStyle(trailingTextColor(for: presentation))
                        .compactStatusText(minimumScaleFactor: 0.72)
                }

                if presentation.actionState == .cancelOnly {
                    Button {
                        stopConfirmDatasetID = entry.datasetID
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(LocalizedStringKey("Stop")))
                }
            }

            if presentation.showsProgressBar {
                NotificationProgressBar(value: entry.status.progress, height: 5)
            } else {
                Capsule()
                    .fill(terminalTrackColor(for: presentation))
#if os(macOS)
                    .frame(height: 2)
#else
                    .frame(height: 5)
#endif
            }

            if presentation.message != presentation.title && !presentation.message.isEmpty {
                Text(presentation.message)
                    .font(.caption2)
                    .foregroundStyle(secondaryTextColor)
                    .compactStatusText(minimumScaleFactor: 0.78)
            }

            if presentation.actionState == .startAndCancel {
                Text(LocalizedStringKey("Keep Noema open while embedding — locking the screen pauses progress."))
                    .font(.caption2)
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
#if os(macOS)
                    Button {
                        requestStart(entry.datasetID)
                    } label: {
                        Label(String(localized: "Confirm and Start Embedding", locale: locale), systemImage: "play.fill")
                    }
                    .buttonStyle(.industrial(.tinted))

                    Button(role: .destructive) {
                        stopConfirmDatasetID = entry.datasetID
                    } label: {
                        Label(String(localized: "Stop", locale: locale), systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.industrial(.destructive))
#else
                    Button {
                        requestStart(entry.datasetID)
                    } label: {
                        Label(String(localized: "Confirm and Start Embedding", locale: locale), systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .compactStatusText(minimumScaleFactor: 0.72)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        stopConfirmDatasetID = entry.datasetID
                    } label: {
                        Label(String(localized: "Stop", locale: locale), systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .compactStatusText(minimumScaleFactor: 0.72)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
#endif

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
    }

    private var collapsedPill: some View {
        Button {
            setCollapsed(false)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(ringTrackColor, lineWidth: 2.4)

                    Circle()
                        .trim(from: 0, to: max(0.02, CGFloat(aggregateProgress)))
                        .stroke(dotColor, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.2), value: aggregateProgress)
                }
                .frame(width: 15, height: 15)

                Text(collapsedTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                    .compactStatusText(minimumScaleFactor: 0.74)

                Spacer(minLength: 6)

                Text(aggregatePercentText)
                    .activityStatFont()
                    .monospacedDigit()
                    .foregroundStyle(secondaryTextColor)
                    .compactStatusText(minimumScaleFactor: 0.76)

                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: collapsedPillWidth)
#if os(macOS)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
#else
            .contentShape(Capsule())
#endif
        }
        .buttonStyle(.plain)
        .glassPill(cornerRadius: 18)
#if !os(macOS)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.24), lineWidth: 0.8)
        )
#endif
    }

    // MARK: - Derived state

    private var signature: [StatusSignature] {
        datasetManager.processingStatus
            .map { id, status in
                StatusSignature(
                    datasetID: id,
                    stage: status.stage,
                    progressStep: Int((status.progress * 1000).rounded()),
                    message: status.message ?? ""
                )
            }
            .sorted { $0.datasetID < $1.datasetID }
    }

    private var liveStatuses: [(id: String, name: String, status: DatasetProcessingStatus)] {
        datasetManager.processingStatus
            .compactMap { id, status -> (String, String, DatasetProcessingStatus)? in
                guard !isTerminal(status.stage) else { return nil }
                return (id, datasetName(for: id), status)
            }
            .sorted { $0.0 < $1.0 }
    }

    private var hasActiveWork: Bool {
        entries.contains { !isTerminal($0.status.stage) }
    }

    private var dotColor: Color {
        if hasActiveWork { return Self.activeBlue }
        if entries.contains(where: { $0.status.stage == .failed }) { return .orange }
        return .green
    }

    private var aggregateProgress: Double {
        guard !entries.isEmpty else { return 0 }
        let total = entries.reduce(into: 0.0) { partial, entry in
            if entry.status.stage == .completed {
                partial += 1.0
            } else {
                partial += max(0.0, min(1.0, entry.status.progress))
            }
        }
        return total / Double(entries.count)
    }

    private var aggregatePercentText: String {
        "\(Int(aggregateProgress * 100))%"
    }

    private var headerTitle: String {
        if entries.count == 1, let entry = entries.first {
            return DatasetIndexingPresentation.title(for: entry.status.stage, locale: locale)
        }
        return String.localizedStringWithFormat(
            String(localized: "Preparing %d datasets", locale: locale),
            entries.count
        )
    }

    private var collapsedTitle: String {
        if entries.count == 1, let entry = entries.first {
            return entry.name
        }
        return String.localizedStringWithFormat(
            String(localized: "%d datasets", locale: locale),
            entries.count
        )
    }

    /// Stage-aware guidance: during extraction/compression the user is free to
    /// leave; once GPU embedding is running the app must stay in the
    /// foreground. The confirmation gate carries its own inline note.
    private var stayInAppFootnote: LocalizedStringKey? {
        let active = entries.filter { !isTerminal($0.status.stage) }
        guard !active.isEmpty else { return nil }
        if active.contains(where: { $0.status.stage == .embedding && !isConfirmationGate($0.status) }) {
            return LocalizedStringKey("Keep Noema open while embedding — locking the screen pauses progress.")
        }
        if active.allSatisfy({ $0.status.stage == .extracting || $0.status.stage == .compressing }) {
            return LocalizedStringKey("You can leave Noema during this step — embedding hasn't started yet.")
        }
        return nil
    }

    // MARK: - State sync

    private func sync() {
        var next = entries
        let live = liveStatuses

        for item in live {
            if let index = next.firstIndex(where: { $0.datasetID == item.id }) {
                next[index].name = item.name
                next[index].status = item.status
            } else {
                next.append(Entry(datasetID: item.id, name: item.name, status: item.status))
            }
            if let pending = removalTasks[item.id] {
                pending.cancel()
                removalTasks[item.id] = nil
            }
        }

        let liveIDs = Set(live.map(\.id))
        var vanishedActiveIDs: Set<String> = []
        for index in next.indices where !liveIDs.contains(next[index].datasetID) {
            let id = next[index].datasetID
            if let status = datasetManager.processingStatus[id], isTerminal(status.stage) {
                next[index].status = status
                if removalTasks[id] == nil {
                    scheduleRemoval(of: id, after: status.stage == .completed ? 1.4 : 1.8)
                }
            } else if isTerminal(next[index].status.stage) {
                // Status cleared while the terminal state lingers; keep the row
                // until its scheduled removal fires.
                if removalTasks[id] == nil {
                    scheduleRemoval(of: id, after: 1.2)
                }
            } else {
                vanishedActiveIDs.insert(id)
            }
        }
        next.removeAll { vanishedActiveIDs.contains($0.datasetID) }

        let previousIDs = Set(entries.map(\.datasetID))
        let previousGateIDs = Set(entries.filter { isConfirmationGate($0.status) }.map(\.datasetID))
        let previousTerminalIDs = Set(entries.filter { isTerminal($0.status.stage) }.map(\.datasetID))
        let shouldExpand = next.contains { entry in
            !previousIDs.contains(entry.datasetID)
                || (isConfirmationGate(entry.status) && !previousGateIDs.contains(entry.datasetID))
                || (isTerminal(entry.status.stage) && !previousTerminalIDs.contains(entry.datasetID))
        }

        applyEntries(next)
        if shouldExpand {
            setCollapsed(false)
        }
    }

    private func applyEntries(_ newEntries: [Entry]) {
        if newEntries.isEmpty {
            guard !entries.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                isVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !isVisible {
                    entries = []
                    isCollapsed = false
                }
            }
        } else {
            entries = newEntries
            if !isVisible {
                DispatchQueue.main.async {
                    isVisible = true
                }
            }
        }
    }

    private func scheduleRemoval(of id: String, after delay: TimeInterval) {
        removalTasks[id]?.cancel()
        removalTasks[id] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            removalTasks[id] = nil
            applyEntries(entries.filter { $0.datasetID != id })
        }
    }

    private func dismissTransientEntries() {
        let remaining = entries.filter { !isTerminal($0.status.stage) }
        for entry in entries where isTerminal(entry.status.stage) {
            removalTasks[entry.datasetID]?.cancel()
            removalTasks[entry.datasetID] = nil
        }
        applyEntries(remaining)
        if !remaining.isEmpty {
            setCollapsed(true)
        }
    }

    private func setCollapsed(_ collapsed: Bool) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            isCollapsed = collapsed
        }
    }

    private func requestStart(_ id: String) {
        if isPluggedIn() {
            datasetManager.startEmbeddingForID(id)
        } else {
            batteryConfirmDatasetID = id
        }
    }

    // MARK: - Helpers

    private func datasetName(for id: String) -> String {
        if let name = datasetManager.datasets.first(where: { $0.datasetID == id })?.name, !name.isEmpty {
            return name
        }
        return id.split(separator: "/").last.map(String.init) ?? id
    }

    private func isTerminal(_ stage: DatasetProcessingStage) -> Bool {
        stage == .completed || stage == .failed
    }

    private func isConfirmationGate(_ status: DatasetProcessingStatus) -> Bool {
        status.stage == .embedding && status.progress <= 0.0001
    }

    private func iconColor(for presentation: DatasetIndexingPresentation) -> Color {
        switch presentation.tone {
        case .active:
            return Self.activeBlue
        case .success:
            return .green
        case .failure:
            return .orange
        }
    }

    private func trailingTextColor(for presentation: DatasetIndexingPresentation) -> Color {
        switch presentation.tone {
        case .active:
            return secondaryTextColor
        case .success:
            return .green
        case .failure:
            return .orange
        }
    }

    private func terminalTrackColor(for presentation: DatasetIndexingPresentation) -> Color {
        switch presentation.tone {
        case .success:
            return .green.opacity(0.28)
        case .failure:
            return .orange.opacity(0.28)
        case .active:
            return .clear
        }
    }

    private var ringTrackColor: Color {
        #if os(macOS)
        Color.primary.opacity(0.12)
        #else
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
        #endif
    }

    private var primaryTextColor: Color {
        #if os(macOS)
        Color(nsColor: .labelColor)
        #else
        Color.primary
        #endif
    }

    private var secondaryTextColor: Color {
        #if os(macOS)
        Color(nsColor: .secondaryLabelColor)
        #else
        Color.secondary
        #endif
    }
}

// Stat lines follow the Mac industrial 11pt mono; touch keeps caption2.
private extension View {
    func activityStatFont() -> some View {
#if os(macOS)
        font(.system(size: 11, weight: .medium, design: .monospaced))
#else
        font(.caption2)
#endif
    }
}

private struct Entry: Identifiable, Equatable {
    let datasetID: String
    var name: String
    var status: DatasetProcessingStatus

    var id: String { datasetID }
}

private struct StatusSignature: Equatable {
    let datasetID: String
    let stage: DatasetProcessingStage
    let progressStep: Int
    let message: String
}

/// Small pulsing indicator dot signalling live background work.
private struct LiveActivityDot: View {
    let color: Color
    let isPulsing: Bool

    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
#if !os(macOS)
            .shadow(color: color.opacity(0.55), radius: 3)
#endif
            .opacity(isPulsing && dimmed ? 0.35 : 1.0)
            .onAppear {
                guard isPulsing else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
            .onChangeCompat(of: isPulsing) { _, pulsing in
                if pulsing {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        dimmed = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dimmed = false
                    }
                }
            }
    }
}

@MainActor
private func isPluggedIn() -> Bool {
    #if canImport(UIKit)
    UIDevice.current.isBatteryMonitoringEnabled = true
    let state = UIDevice.current.batteryState
    return state == .charging || state == .full
    #else
    return true
    #endif
}
