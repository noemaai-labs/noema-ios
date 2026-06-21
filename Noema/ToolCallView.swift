import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct ToolCallView: View {
    let toolCall: ChatVM.Msg.ToolCall

    @Environment(\.colorScheme) private var colorScheme
    @State private var showingDetails = false
    @State private var isAppearing = false
    @State private var loadingSweepOffset: CGFloat = 0
    @State private var loadingSweepCardWidth: CGFloat = 0
    @State private var showCompletionSweep = false
    @State private var completionSweepProgress: CGFloat = 0.02
    @State private var completionSweepOpacity = 0.0
    @State private var completionSweepTask: Task<Void, Never>?

    private var surfaceColor: Color {
        toolCall.phase == .failed
            ? Color.orange.opacity(0.10)
            : (colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.97))
    }

    private var surfaceBorderColor: Color {
        toolCall.phase == .failed
            ? Color.orange.opacity(0.24)
            : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.10)
    }

    private var secondaryPillForegroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.6) : Color.black.opacity(0.5)
    }

    private var cardShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.1) : Color.black.opacity(0.04)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var loadingSweepShoulderOpacity: Double {
        colorScheme == .dark ? 0.22 : 0.16
    }

    private var loadingSweepCoreOpacity: Double {
        colorScheme == .dark ? 0.26 : 0.5
    }

    private var completionSweepColor: Color {
        Color(red: 0.24, green: 0.82, blue: 0.47)
    }

    private var parameterSummaryEntries: [ToolCallViewSupport.ParameterSummaryEntry] {
        ToolCallViewSupport.parameterSummaryEntries(from: toolCall.requestParams)
    }

    private var remainingParameterCount: Int {
        ToolCallViewSupport.remainingParameterCount(from: toolCall.requestParams)
    }

    private var isWebSearchActive: Bool {
        ToolCallViewSupport.isActiveWebSearch(toolName: toolCall.toolName, phase: toolCall.phase)
    }

    private var statusTitleKey: String {
        switch toolCall.phase {
        case .requesting:
            return "Tool requested"
        case .executing, .running:
            return "Tool running"
        case .completed:
            return "Tool completed"
        case .failed:
            return "Tool failed"
        }
    }

    private var outcomePreview: (titleKey: String, text: String, isError: Bool)? {
        if let error = toolCall.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return ("Tool error", Self.compactPreview(error), true)
        }
        if let result = toolCall.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
            return ("Tool result", Self.compactPreview(ToolCallViewSupport.formatRawResult(result)), false)
        }
        return nil
    }

    var body: some View {
        Button(action: { showingDetails = true }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: toolCall.iconName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondaryPillForegroundColor)
                        Text(toolCall.displayName.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(0.5)
                            .foregroundStyle(secondaryPillForegroundColor)
                    }

                    Spacer()

                    statusIndicator
                }

                Text(toolCall.toolName)
                    .font(.caption2)
                    .foregroundStyle(secondaryPillForegroundColor)

                HStack(spacing: 6) {
                    Text(LocalizedStringKey(statusTitleKey))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(toolCall.phase == .failed ? .orange : secondaryPillForegroundColor)
                    Text(toolCall.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(secondaryPillForegroundColor)
                }

                if !parameterSummaryEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(parameterSummaryEntries) { entry in
                            HStack(spacing: 4) {
                                Text("\(entry.key):")
                                    .font(.caption2)
                                    .foregroundStyle(secondaryPillForegroundColor)
                                Text(entry.value)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.82))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        if remainingParameterCount > 0 {
                            Text("... and \(remainingParameterCount) more")
                                .font(.caption2)
                                .foregroundStyle(secondaryPillForegroundColor)
                                .italic()
                        }
                    }
                    .padding(.horizontal, 2)
                }

                if let outcomePreview {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(outcomePreview.titleKey))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(outcomePreview.isError ? .orange : secondaryPillForegroundColor)
                        Text(outcomePreview.text)
                            .font(.caption2)
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.86) : Color.black.opacity(0.74))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(14)
            .background(surfaceColor)
            .clipShape(cardShape)
            .overlay(
                cardShape
                    .strokeBorder(surfaceBorderColor, lineWidth: 0.6)
            )
            .shadow(color: cardShadowColor, radius: 8, x: 0, y: 4)
            .overlay(
                GeometryReader { geo in
                    #if !os(visionOS)
                    if isWebSearchActive {
                        loadingSweepOverlay(in: geo.size)
                            .onAppear {
                                startLoadingSweep(cardWidth: geo.size.width)
                            }
                            .onChangeCompat(of: geo.size.width) { _, newWidth in
                                startLoadingSweep(cardWidth: newWidth)
                            }
                    }
                    #endif
                }
                .clipShape(cardShape)
                .allowsHitTesting(false)
            )
            .overlay(
                Group {
                    if showCompletionSweep {
                        completionSweepOverlay
                    }
                }
                .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
        .opacity(isAppearing ? 1 : 0)
        .scaleEffect(isAppearing ? 1 : 0.98)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isAppearing = true
            }
            initializeAnimationState()
        }
        .onDisappear {
            stopLoadingSweep()
            completionSweepTask?.cancel()
        }
        .onChangeCompat(of: toolCall.phase) { oldPhase, newPhase in
            guard oldPhase != newPhase else { return }
            handlePhaseChange(newPhase)
        }
        .toolCallDetailPresentation(isPresented: $showingDetails, toolCall: toolCall)
    }

    private static func compactPreview(_ text: String) -> String {
        let condensed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard condensed.count > 180 else { return condensed }
        return String(condensed.prefix(177)) + "..."
    }

    @ViewBuilder
    private func loadingSweepOverlay(in size: CGSize) -> some View {
        let width = max(size.width * 0.6, 1)
        let height = max(size.height * 1.8, 1)

        LinearGradient(
            colors: [
                .clear,
                Color.accentColor.opacity(loadingSweepShoulderOpacity),
                Color.white.opacity(loadingSweepCoreOpacity),
                Color.accentColor.opacity(loadingSweepShoulderOpacity),
                .clear
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: width, height: height)
        .blur(radius: 4)
        .rotationEffect(.degrees(12))
        .offset(x: loadingSweepOffset)
        .blendMode(.screen)
    }

    private var completionSweepOverlay: some View {
        let segmentStart = max(0.001, completionSweepProgress - 0.18)
        let segmentEnd = max(segmentStart + 0.001, completionSweepProgress)
        let trimmedShape = cardShape.trim(from: segmentStart, to: segmentEnd)

        return ZStack {
            trimmedShape
                .stroke(
                    completionSweepColor.opacity(completionSweepOpacity * 0.35),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
                .blur(radius: 3)

            trimmedShape
                .stroke(
                    completionSweepColor.opacity(completionSweepOpacity),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
        .rotationEffect(.degrees(-90))
    }

    private func initializeAnimationState() {
        if !toolCall.phase.isInFlight {
            stopLoadingSweep()
        }

        if ToolCallViewSupport.shouldAnimateCompletionSweep(toolName: toolCall.toolName, phase: toolCall.phase) {
            playCompletionSweep()
        } else if toolCall.phase == .completed || toolCall.phase == .failed {
            resetCompletionSweep()
        }
    }

    private func handlePhaseChange(_ phase: ChatVM.Msg.ToolCallPhase) {
        if !phase.isInFlight {
            stopLoadingSweep()
        }

        if ToolCallViewSupport.shouldAnimateCompletionSweep(toolName: toolCall.toolName, phase: phase) {
            playCompletionSweep()
            return
        }

        resetCompletionSweep()
        if loadingSweepCardWidth > 0,
           ToolCallViewSupport.isActiveWebSearch(toolName: toolCall.toolName, phase: phase) {
            startLoadingSweep(cardWidth: loadingSweepCardWidth)
        }
    }

    private func startLoadingSweep(cardWidth: CGFloat) {
        guard cardWidth > 0 else { return }
        loadingSweepCardWidth = cardWidth

        let startOffset = -cardWidth * 0.9
        let endOffset = cardWidth * 0.9

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            loadingSweepOffset = startOffset
        }

        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
            loadingSweepOffset = endOffset
        }
    }

    private func stopLoadingSweep() {
        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            loadingSweepOffset = 0
        }
    }

    private func playCompletionSweep() {
        completionSweepTask?.cancel()

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            showCompletionSweep = true
            completionSweepProgress = 0.02
            completionSweepOpacity = 1
        }

        withAnimation(.linear(duration: 0.85)) {
            completionSweepProgress = 1
        }

        completionSweepTask = Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    completionSweepOpacity = 0
                }
            }

            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                resetCompletionSweep()
            }
        }
    }

    private func resetCompletionSweep() {
        completionSweepTask?.cancel()
        completionSweepTask = nil

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            showCompletionSweep = false
            completionSweepProgress = 0.02
            completionSweepOpacity = 0
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if toolCall.phase == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
        } else if toolCall.phase == .completed {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(secondaryPillForegroundColor)
        } else {
            ProgressView()
                .scaleEffect(0.7)
        }
    }
}

