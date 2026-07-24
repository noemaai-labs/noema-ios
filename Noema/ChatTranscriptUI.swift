import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(UIKit) || os(macOS)
enum TranscriptSaveFeedback: Equatable {
    case saving
    case saved(String?)
    case failed(String)

    var message: String? {
        switch self {
        case .saving:
            return String(localized: "Saving...")
        case .saved(let datasetName):
            if let datasetName, !datasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String.localizedStringWithFormat(String(localized: "Saved to %@"), datasetName)
            }
            return String(localized: "Saved to Stored")
        case .failed(let message):
            return message
        }
    }

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }

    var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }
}

enum TranscriptQuickAction: String, CaseIterable, Identifiable {
    case summarize
    case ask
    case actionItems
    case studyNotes
    case decisions
    case timeline
    case followUp

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .summarize: return "Summarize"
        case .ask: return "Ask"
        case .actionItems: return "Extract action items"
        case .studyNotes: return "Create study notes"
        case .decisions: return "Find decisions"
        case .timeline: return "Make timeline"
        case .followUp: return "Draft follow-up"
        }
    }

    var iconName: String {
        switch self {
        case .summarize: return "text.bubble"
        case .ask: return "questionmark.bubble"
        case .actionItems: return "checklist"
        case .studyNotes: return "book"
        case .decisions: return "checkmark.seal"
        case .timeline: return "list.bullet.rectangle"
        case .followUp: return "envelope"
        }
    }

    func prompt(for title: String) -> String {
        switch self {
        case .summarize:
            return String(localized: "Summarize this transcript.")
        case .ask:
            return String.localizedStringWithFormat(String(localized: "Ask about %@: "), title)
        case .actionItems:
            return String(localized: "Extract action items from this transcript.")
        case .studyNotes:
            return String(localized: "Create study notes from this transcript.")
        case .decisions:
            return String(localized: "Find the decisions in this transcript.")
        case .timeline:
            return String(localized: "Make a timeline from this transcript.")
        case .followUp:
            return String(localized: "Draft a follow-up based on this transcript.")
        }
    }
}

enum ASRRecoveryAction: String, CaseIterable, Identifiable {
    case openSettings
    case chooseLocale
    case downloadWhisperModel
    case configureEndpoint
    case retry

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .openSettings: return "Open ASR Settings"
        case .chooseLocale: return "Choose Locale"
        case .downloadWhisperModel: return "Download Whisper Model"
        case .configureEndpoint: return "Configure Endpoint"
        case .retry: return "Retry"
        }
    }

    var iconName: String {
        switch self {
        case .openSettings: return "gearshape"
        case .chooseLocale: return "globe"
        case .downloadWhisperModel: return "arrow.down.circle"
        case .configureEndpoint: return "network"
        case .retry: return "arrow.clockwise"
        }
    }

    static func actions(
        for message: String,
        includeRetry: Bool,
        includeRemoteEndpoint: Bool = false
    ) -> [ASRRecoveryAction] {
        let lower = message.lowercased()
        var actions: [ASRRecoveryAction] = []
        if lower.contains("locale") || lower.contains("on-device") || lower.contains("recognition") {
            actions.append(.chooseLocale)
        }
        if lower.contains("whisper") || lower.contains("model") || lower.contains("download") {
            actions.append(.downloadWhisperModel)
        }
        if includeRemoteEndpoint,
           lower.contains("endpoint") || lower.contains("remote") || lower.contains("audio-language") || lower.contains("upload") {
            actions.append(.configureEndpoint)
        }
        if lower.contains("permission") || lower.contains("unavailable") || actions.isEmpty {
            actions.append(.openSettings)
        }
        if includeRetry {
            actions.append(.retry)
        }
        return actions.reduce(into: []) { unique, action in
            if !unique.contains(action) { unique.append(action) }
        }
    }
}

struct TranscriptReviewSheet: View {
    let attachment: ChatMediaAttachment
    let allowsEditing: Bool
    let onSaveEdits: (String, String) -> Void
    let onQuickAction: (TranscriptQuickAction) -> Void
    let onSaveNewDataset: () -> Void
    let onSaveExistingDataset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var transcriptText: String
    @State private var showsSegments = false

