import SwiftUI

enum RouterRowPhase: Equatable {
    case deciding
    case resolved
}

struct RouterDecisionRow: View {
    let phase: RouterRowPhase
    let record: RouteDecisionRecord?
    var localModelName: String? = nil
    var onReroute: (() -> Void)? = nil

    @State private var isExpanded = false
    @State private var dotPulsing = false
    @State private var decidingStart = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExpandable: Bool {
        phase == .resolved && record != nil
    }

    /// The router itself failed and a quick heuristic made the call — visually
    /// distinct (gray, "fallback") from the router *choosing* local (green).
    private static let routerFallbackReasonKeys: Set<String> = [
        AutopilotReasonKey.routerTimeout,
        AutopilotReasonKey.routerUnreachable,
        AutopilotReasonKey.routerUnparseable,
        AutopilotReasonKey.routerKeyRejected,
        AutopilotReasonKey.routerProviderError
    ]

    private func isRouterFallback(_ record: RouteDecisionRecord) -> Bool {
        record.reasonKey.map(Self.routerFallbackReasonKeys.contains) ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpandable {
                Button(action: handleRowTap) {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: accessibilitySummary))
                .accessibilityHint(Text("Details"))
            } else {
                rowContent
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: accessibilitySummary))
            }

            if isExpanded, let record {
                inlineDetail(record)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .animation(.easeOut(duration: 0.18), value: phase)
        .onAppear {
            syncPulse()
        }
        .onChangeCompat(of: phase) { oldPhase, newPhase in
            guard oldPhase != newPhase else { return }
            if newPhase == .deciding { isExpanded = false }
            syncPulse()
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .opacity(dotOpacity)

            Text(rowLabel)
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.3)
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
                .layoutPriority(1)

            Text(verbatim: "· \(headline)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppTheme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            trailingStatus

            if isExpandable {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.3))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if phase == .deciding {
            TimelineView(.periodic(from: decidingStart, by: 1)) { context in
                Text(Self.liveDurationString(from: decidingStart, to: context.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.tertiaryText)
                    .opacity(dotPulsing ? 0.45 : 1)
            }
        } else if let record, record.routerLatencyMs >= 50 {
            Text(Self.latencyString(milliseconds: record.routerLatencyMs))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppTheme.tertiaryText)
        }
    }

    private func inlineDetail(_ record: RouteDecisionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow(key: String(localized: "Decision"), value: verdictText(record))
            if record.fellBackToLocal {
                detailRow(key: String(localized: "Result"), value: answerTargetText(record))
            }
            detailRow(key: String(localized: "reason"), value: reasonText(record), lineLimit: 3)
            detailRow(key: String(localized: "confidence"), value: confidenceText(record))
            detailRow(key: String(localized: "Decided By"), value: deciderText(record))

            if let onReroute {
                Button(action: onReroute) {
                    Text(rerouteLabel(record))
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(rerouteTarget(record) == .local ? Color.green : Color.purple)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
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

    private func detailRow(key: String, value: String, lineLimit: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppTheme.tertiaryText)
            Text(verbatim: value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
        }
    }

    /// Phone-a-friend rows have no router — the on-device model itself asked.
    private var isPhoneAFriendRecord: Bool {
        record?.decidedBy == .phoneAFriend
    }

    private var rowLabel: String {
        isPhoneAFriendRecord ? String(localized: "Autopilot") : String(localized: "Escalation")
    }

    private var dotColor: Color {
        switch phase {
        case .deciding:
            return .cyan
        case .resolved:
            guard let record else { return .gray }
            if record.fellBackToLocal { return .orange }
            switch record.target {
            case .cloud:
                return record.escalationIsLocal == true ? .cyan : .purple
            case .local:
                if record.fellBackToLocal { return .orange }
                if record.reasonKey == AutopilotReasonKey.offGrid { return .gray }
                if isRouterFallback(record) { return .gray }
                return .green
            }
        }
    }

    private var dotOpacity: Double {
        if phase == .deciding && reduceMotion { return 0.7 }
        return dotPulsing ? 0.35 : 1
    }

    private var headline: String {
        switch phase {
        case .deciding:
            return String(localized: "deciding…")
        case .resolved:
            guard let record else { return "" }
            if record.fellBackToLocal {
                var text = record.escalationIsLocal == true
                    ? String(localized: "on-device · fallback")
                    : String(localized: "cloud failed · on-device")
                if record.userOverride {
                    text += String(localized: " · your call")
                }
                return text
            }
            var text: String
            switch record.target {
            case .cloud:
                if record.escalationIsLocal == true {
                    let model = record.escalationModelName ?? String(localized: "stronger model")
                    text = String(localized: "handed off · \(model)")
                } else if record.escalationUsesPrivateCloudCompute == true {
                    text = String(localized: "private cloud · Apple PCC")
                } else {
                    let model = record.escalationModelName ?? String(localized: "cloud")
                    text = String(localized: "cloud · \(model)")
                }
            case .local:
                if record.fellBackToLocal {
                    text = String(localized: "cloud failed · on-device")
                } else if record.reasonKey == AutopilotReasonKey.offGrid {
                    text = String(localized: "offline · on-device")
                } else if isRouterFallback(record) {
                    text = String(localized: "on-device · fallback")
                } else if let localModelName {
                    text = String(localized: "on-device · \(localModelName)")
                } else {
                    text = String(localized: "on-device")
                }
            }
            if record.userOverride {
                text += String(localized: " · your call")
            }
            return text
        }
    }

    private func verdictText(_ record: RouteDecisionRecord) -> String {
        switch decisionTarget(record) {
        case .local:
            if let localModelName {
                return String(localized: "on-device · \(localModelName)")
            }
            return String(localized: "on-device")
        case .cloud:
            if record.escalationIsLocal == true {
                let model = record.escalationModelName ?? String(localized: "stronger model")
                return String(localized: "handed off · \(model)")
            }
            if record.escalationUsesPrivateCloudCompute == true {
                return String(localized: "private cloud · Apple PCC")
            }
            let model = record.escalationModelName ?? String(localized: "cloud")
            return String(localized: "cloud · \(model)")
        }
    }

    private func answerTargetText(_ record: RouteDecisionRecord) -> String {
        guard record.answerTarget == .local else { return verdictText(record) }
        if let localModelName {
            return String(localized: "on-device · \(localModelName)")
        }
        return String(localized: "on-device")
    }

    /// Older persisted fallback receipts rewrote the route to local. Infer the
    /// original cloud verdict for display while new receipts preserve it.
    private func decisionTarget(_ record: RouteDecisionRecord) -> AutoRouteTarget {
        if record.fellBackToLocal,
           record.reasonKey == AutopilotReasonKey.cloudFailed {
            return .cloud
        }
        return record.target
    }

    private func reasonText(_ record: RouteDecisionRecord) -> String {
        var key = record.reasonKey
        // Normalize legacy receipts created before route/reason consistency was
        // enforced at decision time.
        if record.target == .cloud,
           key == AutopilotReasonKey.simpleLocal || key == AutopilotReasonKey.localCapable {
            key = AutopilotReasonKey.cloudCapable
        } else if record.target == .local, key == AutopilotReasonKey.cloudCapable {
            key = AutopilotReasonKey.localCapable
        }
        return key.map(AutopilotReasonKey.localized) ?? record.reason
    }

    private func rerouteLabel(_ record: RouteDecisionRecord) -> String {
        if record.fellBackToLocal {
            return record.escalationIsLocal == true || record.escalationUsesPrivateCloudCompute == true
                ? String(localized: "Retry with Stronger Model")
                : String(localized: "Retry Cloud")
        }
        if record.answerTarget == .cloud {
            return String(localized: "Redo On-Device")
        }
        // The escalation side of the redo: a cloud model unless Autopilot is
        // configured to hand off to a stronger local model.
        return AutopilotConfigStore.load().escalationTarget != .remote
            ? String(localized: "Redo with Stronger Model")
            : String(localized: "Redo on Cloud")
    }

    private func rerouteTarget(_ record: RouteDecisionRecord) -> AutoRouteTarget {
        record.answerTarget == .cloud ? .local : .cloud
    }

    private func confidenceText(_ record: RouteDecisionRecord) -> String {
        let band: String
        if record.confidence >= 0.75 {
            band = String(localized: "high")
        } else if record.confidence >= 0.5 {
            band = String(localized: "medium")
        } else {
            band = String(localized: "low")
        }
        return "\(band) (\(String(format: "%.2f", record.confidence)))"
    }

    private func deciderText(_ record: RouteDecisionRecord) -> String {
        switch record.decidedBy {
        case .llm:
            return String(localized: "cloud router") + " · \(record.routerLatencyMs)ms"
        case .afm:
            return String(localized: "Apple Foundation Models") + " · \(record.routerLatencyMs)ms"
        case .pcc:
            return String(localized: "Apple Private Cloud Compute") + " · \(record.routerLatencyMs)ms"
        case .heuristic:
            return String(localized: "quick local check")
        case .forced:
            return String(localized: "policy")
        case .phoneAFriend:
            return String(localized: "on-device model's call")
        }
    }

    private var accessibilitySummary: String {
        switch phase {
        case .deciding:
            return String(localized: "Escalation") + ": " + String(localized: "deciding…")
        case .resolved:
            guard let record else { return String(localized: "Escalation") }
            return String(localized: "Escalation") + ": " + headline + ". " + reasonText(record)
        }
    }

    private func handleRowTap() {
        guard isExpandable else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            isExpanded.toggle()
        }
    }

    private func syncPulse() {
        if phase == .deciding && !reduceMotion {
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

    private static func latencyString(milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1000
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%.0fs", seconds)
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

extension RouterDecisionRow: Equatable {
    /// Streaming re-renders the whole message every token; comparing only the
    /// routing data (plus redo availability, which gates the button) lets
    /// SwiftUI skip this row's body while text streams.
    static func == (lhs: RouterDecisionRow, rhs: RouterDecisionRow) -> Bool {
        lhs.phase == rhs.phase
            && lhs.record == rhs.record
            && lhs.localModelName == rhs.localModelName
            && (lhs.onReroute == nil) == (rhs.onReroute == nil)
    }
}