extension ToolCallView: Equatable {
    /// When the parent re-renders (e.g. every streaming token in the same turn),
    /// SwiftUI uses this to skip re-evaluating `body` for tool calls whose data
    /// hasn't changed — preventing layout thrashing from `GeometryReader` and
    /// relative-time `Text` nodes inside the card.
    static func == (lhs: ToolCallView, rhs: ToolCallView) -> Bool {
        lhs.toolCall == rhs.toolCall
    }
}

struct ToolCallDetailSheet: View {
    let toolCall: ChatVM.Msg.ToolCall

    @EnvironmentObject private var vm: ChatVM
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var resultDisplayMode: ToolCallViewSupport.ResultDisplayMode
    @State private var pinnedResult = false

    init(toolCall: ChatVM.Msg.ToolCall) {
        self.toolCall = toolCall
        _resultDisplayMode = State(
            initialValue: ToolCallViewSupport.defaultResultDisplayMode(
                toolName: toolCall.toolName,
                result: toolCall.result
            )
        )
    }

    private var sectionBackgroundColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04)
    }

    private var sectionBorderColor: Color {
        Color.primary.opacity(0.08)
    }

    private var neutralPillBackgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05)
    }

    private var neutralPillForegroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.8) : Color.black.opacity(0.7)
    }

    private var secondaryPillForegroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.6) : Color.black.opacity(0.5)
    }

    private var monospaceBackgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.02)
    }

    private var warningBackgroundColor: Color {
        Color.orange.opacity(0.08)
    }

    private var warningBorderColor: Color {
        Color.orange.opacity(0.18)
    }

    private var hasPinPayload: Bool {
        toolCall.result?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || toolCall.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var canRequestRepair: Bool {
        toolCall.phase == .failed
            && vm.canAcceptChatInput
            && !vm.isStreamingInAnotherSession
    }

    var body: some View {
#if os(macOS)
        // Compact, fixed-size popover: a quiet title bar instead of a large
        // navigation chrome, and tight content sections.
        VStack(spacing: 0) {
            macHeaderBar
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    actionSection
                    requestParameterSection
                    outcomeSections
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChangeCompat(of: toolCall.result) { _, newValue in
            handleResultChange(newValue)
        }
#else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    actionSection
                    requestParameterSection
                    outcomeSections

                    Spacer(minLength: 20)
                }
                .padding()
            }
            .navigationTitle("Tool Call Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChangeCompat(of: toolCall.result) { _, newValue in
                handleResultChange(newValue)
            }
        }