    init(
        attachment: ChatMediaAttachment,
        allowsEditing: Bool,
        onSaveEdits: @escaping (String, String) -> Void,
        onQuickAction: @escaping (TranscriptQuickAction) -> Void,
        onSaveNewDataset: @escaping () -> Void,
        onSaveExistingDataset: @escaping () -> Void
    ) {
        self.attachment = attachment
        self.allowsEditing = allowsEditing
        self.onSaveEdits = onSaveEdits
        self.onQuickAction = onQuickAction
        self.onSaveNewDataset = onSaveNewDataset
        self.onSaveExistingDataset = onSaveExistingDataset
        let artifact = attachment.transcript
        _title = State(initialValue: artifact?.displaySourceName ?? attachment.originalFilename)
        _transcriptText = State(initialValue: artifact?.effectiveTranscriptText ?? "")
    }

    private var visibleSegmentRows: [TranscriptReviewDisplayRow] {
        guard let artifact = attachment.transcript else {
            return TranscriptReviewDisplayRow.rows(from: transcriptText)
        }
        if !artifact.segments.isEmpty {
            return artifact.reviewSegmentRows
        }
        return TranscriptReviewDisplayRow.rows(from: transcriptText)
    }

    private var visibleTranscriptText: String {
        if showsSegments {
            return visibleSegmentRows.map { "[\($0.label)] \($0.text)" }.joined(separator: "\n")
        }
        return transcriptText
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey("Source title"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    TextField(LocalizedStringKey("Source title"), text: $title)
                        .font(.title3)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 54)
                        .background(transcriptFieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: transcriptFieldRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: transcriptFieldRadius, style: .continuous)
                                .stroke(transcriptBorderColor, lineWidth: 1)
                        )
                        .disabled(!allowsEditing)
                }

                if let artifact = attachment.transcript {
                    Text(artifact.provenanceSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker(LocalizedStringKey("Transcript view"), selection: $showsSegments) {
                    Text(LocalizedStringKey("Full Text")).tag(false)
                    Text(LocalizedStringKey("Segments")).tag(true)
                }
                #if os(macOS)
                .pickerStyle(.menu)
                .fixedSize()
                #else
                .pickerStyle(.segmented)
                #endif

                if showsSegments {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(visibleSegmentRows.enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(row.label)
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 54, alignment: .leading)
                                    Text(row.text)
                                        .font(.body)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .frame(minHeight: 320)
                    .background(transcriptFieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: transcriptAreaRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: transcriptAreaRadius, style: .continuous)
                            .stroke(transcriptBorderColor, lineWidth: 1)
                    )
                } else {
                    TextEditor(text: $transcriptText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 320)
                        .background(transcriptFieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: transcriptAreaRadius, style: .continuous))
                        .disabled(!allowsEditing)
                        .overlay(
                            RoundedRectangle(cornerRadius: transcriptAreaRadius, style: .continuous)
                                .stroke(transcriptBorderColor, lineWidth: 1)
                        )
                }

                #if os(macOS)
                HStack(spacing: 8) {
                    Button {
                        copyTranscriptToPasteboard(visibleTranscriptText)
                    } label: {
                        Label(LocalizedStringKey("Copy"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.industrial(.quiet))

                    Menu {
                        Button {
                            onSaveNewDataset()
                            dismiss()
                        } label: {
                            Label(LocalizedStringKey("Save to Stored"), systemImage: "tray.and.arrow.down")
                        }
                        Button {
                            onSaveExistingDataset()
                            dismiss()
                        } label: {
                            Label(LocalizedStringKey("Save to existing dataset"), systemImage: "folder.badge.plus")
                        }
                    } label: {
                        MacTranscriptMenuLabel(titleKey: "Save", systemImage: "square.and.arrow.down")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Menu {
                        ForEach(TranscriptQuickAction.allCases) { action in
                            Button {
                                onQuickAction(action)
                                dismiss()
                            } label: {
                                Label(action.titleKey, systemImage: action.iconName)
                            }
                        }
                    } label: {
                        MacTranscriptMenuLabel(titleKey: "Actions", systemImage: "sparkles")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    if allowsEditing {
                        Button {
                            onSaveEdits(title, transcriptText)
                            dismiss()
                        } label: {
                            Label(LocalizedStringKey("Done"), systemImage: "checkmark")
                        }
                        .buttonStyle(.industrial(.prominent))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                #else
                HStack(spacing: 8) {
                    Button {
                        copyTranscriptToPasteboard(visibleTranscriptText)
                    } label: {
                        transcriptActionLabel("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)

                    Menu {
                        Button {
                            onSaveNewDataset()
                            dismiss()
                        } label: {
                            Label(LocalizedStringKey("Save to Stored"), systemImage: "tray.and.arrow.down")
                        }
                        Button {
                            onSaveExistingDataset()
                            dismiss()
                        } label: {
                            Label(LocalizedStringKey("Save to existing dataset"), systemImage: "folder.badge.plus")
                        }
                    } label: {
                        transcriptActionLabel("Save", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)

                    Menu {
                        ForEach(TranscriptQuickAction.allCases) { action in
                            Button {
                                onQuickAction(action)
                                dismiss()
                            } label: {
                                Label(action.titleKey, systemImage: action.iconName)
                            }
                        }
                    } label: {
                        transcriptActionLabel("Actions", systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)

                    if allowsEditing {
                        Button {
                            onSaveEdits(title, transcriptText)
                            dismiss()
                        } label: {
                            transcriptActionLabel("Done", systemImage: "checkmark", isProminent: true)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .background(transcriptSheetBackground.ignoresSafeArea())
            .navigationTitle(Text(LocalizedStringKey("Review Transcript")))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    #if os(macOS)
                    IndustrialIconButton(systemImage: "xmark", help: "Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(Text(LocalizedStringKey("Close")))
                    #else
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(transcriptActionBackground))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(LocalizedStringKey("Close")))
                    #endif
                }
            }
        }
    }

    #if !os(macOS)
    private func transcriptActionLabel(
        _ titleKey: String,
        systemImage: String,
        isProminent: Bool = false
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .imageScale(.medium)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(titleKey))
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .allowsTightening(true)
        }
        .foregroundStyle(isProminent ? Color.white : Color.accentColor)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(
            Capsule(style: .continuous)
                .fill(isProminent ? Color.accentColor : transcriptActionBackground)
        )
    }
    #endif

    private var transcriptSheetBackground: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }

    private var transcriptFieldBackground: Color {
        #if os(macOS)
        return Color.primary.opacity(0.035)
        #else
        return Color(uiColor: .secondarySystemBackground)
        #endif
    }

    #if !os(macOS)
    private var transcriptActionBackground: Color {
        return Color(uiColor: .secondarySystemFill)
    }
    #endif

    private var transcriptFieldRadius: CGFloat {
        #if os(macOS)
        return 8
        #else
        return 16
        #endif
    }

    private var transcriptAreaRadius: CGFloat {
        #if os(macOS)
        return 8
        #else
        return 18
        #endif
    }

    private var transcriptBorderColor: Color {
        #if os(macOS)
        return Color.primary.opacity(0.08)
        #else
        return Color.secondary.opacity(0.18)
        #endif
    }
}

#if os(macOS)
// Menu can't take a PrimitiveButtonStyle, so the label carries the quiet
// MacIndustrialButtonStyle chrome itself.
private struct MacTranscriptMenuLabel: View {
    let titleKey: String
    let systemImage: String

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Label(LocalizedStringKey(titleKey), systemImage: systemImage)
            .textCase(.uppercase)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(0.5)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(Color.primary.opacity(0.75))
            .background(shape.fill(hovering ? Color.primary.opacity(0.05) : .clear))
            .overlay(shape.stroke(Color.primary.opacity(0.15), lineWidth: 1))
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}
#endif

struct TranscriptDatasetPickerSheet: View {
    let datasets: [LocalDataset]
    let onSelect: (LocalDataset) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(datasets) { dataset in
                Button {
                    onSelect(dataset)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dataset.name)
                            .font(.body.weight(.semibold))
                        Text(dataset.datasetID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(Text(LocalizedStringKey("Choose Dataset")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("Cancel")) { dismiss() }
                }
            }
            .overlay {
                if datasets.isEmpty {
                    ContentUnavailableView(
                        LocalizedStringKey("No Stored datasets"),
                        systemImage: "folder",
                        description: Text(LocalizedStringKey("Create a Stored dataset first, then save transcripts into it."))
                    )
                }
            }
        }
    }
}

func copyTranscriptToPasteboard(_ text: String) {
#if canImport(UIKit)
    UIPasteboard.general.string = text
#elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
#endif
}
#endif
