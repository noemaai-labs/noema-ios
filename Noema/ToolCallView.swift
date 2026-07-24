import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct ToolCallView: View {
    let toolCall: ChatVM.Msg.ToolCall

    @State private var showingDetails = false
    @State private var isExpanded = false
    @State private var dotPulsing = false
#if os(macOS)
    @ObservedObject private var mcpApprovals = MCPApprovalCenter.shared
    @State private var rememberMCPApproval = false
#endif
    private var kind: ToolCallViewSupport.ToolKind {
        ToolCallViewSupport.toolKind(for: toolCall.toolName)
    }

    private var headline: String? {
        ToolCallViewSupport.resultHeadline(for: toolCall)
    }

    private var hasInlineDetail: Bool {
        !toolCall.requestParams.isEmpty
            || toolCall.result?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || toolCall.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var statusTitleKey: String {
        switch toolCall.phase {
        case .requesting:
            return "Tool requested"
        case .awaitingApproval:
            return "Awaiting approval"
        case .executing, .running:
            return "Tool running"
        case .completed:
            return "Tool completed"
        case .failed:
            return "Tool failed"
        }
    }

    private var outcomePreview: (text: String, isError: Bool)? {
        if let error = toolCall.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return (Self.compactPreview(error), true)
        }
        if let result = toolCall.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
            return (Self.compactPreview(ToolCallViewSupport.formatRawResult(result)), false)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: handleRowTap) {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rowAccessibilityLabel)
            .accessibilityHint(Text("Details"))

#if os(macOS)
            if let request = matchingApprovalRequest {
                inlineApproval(request)
            } else if isExpanded {
                inlineDetail
            }
#else
            if isExpanded { inlineDetail }
#endif

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .onAppear {
            syncPulse(to: toolCall.phase)
        }
        .onChangeCompat(of: toolCall.phase) { oldPhase, newPhase in
            guard oldPhase != newPhase else { return }
            syncPulse(to: newPhase)
        }
        .toolCallDetailPresentation(isPresented: $showingDetails, toolCall: toolCall)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ToolCallViewSupport.dotGradient(for: kind))
                .frame(width: 6, height: 6)
                .opacity(dotPulsing ? 0.35 : 1)

            Text(toolCall.displayName)
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.3)
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
                .layoutPriority(1)

            if let headline, !headline.isEmpty {
                Text(verbatim: "· \(headline)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            trailingStatus

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.3))
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if toolCall.phase == .failed {
            Text("Failed")
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
        } else if toolCall.phase.isInFlight {
            TimelineView(.periodic(from: toolCall.timestamp, by: 1)) { context in
                Text(Self.liveDurationString(from: toolCall.timestamp, to: context.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.tertiaryText)
                    .opacity(dotPulsing ? 0.45 : 1)
            }
        } else if let completedAt = toolCall.completedAt,
                  completedAt.timeIntervalSince(toolCall.timestamp) >= 0.05 {
            Text(Self.durationString(from: toolCall.timestamp, to: completedAt))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppTheme.tertiaryText)
        }
    }

    private var inlineDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            let entries = ToolCallViewSupport.parameterSummaryEntries(
                from: toolCall.requestParams,
                maxEntries: 4,
                maxValueLength: 80
            )
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: entry.key)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.tertiaryText)
                    Text(verbatim: entry.value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if let outcomePreview {
                Text(verbatim: outcomePreview.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(outcomePreview.isError ? Color.orange : AppTheme.secondaryText)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }

            Button {
                showingDetails = true
            } label: {
                HStack(spacing: 3) {
                    Text("Details")
                        .textCase(.uppercase)
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.leading, 14)
        .padding(.bottom, 8)
    }

#if os(macOS)
    private var matchingApprovalRequest: MCPApprovalRequest? {
        guard toolCall.phase == .awaitingApproval,
              let request = mcpApprovals.request,
              request.tool.alias == toolCall.toolName || toolCall.toolName == MCPCallTool.toolName else { return nil }
        return request
    }

    private func inlineApproval(_ request: MCPApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey("Allow this MCP tool to run?"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                Text(verbatim: "\(request.serverName) · \(request.tool.title ?? request.tool.originalName)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppTheme.tertiaryText)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Toggle(LocalizedStringKey("Don't ask again"), isOn: $rememberMCPApproval)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer(minLength: 8)
                Button(LocalizedStringKey("Deny"), role: .destructive) {
                    mcpApprovals.answer(.deny)
                }
                .buttonStyle(.borderless)
                Button(LocalizedStringKey("Allow")) {
                    mcpApprovals.answer(rememberMCPApproval ? .alwaysAllow : .allowOnce)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.leading, 14)
        .padding(.bottom, 8)
    }
#endif

    private var rowAccessibilityLabel: Text {
        var label = Text(toolCall.displayName) + Text(verbatim: ", ") + Text(LocalizedStringKey(statusTitleKey))
        if let headline, !headline.isEmpty {
            label = label + Text(verbatim: ", \(headline)")
        }
        return label
    }

    private func handleRowTap() {
        if hasInlineDetail {
            withAnimation(.easeOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } else {
            showingDetails = true
        }
    }

    private func syncPulse(to phase: ChatVM.Msg.ToolCallPhase) {
        if phase.isInFlight {
            guard !dotPulsing else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                dotPulsing = true
            }
        } else if dotPulsing {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dotPulsing = false
            }
        }
    }

    private static func compactPreview(_ text: String) -> String {
        let condensed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard condensed.count > 180 else { return condensed }
        return String(condensed.prefix(177)) + "..."
    }

    private static func durationString(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let whole = Int(seconds.rounded())
        return String(format: "%dm %ds", whole / 60, whole % 60)
    }

    private static func liveDurationString(from start: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let whole = Int(seconds.rounded())
        return String(format: "%dm %ds", whole / 60, whole % 60)
    }
}

extension ToolCallView: Equatable {
    /// When the parent re-renders (e.g. every streaming token in the same turn),
    /// SwiftUI uses this to skip re-evaluating `body` for tool calls whose data
    /// hasn't changed.
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
#if os(macOS)
    @State private var mcpSound: NSSound?
#endif

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
                Image(systemName: toolCall.phase == .awaitingApproval ? "checkmark.shield" : toolCall.phase == .requesting ? "clock.fill" : "play.circle.fill")
                    .font(.caption)
                    .foregroundColor(secondaryPillForegroundColor)
                Text(toolCall.phase == .awaitingApproval ? "Awaiting Approval" : toolCall.phase == .requesting ? "Requesting Tool" : "Running Tool")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
            }

            Text(toolCall.phase == .awaitingApproval ? "Review the MCP tool request to continue." : toolCall.phase == .requesting ? "The model is still composing the tool request." : "Waiting for tool response…")
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()
        }
    }

    @ViewBuilder
    private func formattedResultView(for result: String) -> some View {
        if let dryRun = ToolCallViewSupport.parseDryRunResult(from: result) {
            dryRunResultView(dryRun)
        } else if toolCall.toolName.hasPrefix("mcp_") {
            mcpResultView(for: result)
        } else {
            switch ToolCallViewSupport.toolKind(for: toolCall.toolName) {
            case .python:
                pythonResultView(for: result)
            case .chart:
                chartResultView(for: result)
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
            case .datasetSearch:
                datasetResultView(for: result)
            case .pdf:
                pdfResultView(for: result)
            case .calendar:
                calendarResultView(for: result)
            case .generic:
                unavailableFormattedResultView
            }
        }
    }

    @ViewBuilder
    private func mcpResultView(for result: String) -> some View {
        if let data = result.data(using: .utf8),
           let payload = try? JSONDecoder().decode(JSONValue.self, from: data),
           let object = payload.objectValue {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.blue)
                    Text(verbatim: object["serverID"]?.stringValue ?? "MCP")
                        .font(.caption.weight(.semibold))
                    if let tool = object["tool"]?.stringValue {
                        Text(verbatim: tool)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if object["isError"]?.boolValue == true {
                        Label(LocalizedStringKey("Error"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }

                ForEach(Array((object["renderContent"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, item in
                    mcpContentView(item)
                }

                if let structured = object["structuredContent"] {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(LocalizedStringKey("Structured Data"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: structured.prettyPrinted)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let task = object["task"] {
                    Label {
                        Text(verbatim: task.prettyPrinted)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .modifier(ResultBoxStyle(backgroundColor: sectionBackgroundColor, borderColor: sectionBorderColor))
        } else {
            unavailableFormattedResultView
        }
    }

    @ViewBuilder
    private func mcpContentView(_ item: JSONValue) -> some View {
        let type = item["type"]?.stringValue ?? "unknown"
        switch type {
        case "text":
            if let text = item["text"]?.stringValue {
                Text(verbatim: text).font(.subheadline).textSelection(.enabled)
            }
        case "structured":
            if let value = item["value"] {
                Text(verbatim: value.prettyPrinted).font(.caption.monospaced()).textSelection(.enabled)
            }
        case "image":
#if os(macOS)
            if let encoded = item["data"]?.stringValue,
               let data = Data(base64Encoded: encoded),
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
#endif
        case "audio":
#if os(macOS)
            if let encoded = item["data"]?.stringValue, let data = Data(base64Encoded: encoded) {
                Button {
                    mcpSound?.stop()
                    mcpSound = NSSound(data: data)
                    mcpSound?.play()
                } label: {
                    Label(LocalizedStringKey("Play Audio"), systemImage: "waveform.circle.fill")
                }
                .buttonStyle(.bordered)
            }
#endif
        case "embeddedResource":
            VStack(alignment: .leading, spacing: 4) {
                Label(LocalizedStringKey("Embedded Resource"), systemImage: "doc.text")
                    .font(.caption.weight(.semibold))
                if let uri = item["uri"]?.stringValue { Text(verbatim: uri).font(.caption.monospaced()).foregroundStyle(.secondary) }
                if let text = item["text"]?.stringValue { Text(verbatim: text).font(.subheadline).textSelection(.enabled) }
            }
        case "resourceLink":
            if let uri = item["uri"]?.stringValue, let url = URL(string: uri) {
                Link(destination: url) {
                    Label(item["name"]?.stringValue ?? uri, systemImage: "link")
                }
            }
        default:
            Text(verbatim: item.prettyPrinted).font(.caption.monospaced()).textSelection(.enabled)
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

    @ViewBuilder
    private func datasetResultView(for result: String) -> some View {
        if let payload = ToolCallViewSupport.parseDatasetSearchResult(from: result) {
            VStack(alignment: .leading, spacing: 10) {
                if !payload.datasetsSearched.isEmpty {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Searched %d dataset(s): %@"),
                            payload.datasetsSearched.count,
                            payload.datasetsSearched.joined(separator: ", ")
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if payload.citations.isEmpty {
                    Text(payload.message ?? String(localized: "No relevant passages found."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(ResultBoxStyle(backgroundColor: sectionBackgroundColor, borderColor: sectionBorderColor))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(payload.citations.enumerated()), id: \.offset) { index, citation in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 6) {
                                        Text("\(index + 1).")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(secondaryPillForegroundColor)
                                        if let source = citation.source, !source.isEmpty {
                                            Text(source)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(neutralPillForegroundColor)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(neutralPillBackgroundColor)
                                                .clipShape(Capsule())
                                        }
                                        Spacer(minLength: 4)
                                        if let score = citation.score {
                                            Text(String(format: "%.0f%%", max(0, min(1, score)) * 100))
                                                .font(.caption2.weight(.semibold).monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(citation.text)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if payload.datasetsSearched.count > 1,
                                       let dataset = citation.dataset, !dataset.isEmpty {
                                        Text(dataset)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
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
                    .modifier(ResultBoxStyle(backgroundColor: sectionBackgroundColor, borderColor: sectionBorderColor))
                }
            }
        } else {
            rawResultView(for: result)
        }
    }

    @ViewBuilder
    private func pdfResultView(for result: String) -> some View {
        switch ToolCallViewSupport.parsePDFResult(from: result) {
        case .info(let docs)?:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(docs.enumerated()), id: \.offset) { _, doc in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(doc.title?.isEmpty == false ? doc.title! : doc.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                Text(String.localizedStringWithFormat(String(localized: "%d page(s)"), doc.pageCount))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !doc.outline.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(doc.outline.prefix(40).enumerated()), id: \.offset) { _, entry in
                                        HStack(spacing: 6) {
                                            Text(entry.title)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            Spacer(minLength: 4)
                                            if let page = entry.page {
                                                Text("\(page)")
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        .padding(.leading, CGFloat(min(entry.depth, 4)) * 12)
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
                .padding(.vertical, 4)
            }
            .modifier(ResultBoxStyle(backgroundColor: sectionBackgroundColor, borderColor: sectionBorderColor))
        case .read(let document, let pageCount, let pages)?:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(document)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(String.localizedStringWithFormat(String(localized: "%d page(s)"), pageCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String.localizedStringWithFormat(String(localized: "Page %d"), page.page))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(page.text)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .modifier(ResultBoxStyle(backgroundColor: sectionBackgroundColor, borderColor: sectionBorderColor))
            }
        case .none:
            rawResultView(for: result)
        }
    }

    @ViewBuilder
    private func calendarResultView(for result: String) -> some View {
        switch ToolCallViewSupport.parseCalendarResult(from: result) {
        case .events(let events)?:
            if events.isEmpty {
                calendarStatusView(
                    icon: "calendar",
                    tint: .gray,
                    title: String(localized: "No events"),
                    detail: String(localized: "Nothing scheduled in that range.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title.isEmpty ? String(localized: "Untitled event") : event.title)
                                    .font(.subheadline.weight(.semibold))
                                HStack(spacing: 6) {
                                    Image(systemName: "clock")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(ToolCallViewSupport.formatCalendarRange(start: event.start, end: event.end, allDay: event.allDay))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let location = event.location, !location.isEmpty {
                                    HStack(spacing: 6) {
                                        Image(systemName: "mappin.and.ellipse")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(location)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
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
                    .padding(.vertical, 4)
                }
                .modifier(ResultBoxStyle(backgroundColor: sectionBackgroundColor, borderColor: sectionBorderColor))
            }
        case .saved?:
            calendarStatusView(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: String(localized: "Event added"),
                detail: String(localized: "Saved to your calendar.")
            )
        case .declined?:
            calendarStatusView(
                icon: "xmark.circle.fill",
                tint: .gray,
                title: String(localized: "Not added"),
                detail: String(localized: "You cancelled — nothing was saved.")
            )
        case .error(let message)?:
            calendarStatusView(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: String(localized: "Calendar unavailable"),
                detail: message
            )
        case .none:
            rawResultView(for: result)
        }
    }

    private func calendarStatusView(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ResultBoxStyle(backgroundColor: sectionBackgroundColor, borderColor: sectionBorderColor))
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
    private func chartResultView(for result: String) -> some View {
        if let chart = ToolCallViewSupport.parseChartResult(from: result), let base64 = chart.imageBase64 {
            VStack(alignment: .leading, spacing: 8) {
                if let title = chart.title, !title.isEmpty {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                pythonImageArtifactView(PythonExecutionArtifact(
                    relativePath: "chart.png",
                    filename: "chart.png",
                    kind: "image",
                    mimeType: "image/png",
                    sizeBytes: 0,
                    preview: nil,
                    base64Data: base64
                ))
            }
        } else {
            Text(LocalizedStringKey("Couldn't render the chart."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                    .accessibilityLabel(Text(artifactImageAccessibilityLabel(artifact)))
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
                    .accessibilityLabel(Text(artifactImageAccessibilityLabel(artifact)))
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

    private func artifactImageAccessibilityLabel(_ artifact: PythonExecutionArtifact) -> String {
        artifact.filename.isEmpty ? String(localized: "Generated image") : artifact.filename
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

/// Renders a rendered chart image inline in a message bubble (below the assistant
/// text), so a `noema.chart.render` result is visible without expanding the tool
/// card. Produces nothing if the result has no image.
struct InlineToolChartView: View {
    let result: String

    private func chartAccessibilityLabel(title: String?) -> String {
        if let title, !title.isEmpty { return title }
        return String(localized: "Chart")
    }

    var body: some View {
        if let chart = ToolCallViewSupport.parseChartResult(from: result),
           let base64 = chart.imageBase64,
           let image = ToolCallViewSupport.platformImage(fromBase64: base64) {
            VStack(alignment: .leading, spacing: 6) {
                if let title = chart.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                #if os(macOS)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(Text(chartAccessibilityLabel(title: chart.title)))
                #elseif canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(Text(chartAccessibilityLabel(title: chart.title)))
                #endif
            }
            .padding(.vertical, 2)
        }
    }
}

enum ToolCallViewSupport {
    enum ToolKind: Equatable {
        case webSearch
        case python
        case memory
        case calculator
        case unitConverter
        case chart
        case datasetSearch
        case pdf
        case calendar
        case generic
    }

    enum ResultDisplayMode: String, CaseIterable, Hashable {
        case formatted
        case raw

        var title: String {
            switch self {
            case .formatted: return String(localized: "Formatted")
            case .raw: return String(localized: "Raw")
            }
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
        // Match dataset search before the generic "search" → webSearch rule below, since
        // "noema.rag.search" also contains "search".
        if normalizedToolName.contains("noema.rag.search")
            || normalizedToolName.contains("rag")
            || normalizedToolName.contains("dataset") {
            return .datasetSearch
        }
        if normalizedToolName.contains("noema.pdf.read")
            || normalizedToolName.contains("pdf") {
            return .pdf
        }
        if normalizedToolName.contains("noema.calendar") {
            return .calendar
        }
        if normalizedToolName.contains("noema.chart.render")
            || normalizedToolName.contains("chart") {
            return .chart
        }
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

    /// Identity dot for activity rows — same visual language as the Stored
    /// page's per-format gradient dots.
    static func dotGradient(for kind: ToolKind) -> LinearGradient {
        let colors: [Color]
        switch kind {
        case .webSearch:
            colors = [.blue, .cyan]
        case .datasetSearch:
            colors = [.green, .teal]
        case .pdf:
            colors = [.red, .orange]
        case .chart:
            colors = [.pink, .purple]
        case .python:
            colors = [.yellow, .orange]
        case .memory:
            colors = [.indigo, .purple]
        case .calendar:
            colors = [.red, .pink]
        case .calculator, .unitConverter, .generic:
            colors = [Color.gray, Color.gray.opacity(0.55)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// One-line summary shown after the tool name in the activity row: the key
    /// request parameter while the call is in flight, the most informative piece
    /// of the result once it completes, or the error when it fails.
    static func resultHeadline(for call: ChatVM.Msg.ToolCall) -> String? {
        if call.phase == .failed {
            if let error = call.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                return singleLine(error)
            }
            return requestHeadline(for: call)
        }
        guard call.phase == .completed,
              let result = call.result?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else {
            return requestHeadline(for: call)
        }

        let kind = toolKind(for: call.toolName)
        switch kind {
        case .webSearch:
            if let first = parseWebResults(from: result).first {
                return singleLine(first.displayTitle)
            }
        case .datasetSearch:
            if let payload = parseDatasetSearchResult(from: result) {
                if let first = payload.citations.first {
                    return singleLine(first.source ?? first.dataset ?? first.text)
                }
                if let message = payload.message {
                    return singleLine(message)
                }
            }
        case .calculator, .unitConverter:
            if let deterministic = parseDeterministicResult(from: result) {
                if let error = deterministic.error, !error.isEmpty {
                    return singleLine(error)
                }
                let value = deterministic.displayResult
                if kind == .calculator, let expression = deterministic.expression, !expression.isEmpty {
                    return singleLine("\(expression) = \(value)")
                }
                if let input = deterministic.value, let fromUnit = deterministic.fromUnit {
                    return singleLine("\(input) \(fromUnit) → \(value)")
                }
                if !value.isEmpty {
                    return singleLine(value)
                }
            }
        case .chart:
            if let chart = parseChartResult(from: result), let title = chart.title, !title.isEmpty {
                return singleLine(title)
            }
        case .pdf:
            if let payload = parsePDFResult(from: result) {
                switch payload {
                case .info(let docs):
                    if let doc = docs.first, !doc.name.isEmpty {
                        return singleLine(doc.name)
                    }
                case .read(let document, _, let pages):
                    let name = document.isEmpty ? nil : document
                    if let firstPage = pages.first?.page, let lastPage = pages.last?.page {
                        let range = firstPage == lastPage ? "p.\(firstPage)" : "p.\(firstPage)–\(lastPage)"
                        return singleLine(([name, range].compactMap { $0 }).joined(separator: " · "))
                    }
                    if let name {
                        return singleLine(name)
                    }
                }
            }
        case .calendar:
            if let payload = parseCalendarResult(from: result) {
                switch payload {
                case .events(let events):
                    if let first = events.first, !first.title.isEmpty {
                        return singleLine(first.title)
                    }
                case .saved:
                    return String(localized: "Saved")
                case .declined:
                    return String(localized: "Declined")
                case .error(let message):
                    return singleLine(message)
                }
            }
        case .python:
            if let payload = parsePythonResult(from: result) {
                if let line = firstLine(payload.stdout) ?? firstLine(payload.stderr) ?? payload.error {
                    return singleLine(line)
                }
            }
        case .memory, .generic:
            break
        }
        return requestHeadline(for: call) ?? singleLine(formatRawResult(result))
    }

    /// Headline drawn from the request parameters — the query, expression, or
    /// document the tool was asked about.
    static func requestHeadline(for call: ChatVM.Msg.ToolCall) -> String? {
        let params = call.requestParams
        func value(_ keys: String...) -> String? {
            for key in keys {
                guard let raw = params[key]?.value else { continue }
                let text = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && text != "nil" { return text }
            }
            return nil
        }

        var candidate: String?
        switch toolKind(for: call.toolName) {
        case .webSearch, .datasetSearch, .memory:
            candidate = value("query", "q", "text")
        case .calculator:
            candidate = value("expression")
        case .unitConverter:
            if let amount = value("value"), let fromUnit = value("from_unit"), let toUnit = value("to_unit") {
                candidate = "\(amount) \(fromUnit) → \(toUnit)"
            } else {
                candidate = value("value", "expression")
            }
        case .pdf:
            candidate = value("grep", "document", "pages")
        case .chart:
            candidate = value("title", "type")
        case .calendar:
            candidate = value("query", "title")
        case .python:
            candidate = firstLine(value("code") ?? "")
        case .generic:
            candidate = nil
        }
        if let candidate, !candidate.isEmpty {
            return singleLine(candidate)
        }
        if let firstKey = params.keys.sorted().first, let raw = params[firstKey]?.value {
            let text = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && text != "nil" { return singleLine(text) }
        }
        return nil
    }

    private static func singleLine(_ text: String, limit: Int = 80) -> String {
        let condensed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard condensed.count > limit else { return condensed }
        return String(condensed.prefix(limit - 1)) + "…"
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return line
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
        case .chart:
            return parseChartResult(from: result) != nil
        case .memory:
            return parseMemoryResult(from: result) != nil
        case .webSearch:
            return !parseWebResults(from: result).isEmpty
        case .calculator, .unitConverter:
            return parseDeterministicResult(from: result) != nil
        case .datasetSearch:
            return parseDatasetSearchResult(from: result) != nil
        case .pdf:
            return parsePDFResult(from: result) != nil
        case .calendar:
            return parseCalendarResult(from: result) != nil
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

    struct ChartResultPayload {
        let title: String?
        let imageBase64: String?
    }

    static func parseChartResult(from result: String) -> ChartResultPayload? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = object["title"] as? String
        let image = object["image_base64"] as? String
        guard image != nil || title != nil else { return nil }
        return ChartResultPayload(title: title, imageBase64: image)
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

    struct DatasetSearchResultPayload: Equatable {
        struct Citation: Equatable {
            let text: String
            let source: String?
            let score: Double?
            let dataset: String?
        }
        let citations: [Citation]
        let datasetsSearched: [String]
        let message: String?
    }

    static func parseDatasetSearchResult(from result: String) -> DatasetSearchResultPayload? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard object["results"] is [[String: Any]] || object["datasets_searched"] is [Any] else {
            return nil
        }
        let citations = (object["results"] as? [[String: Any]] ?? []).compactMap { item -> DatasetSearchResultPayload.Citation? in
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return .init(
                text: text,
                source: item["source"] as? String,
                score: (item["score"] as? NSNumber)?.doubleValue,
                dataset: item["dataset"] as? String
            )
        }
        let datasetsSearched = (object["datasets_searched"] as? [String]) ?? []
        let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DatasetSearchResultPayload(
            citations: citations,
            datasetsSearched: datasetsSearched,
            message: (message?.isEmpty == false) ? message : nil
        )
    }

    enum PDFToolResultPayload: Equatable {
        case info([Doc])
        case read(document: String, pageCount: Int, pages: [Page])
        struct Doc: Equatable {
            let name: String
            let pageCount: Int
            let title: String?
            let outline: [Outline]
        }
        struct Outline: Equatable { let title: String; let page: Int?; let depth: Int }
        struct Page: Equatable { let page: Int; let text: String }
    }

    static func parsePDFResult(from result: String) -> PDFToolResultPayload? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let docs = object["documents"] as? [[String: Any]] {
            let parsed = docs.map { doc in
                PDFToolResultPayload.Doc(
                    name: doc["name"] as? String ?? "",
                    pageCount: (doc["pageCount"] as? NSNumber)?.intValue ?? 0,
                    title: doc["title"] as? String,
                    outline: (doc["outline"] as? [[String: Any]] ?? []).map {
                        PDFToolResultPayload.Outline(
                            title: $0["title"] as? String ?? "",
                            page: ($0["page"] as? NSNumber)?.intValue,
                            depth: ($0["depth"] as? NSNumber)?.intValue ?? 0
                        )
                    }
                )
            }
            return .info(parsed)
        }
        if let pages = object["pages"] as? [[String: Any]] {
            let parsed = pages.map {
                PDFToolResultPayload.Page(page: ($0["page"] as? NSNumber)?.intValue ?? 0, text: $0["text"] as? String ?? "")
            }
            return .read(
                document: object["document"] as? String ?? "",
                pageCount: (object["pageCount"] as? NSNumber)?.intValue ?? 0,
                pages: parsed
            )
        }
        return nil
    }

    enum CalendarToolResultPayload: Equatable {
        case events([Event])
        case saved
        case declined
        case error(String)
        struct Event: Equatable {
            let title: String
            let start: String
            let end: String
            let location: String?
            let calendar: String?
            let allDay: Bool
        }
    }

    static func parseCalendarResult(from result: String) -> CalendarToolResultPayload? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let events = object["events"] as? [[String: Any]] {
            let parsed = events.map { event in
                CalendarToolResultPayload.Event(
                    title: event["title"] as? String ?? "",
                    start: event["start"] as? String ?? "",
                    end: event["end"] as? String ?? "",
                    location: event["location"] as? String,
                    calendar: event["calendar"] as? String,
                    allDay: (event["all_day"] as? Bool) ?? false
                )
            }
            return .events(parsed)
        }
        if let ok = object["ok"] as? Bool {
            if ok { return .saved }
            let error = object["error"] as? String
            if error == "user_declined" { return .declined }
            if let error, !error.isEmpty { return .error(error) }
            return nil
        }
        return nil
    }

    private static func parseISODate(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: iso)
    }

    static func formatCalendarRange(start: String, end: String, allDay: Bool) -> String {
        guard let startDate = parseISODate(start) else { return start }
        let dayFormatter = DateFormatter()
        if allDay {
            dayFormatter.dateStyle = .medium
            dayFormatter.timeStyle = .none
            return dayFormatter.string(from: startDate)
        }
        dayFormatter.dateStyle = .medium
        dayFormatter.timeStyle = .short
        let startText = dayFormatter.string(from: startDate)
        guard let endDate = parseISODate(end) else { return startText }
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return "\(startText) – \(timeFormatter.string(from: endDate))"
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
            let candidateKeys = ["sources", "results", "items", "data", "hits", "entries"]
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