#endif
    }

    private func handleResultChange(_ newValue: String?) {
        guard let newValue else { return }
        if resultDisplayMode == .formatted,
           !ToolCallViewSupport.supportsFormattedResultDisplay(
            toolName: toolCall.toolName,
            result: newValue
           ) {
            resultDisplayMode = .raw
        }
    }

    @ViewBuilder
    private var outcomeSections: some View {
        if let error = toolCall.error {
            errorSection(error)
            if let result = toolCall.result {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Raw Response")
                        .font(.system(size: 13, weight: .semibold))
                    rawResultView(for: result)
                }
            }
        } else if let result = toolCall.result {
            resultSection(result)
        } else {
            inFlightSection
        }
    }

#if os(macOS)
    private var macHeaderBar: some View {
        HStack(spacing: 8) {
            Image(systemName: toolCall.iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(toolCall.phase == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(toolCall.displayName)
                .font(.system(size: 13, weight: .semibold))
            Text(verbatim: toolCall.toolName)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(toolCall.timestamp, style: .time)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
#endif

    @ViewBuilder
    private var actionSection: some View {
        if hasPinPayload || toolCall.phase == .failed {
            HStack(spacing: 8) {
                if hasPinPayload {
                    Button {
                        vm.pinToolCallToActiveScratchpad(toolCall)
                        pinnedResult = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            pinnedResult = false
                        }
                    } label: {
                        Label(
                            pinnedResult ? LocalizedStringKey("Pinned Result") : LocalizedStringKey("Pin Result"),
                            systemImage: pinnedResult ? "checkmark" : "note.text.badge.plus"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if toolCall.phase == .failed {
                    Button {
                        dismiss()
                        Task { await vm.requestToolCallRepair(toolCall) }
                    } label: {
                        Label("Repair Tool Call", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canRequestRepair)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: toolCall.iconName)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(toolCall.phase == .failed ? .orange : secondaryPillForegroundColor)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(toolCall.displayName)
                    .font(.headline)
                Text(toolCall.toolName)
                    .font(.caption)
                    .foregroundColor(secondaryPillForegroundColor)
                Text(toolCall.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(secondaryPillForegroundColor)
            }

            Spacer()
        }
        .padding()
        .background(sectionBackgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(sectionBorderColor, lineWidth: 0.8)
        )
        .cornerRadius(12)
    }

    /// Compact key/value rows on one quiet surface — no nested monospaced
    /// boxes per parameter.
    private var requestParameterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Parameters")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            if toolCall.requestParams.isEmpty {
                Text("No parameters")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(toolCall.requestParams.keys.sorted()), id: \.self) { key in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(key)
                                .font(.caption.weight(.medium))
                                .foregroundColor(secondaryPillForegroundColor)
                                .frame(width: 92, alignment: .leading)
                            Text(ToolCallViewSupport.formatParameterValue(toolCall.requestParams[key]?.value))
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(sectionBackgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(sectionBorderColor, lineWidth: 0.8)
        )
        .cornerRadius(10)
    }

    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text("Error")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)
            }

            Text(error)
                .font(.caption)
                .textSelection(.enabled)
                .padding()
                .background(warningBackgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(warningBorderColor, lineWidth: 0.8)
                )
                .cornerRadius(8)
        }
    }

    private func resultSection(_ result: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Result")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Spacer()

                Picker("Result format", selection: $resultDisplayMode) {
                    ForEach(ToolCallViewSupport.ResultDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 150)
            }

            Group {
                if resultDisplayMode == .formatted {
                    formattedResultView(for: result)
                } else {
                    rawResultView(for: result)
                }
            }
            .animation(.none, value: resultDisplayMode)
        }
    }

    private var inFlightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: toolCall.phase == .requesting ? "clock.fill" : "play.circle.fill")
                    .font(.caption)
                    .foregroundColor(secondaryPillForegroundColor)
                Text(toolCall.phase == .requesting ? "Requesting Tool" : "Running Tool")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
            }

            Text(toolCall.phase == .requesting ? "The model is still composing the tool request." : "Waiting for tool response…")
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()
        }
    }

    @ViewBuilder
    private func formattedResultView(for result: String) -> some View {
        if let dryRun = ToolCallViewSupport.parseDryRunResult(from: result) {
            dryRunResultView(dryRun)
        } else {
            switch ToolCallViewSupport.toolKind(for: toolCall.toolName) {
            case .python:
                pythonResultView(for: result)
            case .memory:
                memoryResultView(for: result)
            case .calculator, .unitConverter:
                deterministicResultView(for: result)
            case .webSearch:
                let hits = ToolCallViewSupport.parseWebResults(from: result)
                if hits.isEmpty {
                    unavailableFormattedResultView
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(hits.enumerated()), id: \.offset) { index, item in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("\(index + 1).")
                                            .font(.headline.weight(.semibold))
                                        Text(item.displayTitle.isEmpty ? "Untitled Result" : item.displayTitle)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                            .multilineTextAlignment(.leading)
                                    }

                                    if !item.snippet.isEmpty {
                                        Text(item.snippet.strippingHTMLTags())
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    if !item.url.isEmpty {
                                        if let destination = URL(string: item.url) ?? URL(string: "https://" + item.url) {
                                            Link(item.url, destination: destination)
                                                .font(.caption)
                                                .foregroundColor(.blue)
                                                .lineLimit(2)
                                        } else {
                                            Text(item.url)
                                                .font(.caption)
                                                .foregroundColor(.blue)
                                                .lineLimit(2)
                                                .textSelection(.enabled)
                                        }
                                    }

                                    if item.engine != nil {
                                        HStack(spacing: 6) {
                                            if let engine = item.engine, !engine.isEmpty {
                                                Text(engine)
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundColor(neutralPillForegroundColor)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(neutralPillBackgroundColor)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(sectionBackgroundColor)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(sectionBorderColor, lineWidth: 0.8)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .modifier(
                        ResultBoxStyle(
                            backgroundColor: sectionBackgroundColor,
                            borderColor: sectionBorderColor
                        )
                    )
                }
            case .generic:
                unavailableFormattedResultView
            }
        }
    }

    private func dryRunResultView(_ result: ToolCallViewSupport.DryRunToolResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(LocalizedStringKey("Dry Run"))
                    .font(.headline)
            }
            Text(LocalizedStringKey("Tool call was recorded but not executed."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !result.tool.isEmpty {
                Text(verbatim: result.tool)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .modifier(
            ResultBoxStyle(
                backgroundColor: sectionBackgroundColor,
                borderColor: sectionBorderColor
            )
        )
    }

    @ViewBuilder
    private func deterministicResultView(for result: String) -> some View {
        if let response = ToolCallViewSupport.parseDeterministicResult(from: result) {
            VStack(alignment: .leading, spacing: 10) {
                if let error = response.error, !error.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(verbatim: error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: response.toUnit == nil ? "function" : "arrow.left.arrow.right")
                            .foregroundStyle(.secondary)
                        Text(verbatim: response.displayResult)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .textSelection(.enabled)
                    }

                    if let detail = response.detailText {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .modifier(
                ResultBoxStyle(
                    backgroundColor: sectionBackgroundColor,
                    borderColor: sectionBorderColor
                )
            )
        } else {
            rawResultView(for: result)
        }
    }

    @ViewBuilder
    private func memoryResultView(for result: String) -> some View {
        if let response = ToolCallViewSupport.parseMemoryResult(from: result) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(response.operation.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(neutralPillBackgroundColor)
                        .clipShape(Capsule())
                    if let message = response.message, !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let entry = response.entry {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.title)
                            .font(.headline)
                        Text(entry.content)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("ID: \(entry.id)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else if let entries = response.entries, !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1). \(entry.title)")
                                    .font(.subheadline.weight(.semibold))
                                Text(entry.content)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                            if index < entries.count - 1 {
                                Divider()
                            }
                        }
                    }
                } else {
                    Text("No memory entries returned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .modifier(
                ResultBoxStyle(
                    backgroundColor: sectionBackgroundColor,
                    borderColor: sectionBorderColor
                )
            )
        } else {
            rawResultView(for: result)
        }
    }

    private var unavailableFormattedResultView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Formatted view unavailable")
                .font(.subheadline.weight(.semibold))
            Text("The tool returned data that can't be formatted. Switch to Raw to inspect the original response.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(
            ResultBoxStyle(
                backgroundColor: sectionBackgroundColor,
                borderColor: sectionBorderColor
            )
        )
    }

    @ViewBuilder
    private func pythonResultView(for result: String) -> some View {
        if let pythonResult = ToolCallViewSupport.parsePythonResult(from: result) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Exit code: \(pythonResult.exitCode)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            pythonResult.exitCode == 0
                                ? neutralPillBackgroundColor
                                : Color.red.opacity(0.12)
                        )
                        .clipShape(Capsule())
                    Text("\(pythonResult.executionTimeMs)ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if pythonResult.timedOut {
                        Text("TIMED OUT")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                    }
                }

                if !pythonResult.artifacts.isEmpty {
                    pythonNotebookArtifactsView(pythonResult.artifacts)
                }

                if !pythonResult.stdout.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("Execution Log"))
                            .font(.caption.weight(.semibold))
                        ScrollView {
                            Text(pythonResult.stdout)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                        .padding(8)
                        .background(monospaceBackgroundColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(sectionBorderColor, lineWidth: 0.8)
                        )
                        .cornerRadius(8)
                    }
                }

                if !pythonResult.stderr.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("Errors"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        ScrollView {
                            Text(pythonResult.stderr)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                        .padding(8)
                        .background(warningBackgroundColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(warningBorderColor, lineWidth: 0.8)
                        )
                        .cornerRadius(8)
                    }
                }

                if let error = pythonResult.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .modifier(
                ResultBoxStyle(
                    backgroundColor: sectionBackgroundColor,
                    borderColor: sectionBorderColor
                )
            )
        } else {
            rawResultView(for: result)
        }
    }

    @ViewBuilder
    private func pythonNotebookArtifactsView(_ artifacts: [PythonExecutionArtifact]) -> some View {
        let imageArtifacts = artifacts.filter { $0.kind == "image" }
        let tableArtifacts = artifacts.filter { $0.kind == "table" }
        let otherArtifacts = artifacts.filter { $0.kind != "image" && $0.kind != "table" }

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.play")
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey("Notebook Output"))
                    .font(.caption.weight(.semibold))
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "%d artifact(s)"),
                        artifacts.count
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if !imageArtifacts.isEmpty {
                artifactGroup(titleKey: "Charts", systemImage: "chart.xyaxis.line") {
                    ForEach(imageArtifacts) { artifact in
                        pythonImageArtifactView(artifact)
                    }
                }
            }

            if !tableArtifacts.isEmpty {
                artifactGroup(titleKey: "Tables", systemImage: "tablecells") {
                    ForEach(tableArtifacts) { artifact in
                        pythonTableArtifactView(artifact)
                    }
                }
            }

            if !otherArtifacts.isEmpty {
                artifactGroup(titleKey: "Generated Files", systemImage: "doc.badge.gearshape") {
                    ForEach(otherArtifacts) { artifact in
                        pythonFileArtifactView(artifact)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func artifactGroup<Content: View>(
        titleKey: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LocalizedStringKey(titleKey), systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pythonImageArtifactView(_ artifact: PythonExecutionArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            artifactHeader(artifact)

            #if os(macOS)
            if let image = ToolCallViewSupport.platformImage(fromBase64: artifact.base64Data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                unavailableArtifactPreview
            }
            #elseif canImport(UIKit)
            if let image = ToolCallViewSupport.platformImage(fromBase64: artifact.base64Data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                unavailableArtifactPreview
            }
            #else
            unavailableArtifactPreview
            #endif
        }
        .modifier(
            ResultBoxStyle(
                backgroundColor: monospaceBackgroundColor,
                borderColor: sectionBorderColor
            )
        )
    }

    private func pythonTableArtifactView(_ artifact: PythonExecutionArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            artifactHeader(artifact)

            let rows = ToolCallViewSupport.tablePreviewRows(for: artifact)
            if rows.isEmpty {
                unavailableArtifactPreview
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                    Text(value)
                                        .font(.caption2.monospaced())
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                        .frame(minWidth: 72, maxWidth: 150, alignment: .leading)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 5)
                                        .background(rowIndex == 0 ? neutralPillBackgroundColor : Color.clear)
                                        .border(sectionBorderColor.opacity(0.7), width: 0.5)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .modifier(
            ResultBoxStyle(
                backgroundColor: monospaceBackgroundColor,
                borderColor: sectionBorderColor
            )
        )
    }

    private func pythonFileArtifactView(_ artifact: PythonExecutionArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            artifactHeader(artifact)

            if let preview = artifact.preview, !preview.isEmpty {
                Text(preview)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(monospaceBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                unavailableArtifactPreview
            }
        }
        .modifier(
            ResultBoxStyle(
                backgroundColor: sectionBackgroundColor,
                borderColor: sectionBorderColor
            )
        )
    }

    private func artifactHeader(_ artifact: PythonExecutionArtifact) -> some View {
        HStack(spacing: 8) {
            Text(artifact.relativePath)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Text(ToolCallViewSupport.fileSizeString(artifact.sizeBytes))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(artifact.kind.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(neutralPillForegroundColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(neutralPillBackgroundColor)
                .clipShape(Capsule())
        }
    }

    private var unavailableArtifactPreview: some View {
        Text(LocalizedStringKey("Preview truncated or unavailable"))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .italic()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(monospaceBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func rawResultView(for result: String) -> some View {
        ScrollView {
            Text(ToolCallViewSupport.formatRawResult(result))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(
            ResultBoxStyle(
                backgroundColor: monospaceBackgroundColor,
                borderColor: sectionBorderColor
            )
        )
    }
}

private struct ResultBoxStyle: ViewModifier {
    let backgroundColor: Color
    let borderColor: Color

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: 300)
            .padding()
            .background(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: 0.8)
            )
            .cornerRadius(8)
    }
}

enum ToolCallViewSupport {
    enum ToolKind: Equatable {
        case webSearch
        case python
        case memory
        case calculator
        case unitConverter
        case generic
    }

    enum ResultDisplayMode: String, CaseIterable, Hashable {
        case formatted
        case raw

        var title: String {
            rawValue.capitalized
        }
    }

    struct WebSearchResultItem: Equatable {
        let title: String
        let url: String
        let snippet: String
        let engine: String?
        let score: String?

        init?(dictionary: [String: Any]) {
            let rawTitle = (dictionary["title"] as? String) ?? (dictionary["name"] as? String) ?? ""
            let rawURL = (dictionary["url"] as? String) ?? (dictionary["link"] as? String) ?? ""
            let rawSnippet = (dictionary["snippet"] as? String)
                ?? (dictionary["summary"] as? String)
                ?? (dictionary["description"] as? String)
                ?? ""

            let normalizedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSnippet = rawSnippet.trimmingCharacters(in: .whitespacesAndNewlines)

            if normalizedTitle.isEmpty && normalizedURL.isEmpty && normalizedSnippet.isEmpty {
                return nil
            }

            title = normalizedTitle
            url = normalizedURL
            snippet = normalizedSnippet
            engine = (dictionary["engine"] as? String) ?? (dictionary["source"] as? String)

            if let string = dictionary["score"] as? String {
                score = string
            } else if let number = dictionary["score"] as? NSNumber {
                score = number.stringValue
            } else if let bool = dictionary["score"] as? Bool {
                score = bool ? "true" : "false"
            } else if let string = dictionary["rank"] as? String {
                score = string
            } else if let number = dictionary["rank"] as? NSNumber {
                score = number.stringValue
            } else if let bool = dictionary["rank"] as? Bool {
                score = bool ? "true" : "false"
            } else {
                score = nil
            }
        }

        var displayTitle: String {
            title.isEmpty ? url : title
        }
    }

    struct ParameterSummaryEntry: Equatable, Identifiable {
        let key: String
        let value: String

        var id: String { key }
    }

    struct DeterministicToolResult: Equatable {
        let expression: String?
        let value: String?
        let fromUnit: String?
        let toUnit: String?
        let category: String?
        let formattedResult: String?
        let error: String?

        var displayResult: String {
            if let formattedResult, !formattedResult.isEmpty {
                if let toUnit, !toUnit.isEmpty {
                    return "\(formattedResult) \(toUnit)"
                }
                return formattedResult
            }
            return error ?? ""
        }

        var detailText: String? {
            if let expression, !expression.isEmpty {
                return expression
            }
            guard let value, let fromUnit else { return category }
            let base = "\(value) \(fromUnit) -> \(displayResult)"
            if let category, !category.isEmpty {
                return "\(base) · \(category)"
            }
            return base
        }
    }

    struct DryRunToolResult: Equatable {
        let tool: String
    }

    static func toolKind(for toolName: String) -> ToolKind {
        let normalizedToolName = toolName.lowercased()
        if normalizedToolName.contains("noema.math.calculate")
            || normalizedToolName.contains("math")
            || normalizedToolName.contains("calculator") {
            return .calculator
        }
        if normalizedToolName.contains("noema.units.convert")
            || normalizedToolName.contains("unit")
            || normalizedToolName.contains("convert") {
            return .unitConverter
        }
        if normalizedToolName.contains("python") {
            return .python
        }
        if normalizedToolName.contains("memory") {
            return .memory
        }
        if normalizedToolName.contains("noema.web.retrieve")
            || normalizedToolName.contains("web")
            || normalizedToolName.contains("search") {
            return .webSearch
        }
        return .generic
    }

    static func defaultResultDisplayMode(toolName: String, result: String?) -> ResultDisplayMode {
        supportsFormattedResultDisplay(toolName: toolName, result: result) ? .formatted : .raw
    }

    static func supportsFormattedResultDisplay(toolName: String, result: String?) -> Bool {
        guard let result else { return false }
        if parseDryRunResult(from: result) != nil { return true }

        switch toolKind(for: toolName) {
        case .python:
            return parsePythonResult(from: result) != nil
        case .memory:
            return parseMemoryResult(from: result) != nil
        case .webSearch:
            return !parseWebResults(from: result).isEmpty
        case .calculator, .unitConverter:
            return parseDeterministicResult(from: result) != nil
        case .generic:
            return parseDryRunResult(from: result) != nil
        }
    }

    static func isActiveWebSearch(toolName: String, phase: ChatVM.Msg.ToolCallPhase) -> Bool {
        toolKind(for: toolName) == .webSearch && phase.isInFlight
    }

    static func shouldAnimateCompletionSweep(toolName: String, phase: ChatVM.Msg.ToolCallPhase) -> Bool {
        phase == .completed && toolKind(for: toolName) == .generic
    }

    static func parsePythonResult(from result: String) -> PythonExecutionResult? {
        guard let data = result.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PythonExecutionResult.self, from: data)
    }

    static func parseDeterministicResult(from result: String) -> DeterministicToolResult? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let error = object["error"] as? String
        let formattedResult = object["formatted_result"] as? String
        guard error?.isEmpty == false || formattedResult?.isEmpty == false else {
            return nil
        }

        func stringValue(_ key: String) -> String? {
            if let string = object[key] as? String { return string }
            if let number = object[key] as? NSNumber { return number.stringValue }
            return nil
        }

        return DeterministicToolResult(
            expression: stringValue("expression"),
            value: stringValue("value"),
            fromUnit: stringValue("from_unit"),
            toUnit: stringValue("to_unit"),
            category: stringValue("category"),
            formattedResult: formattedResult,
            error: error
        )
    }

    static func parseDryRunResult(from result: String) -> DryRunToolResult? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["dry_run"] as? Bool == true else {
            return nil
        }
        return DryRunToolResult(tool: object["tool"] as? String ?? "")
    }

    static func parseWebResults(from result: String) -> [WebSearchResultItem] {
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        var rawItems: [[String: Any]] = []

        if let array = json as? [[String: Any]] {
            rawItems = array
        } else if let dict = json as? [String: Any] {
            let candidateKeys = ["results", "items", "data", "hits", "entries"]
            for key in candidateKeys {
                if let array = dict[key] as? [[String: Any]] {
                    rawItems = array
                    break
                }
            }
            if rawItems.isEmpty, let array = dict["result"] as? [[String: Any]] {
                rawItems = array
            }
        }

        return rawItems.compactMap { WebSearchResultItem(dictionary: $0) }
    }

    static func parseMemoryResult(from result: String) -> MemoryToolResponse? {
        guard let data = result.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MemoryToolResponse.self, from: data)
    }

    static func parameterSummaryEntries(
        from params: [String: AnyCodable],
        maxEntries: Int = 2,
        maxValueLength: Int = 50
    ) -> [ParameterSummaryEntry] {
        Array(params.keys.sorted().prefix(maxEntries)).map { key in
            let rawValue = String(describing: params[key]?.value ?? "")
            return ParameterSummaryEntry(
                key: key,
                value: String(rawValue.prefix(maxValueLength))
            )
        }
    }

    static func remainingParameterCount(from params: [String: AnyCodable], maxEntries: Int = 2) -> Int {
        max(0, params.count - maxEntries)
    }

    static func formatParameterValue(_ value: Any?) -> String {
        guard let value else { return "null" }

        if let string = value as? String {
            return string
        }
        if let dict = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: data, encoding: .utf8) {
            return prettyString
        }
        if let array = value as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: data, encoding: .utf8) {
            return prettyString
        }

        return String(describing: value)
    }

    static func fileSizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    static func tablePreviewRows(for artifact: PythonExecutionArtifact, maxRows: Int = 8, maxColumns: Int = 6) -> [[String]] {
        guard let preview = artifact.preview, !preview.isEmpty else { return [] }
        let delimiter = artifact.filename.lowercased().hasSuffix(".tsv") ? "\t" : ","
        return preview
            .split(whereSeparator: \.isNewline)
            .prefix(maxRows)
            .map { line in
                parseDelimitedLine(String(line), delimiter: Character(delimiter))
                    .prefix(maxColumns)
                    .map { value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? " " : trimmed
                    }
            }
            .filter { !$0.isEmpty }
    }

    private static func parseDelimitedLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false
        var iterator = line.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if insideQuotes, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")
                    } else {
                        insideQuotes = false
                        if next == delimiter {
                            fields.append(current)
                            current = ""
                        } else {
                            current.append(next)
                        }
                    }
                } else {
                    insideQuotes.toggle()
                }
            } else if character == delimiter, !insideQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        fields.append(current)
        return fields
    }

    #if os(macOS)
    static func platformImage(fromBase64 base64Data: String?) -> NSImage? {
        guard let base64Data,
              let data = Data(base64Encoded: base64Data) else {
            return nil
        }
        return NSImage(data: data)
    }
    #elseif canImport(UIKit)
    static func platformImage(fromBase64 base64Data: String?) -> UIImage? {
        guard let base64Data,
              let data = Data(base64Encoded: base64Data) else {
            return nil
        }
        return UIImage(data: data)
    }
    #endif

    /// Memoized — this runs inside `body` paths that re-render ~10 Hz during
    /// streaming, and JSON round-tripping a large result per render is wasted
    /// main-thread time. Deterministic (`.sortedKeys`), so caching is safe.
    private static let formattedResultCache = TextComputationCache<String>(countLimit: 128)

    static func formatRawResult(_ result: String) -> String {
        formattedResultCache.value(for: result) {
            formatRawResultUncached(result)
        }
    }

    private static func formatRawResultUncached(_ result: String) -> String {
        // `.sortedKeys` is essential: JSONSerialization.jsonObject yields an unordered
        // dictionary, so without a stable key order each re-serialization emits keys in
        // a different order. Because this runs inside `body` (recomputed on every
        // streaming token and on hover), that non-determinism made the rendered lines
        // visibly swap places. Sorting keys makes the output byte-stable across renders.
        if let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            return prettyString
        }
        return result
    }
}

