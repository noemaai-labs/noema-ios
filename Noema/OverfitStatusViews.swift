import Combine
import NoemaPackages
import os
import SwiftUI

/// `PagedPackageLocator.isPagedInstall` stats the disk. List rows evaluate it
/// on every body pass, so cache the verdict per canonical path — an install
/// flipping paged/non-paged mid-session always goes through a re-download,
/// which produces a new URL or an app restart.
enum OverfitPagedInstallCache {
    private static let verdicts = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    static func isPaged(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        if let cached = verdicts.withLock({ $0[key] }) {
            return cached
        }
        let verdict = PagedPackageLocator.isPagedInstall(url)
        verdicts.withLock { $0[key] = verdict }
        return verdict
    }

    static func invalidate() {
        verdicts.withLock { $0.removeAll() }
    }
}

struct OverfitClassificationChip: View {
    let classification: OverfitFitClassification

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(labelKey)
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.3)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
    }

    private var labelKey: LocalizedStringKey {
        switch classification {
        case .residentInteractive: return "Works here"
        case .pagedInteractive: return "Paged — interactive"
        case .pagedSlow: return "Paged — slow"
        case .offlineOnly: return "Too slow on this device"
        case .relayRecommended: return "Relay recommended"
        case .unsupported: return "Not supported for this model"
        }
    }

    private var tint: Color {
        switch classification {
        case .residentInteractive, .pagedInteractive: return .green
        case .pagedSlow: return .orange
        case .offlineOnly: return .red
        case .relayRecommended: return .teal
        case .unsupported: return .gray
        }
    }
}

/// Compact "PAGED" marker for model list rows; same anatomy as the Autopilot
/// AUTO chip so mixed rows stay visually quiet.
struct OverfitPagedChip: View {
    var body: some View {
        Text("PAGED")
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color.indigo)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.indigo.opacity(0.12))
            )
    }
}

// The canonical OverfitCanaryPhase lives in OverfitCanaryService.swift; the
// UI only contributes presentation.
extension OverfitCanaryPhase {
    var titleKey: LocalizedStringKey {
        switch self {
        case .validating: return "Validating package…"
        case .measuringStorage: return "Measuring storage…"
        case .loadingModel: return "Loading model…"
        case .generating: return "Generating…"
        case .finished: return "Complete"
        }
    }
}

struct OverfitCanaryProgressSheet: View {
    let phase: OverfitCanaryPhase
    var error: String? = nil
    let onDismiss: () -> Void

    private enum StepState {
        case pending
        case active
        case done
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(error == nil ? Color.accentColor : Color.red)
                    .frame(width: 6, height: 6)
                Text(error == nil ? "Run Canary Test" : "Canary failed")
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(error == nil ? Color.primary.opacity(0.6) : Color.red)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.vertical, 7)
            IndustrialHairline()

            VStack(alignment: .leading, spacing: 0) {
                ForEach(OverfitCanaryPhase.allCases, id: \.rawValue) { step in
                    stepRow(step)
                }
            }
            .padding(.vertical, 4)

            if let error {
                IndustrialHairline()
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10)
            }

            IndustrialHairline()
            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(.industrial(error == nil && phase == .finished ? .tinted : .quiet))
            }
            .padding(.top, 12)
        }
        .padding(20)
#if os(macOS)
        .frame(width: 340)