private extension View {
    @ViewBuilder
    func toolCallDetailPresentation(
        isPresented: Binding<Bool>,
        toolCall: ChatVM.Msg.ToolCall
    ) -> some View {
        #if os(macOS)
        popover(isPresented: isPresented, arrowEdge: .top) {
            ToolCallDetailSheet(toolCall: toolCall)
                .toolCallDetailPopupPresentation()
        }
        #else
        sheet(isPresented: isPresented) {
            ToolCallDetailSheet(toolCall: toolCall)
                .toolCallDetailPopupPresentation()
        }
        #endif
    }

    @ViewBuilder
    func toolCallDetailPopupPresentation() -> some View {
        #if os(macOS)
        // Fixed, restrained popover size — without a max the popover balloons
        // to fit wide result content and reads like a full-screen takeover.
        frame(width: 560, height: 560)
        #else
        self
        #endif
    }
}

private enum HTMLStripper {
    static let newlineRegex = try? NSRegularExpression(
        pattern: "<\\s*(br|/?p)\\b[^>]*>",
        options: [.caseInsensitive]
    )
    static let tagRegex = try? NSRegularExpression(
        pattern: "<[^>]+>",
        options: [.caseInsensitive]
    )
}

fileprivate extension String {
    func strippingHTMLTags() -> String {
        guard !isEmpty else { return self }

        var working = self

        if let newlineRegex = HTMLStripper.newlineRegex {
            let range = NSRange(location: 0, length: working.utf16.count)
            working = newlineRegex.stringByReplacingMatches(
                in: working,
                options: [],
                range: range,
                withTemplate: "\n"
            )
        }

        if let tagRegex = HTMLStripper.tagRegex {
            let range = NSRange(location: 0, length: working.utf16.count)
            working = tagRegex.stringByReplacingMatches(
                in: working,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        working = working.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        working = working.replacingOccurrences(
            of: " {2,}",
            with: " ",
            options: .regularExpression
        )

        working = working.decodingHTMLEntities()
        working = working.replacingOccurrences(of: "\u{00A0}", with: " ")

        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodingHTMLEntities() -> String {
        var decoded = self
        let namedEntities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&nbsp;": "\u{00A0}"
        ]

        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }

        func replacingMatches(pattern: String, transformer: (NSTextCheckingResult, String) -> String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return decoded }
            let nsString = decoded as NSString
            let matches = regex.matches(in: decoded, options: [], range: NSRange(location: 0, length: nsString.length))
            var result = decoded
            for match in matches.reversed() {
                let replacement = transformer(match, decoded)
                let range = match.range
                let startIndex = result.index(result.startIndex, offsetBy: range.location)
                let endIndex = result.index(startIndex, offsetBy: range.length)
                result.replaceSubrange(startIndex..<endIndex, with: replacement)
            }
            return result
        }

        decoded = replacingMatches(pattern: "&#(\\d+);") { match, source in
            let nsSource = source as NSString
            let numberRange = match.range(at: 1)
            let numberString = nsSource.substring(with: numberRange)
            if let codePoint = Int(numberString), let scalar = UnicodeScalar(codePoint) {
                return String(scalar)
            }
            return nsSource.substring(with: match.range)
        }

        decoded = replacingMatches(pattern: "&#x([0-9A-Fa-f]+);") { match, source in
            let nsSource = source as NSString
            let hexRange = match.range(at: 1)
            let hexString = nsSource.substring(with: hexRange)
            if let codePoint = Int(hexString, radix: 16), let scalar = UnicodeScalar(codePoint) {
                return String(scalar)
            }
            return nsSource.substring(with: match.range)
        }

        return decoded
    }
}

#Preview {
    VStack(spacing: 16) {
        ToolCallView(toolCall: .init(
            toolName: "noema.web.retrieve",
            displayName: "Web Search",
            iconName: "globe",
            requestParams: [
                "query": AnyCodable("latest news on AI"),
                "count": AnyCodable(5),
                "safesearch": AnyCodable("moderate")
            ],
            result: """
            [{"title": "Breaking: New AI Model Released", "url": "https://example.com/ai-news", "snippet": "A groundbreaking new AI model has been released today..."},
             {"title": "AI Safety Research Update", "url": "https://example.com/safety", "snippet": "Latest developments in AI safety research show promising results..."}]
            """,
            error: nil
        ))

        ToolCallView(toolCall: .init(
            toolName: "noema.code.analyze",
            displayName: "Code Analysis",
            iconName: "curlybraces",
            requestParams: ["file": AnyCodable("main.swift"), "language": AnyCodable("swift")],
            result: nil,
            error: nil
        ))

        ToolCallView(toolCall: .init(
            toolName: "noema.web.retrieve",
            displayName: "Web Search",
            iconName: "globe",
            requestParams: ["query": AnyCodable("test query")],
            result: nil,
            error: "Network error: Connection failed"
        ))
    }
    .padding()
    .frame(maxWidth: .infinity)
    .background(Color(uiColor: .systemBackground))
    .environmentObject(ChatVM())
}