#else
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
#endif
    }

    private func stepRow(_ step: OverfitCanaryPhase) -> some View {
        let state = state(for: step)
        return HStack(spacing: 10) {
            Group {
                switch state {
                case .pending:
                    Circle()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 5, height: 5)
                case .active:
                    ProgressView()
                        .controlSize(.small)
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 16, height: 16)
            Text(step.titleKey)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(textColor(for: state))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func state(for step: OverfitCanaryPhase) -> StepState {
        if error != nil {
            if step.rawValue < phase.rawValue { return .done }
            if step == phase { return .failed }
            return .pending
        }
        if phase == .finished { return .done }
        if step.rawValue < phase.rawValue { return .done }
        if step == phase { return .active }
        return .pending
    }

    private func textColor(for state: StepState) -> Color {
        switch state {
        case .pending: return Color.primary.opacity(0.35)
        case .active: return Color.primary.opacity(0.8)
        case .done: return Color.primary.opacity(0.6)
        case .failed: return .red
        }
    }
}

/// Stored-dialect mono notice row for governor events during paged runs.
/// Display component only; the chat surface decides when one appears.
struct OverfitNoticeRow: View {
    enum Kind {
        case memoryStop
        case thermalReduced
    }

    let kind: Kind
    let showsHairline: Bool

    init(kind: Kind, showsHairline: Bool = true) {
        self.kind = kind
        self.showsHairline = showsHairline
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .padding(.top, 3.5)
                Text(messageKey)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            if showsHairline {
                IndustrialHairline()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var messageKey: LocalizedStringKey {
        switch kind {
        case .memoryStop:
            return "Response stopped early to protect device memory. The partial answer was kept."
        case .thermalReduced:
            return "Streaming was reduced because the device is warm."
        }
    }

    private var tint: Color {
        switch kind {
        case .memoryStop: return .red
        case .thermalReduced: return .orange
        }
    }
}

/// Transient floating host for governor + thermal notices during paged runs.
/// Attached once as a bottom overlay on the conversation scroll area (whose
/// bottom edge already sits above the composer on every platform), it owns all
/// of its state so ChatVM stays untouched. Memory events arrive from
/// OverfitGovernorController via NotificationCenter; thermal transitions come
/// from ProcessInfo and only surface while a paged loopback server is live.
/// Cards auto-dismiss after 8 seconds or on the close affordance.
struct OverfitNoticeHost: View {
    /// One card per kind: a critical followed by an emergency refreshes the
    /// existing memory card's timer instead of stacking a duplicate.
    private struct Notice: Identifiable, Equatable {
        let id: OverfitNoticeRow.Kind
        var timerToken = UUID()
    }

    @State private var notices: [Notice] = []
    /// True after a serious-or-worse thermal notice fired; cleared when the
    /// device cools below serious so the next heat-up can notify again.
    @State private var thermalLatched = false

    private static let dismissDelay: UInt64 = 8_000_000_000

    var body: some View {
        VStack(spacing: 6) {
            ForEach(notices) { notice in
                card(notice)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.2), value: notices)
        .onReceive(mainQueuePublisher(for: .noemaOverfitMemoryCritical)) { _ in
            present(.memoryStop)
        }
        .onReceive(mainQueuePublisher(for: .noemaOverfitMemoryEmergency)) { _ in
            present(.memoryStop)
        }
        .onReceive(mainQueuePublisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalStateDidChange()
        }
    }

    private func card(_ notice: Notice) -> some View {
        HStack(alignment: .top, spacing: 4) {
            OverfitNoticeRow(kind: notice.id, showsHairline: false)
            Button {
                notices.removeAll { $0.id == notice.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .task(id: notice.timerToken) {
            try? await Task.sleep(nanoseconds: Self.dismissDelay)
            guard !Task.isCancelled else { return }
            notices.removeAll { $0.id == notice.id }
        }
    }

    private func present(_ kind: OverfitNoticeRow.Kind) {
        if let idx = notices.firstIndex(where: { $0.id == kind }) {
            notices[idx].timerToken = UUID()
        } else {
            notices.append(Notice(id: kind))
            AccessibilityAnnouncer.announceLocalized(announcementKey(for: kind))
        }
    }

    private func announcementKey(for kind: OverfitNoticeRow.Kind) -> String {
        switch kind {
        case .memoryStop:
            return "Response stopped early to protect device memory. The partial answer was kept."
        case .thermalReduced:
            return "Streaming was reduced because the device is warm."
        }
    }

    private func thermalStateDidChange() {
        let state = ProcessInfo.processInfo.thermalState
        guard state == .serious || state == .critical else {
            thermalLatched = false
            return
        }
        // Latch even when no paged server is live: heating up mid-resident-run
        // must not retroactively fire on a later paged load; only a fresh
        // below-serious → serious transition during a paged run notifies.
        guard !thermalLatched else { return }
        thermalLatched = true
        guard LlamaServerBridge.port() > 0, LlamaServerBridge.pagedStatsJSON() != nil else { return }
        present(.thermalReduced)
    }

    private func mainQueuePublisher(
        for name: Notification.Name
    ) -> AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: name)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
