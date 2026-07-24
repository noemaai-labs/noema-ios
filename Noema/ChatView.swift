import SwiftUI
import Combine
import NoemaPackages
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(UIKit) || os(macOS)
extension MessageView {
    struct ChatView: View {
        @EnvironmentObject var vm: ChatVM
        @EnvironmentObject var modelManager: AppModelManager
        @EnvironmentObject var datasetManager: DatasetManager
        @EnvironmentObject var tabRouter: TabRouter
        @EnvironmentObject var walkthrough: GuidedWalkthroughManager
        @AppStorage("isAdvancedMode") private var isAdvancedMode = false
    @AppStorage("showGenerationDiagnostics") private var showGenerationDiagnostics = true
        // Renders assistant replies as the model's verbatim, unformatted text
        // (markdown syntax, think tags, tool markers) instead of parsed pieces.
        // Global so it stays consistent across every device; defaults off.
        @AppStorage("showRawAssistantOutput") private var showRawAssistantOutput = false
#if os(macOS)
        @State private var inputFocused = false
#else
        @FocusState private var inputFocused: Bool
#endif
        @State private var showSidebar = false
        @State private var sessionToDelete: ChatVM.Session?
#if os(macOS)
        @State private var drawerFilterText = ""
        @State private var sessionToRename: ChatVM.Session?
        @State private var renameDraft = ""
#endif
        @State private var shouldAutoScrollToBottom: Bool = true

        /// True when VoiceOver is running. A programmatic `scrollTo` while an
        /// assistive cursor is reading the transcript yanks focus to another
        /// element, so every auto-scroll handler is gated on this.
        private var isVoiceOverActive: Bool {
#if os(iOS) || os(visionOS)
            return UIAccessibility.isVoiceOverRunning
#elseif os(macOS)
            return NSWorkspace.shared.isVoiceOverEnabled
#else
            return false
#endif
        }
        // Suggestion overlay state
        @State private var suggestionTriplet: [String] = ChatSuggestions.nextThree()
        @State private var suggestionsSessionID: UUID?
        @State private var showModelRequiredAlert = false
        @State private var showContextOverflowAlert = false
        @State private var showMemoryPromptBudgetAlert = false
        @State private var showRuntimeInfo = false
        @State private var quickLoadInProgress: LocalModel.ID?
        /// Local draft text for the input box. Using @State instead of @Binding to
        /// vm.prompt means keystrokes do NOT fire ChatVM.objectWillChange, so the
        /// whole message list (including every MessageView / ToolCallView) is never
        /// re-rendered while the user is typing.
        @State private var draftText: String = ""
        @State private var chatRecallQuery = ""
        @State private var showScratchpad = false
        @State private var scratchpadDraft = ""
        @State private var showChatInstructions = false
        @State private var chatInstructionsDraft = ""
        @State private var showChatSnapshot = false
        @State private var showChatExportPack = false
        @State private var showContextPlan = false
#if os(macOS)
        @EnvironmentObject private var macChatChrome: MacChatChromeState
        /// Mirrors only the lens's counterfactual run (via `onReceive`), so the chat
        /// re-renders when the panel opens/closes — NOT on every readout frame the
        /// lens controller publishes during residual-stream viewing.
        @State private var jspaceCounterfactual: JSpaceLensController.CounterfactualRun?
        @State private var advancedSettings = ModelSettings()
        /// True while the first send of a fresh chat is gliding the composer
        /// from the centered canvas down to the bottom bar. The actual send is
        /// deferred until this animation finishes — prompt prefill saturates
        /// CPU/GPU and would starve the animation to a few frames otherwise.
        @State private var macComposerHandOff = false
#endif

        private struct BookmarkedMessageReference: Identifiable {
            let session: ChatVM.Session
            let message: ChatVM.Msg

            var id: UUID { message.id }
        }

        private struct ChatRecallResult: Identifiable {
            let session: ChatVM.Session
            let message: ChatVM.Msg
            let score: Int

            var id: String { "\(session.id.uuidString)-\(message.id.uuidString)" }
        }

        private struct ChatSnapshotRow: Identifiable {
            let id = UUID()
            let title: String
            let value: String
        }

        private struct ContextPlanRow: Identifiable {
            let id: UUID
            let roleTitle: String
            let preview: String
            let tokenCount: Int
            let statusKey: String
            let tint: Color
        }

        private var inputFocusBinding: Binding<Bool> {
            Binding(
                get: { inputFocused },
                set: { inputFocused = $0 }
            )
        }


        private struct ChatInputBox: View {
            @Binding var text: String
            var focus: Binding<Bool>
            @Binding var showModelRequiredAlert: Bool
            let send: () -> Void
            let stop: () -> Void
            let stopAfterParagraph: () -> Void
            let canStop: Bool
            let stopAfterParagraphPending: Bool
            @EnvironmentObject var vm: ChatVM
            @EnvironmentObject var modelManager: AppModelManager
            @EnvironmentObject var tabRouter: TabRouter
            @Environment(\.horizontalSizeClass) private var horizontalSizeClass
            @ObservedObject private var settings = SettingsStore.shared
            @AppStorage("chatStatusBarExpanded") private var statusBarExpanded = false
            @AppStorage("chatContextBreakdownExpanded") private var contextBreakdownExpanded = false
            @AppStorage("isAdvancedMode") private var isAdvancedMode = false
            @AppStorage("showGenerationDiagnostics") private var showGenerationDiagnostics = true
            @State private var showSmallCtxAlert: Bool = false
            @State private var measuredHeight: CGFloat = 0
            @State private var recentlyAddedImageURL: URL?
            @State private var pendingImageFeedbackTask: Task<Void, Never>?
            @State private var transcriptSaveFeedback: [ChatMediaAttachment.ID: TranscriptSaveFeedback] = [:]
            @State private var transcriptReviewAttachment: ChatMediaAttachment?
            @State private var pendingRemovalAttachment: ChatMediaAttachment?
            @State private var existingDatasetSaveAttachment: ChatMediaAttachment?
            @State private var remoteUploadConfirmationAttachment: ChatMediaAttachment?
            @State private var showVoiceMode = false
            @State private var autopilotDotPulsing = false
            @Environment(\.accessibilityReduceMotion) private var reduceMotion
            @ObservedObject private var autopilotLedger = AutopilotLedger.shared
#if os(macOS)
            @ObservedObject private var mcpManager = MCPServerManager.shared
#endif
#if os(iOS)
            @AppStorage(ChatSendBehavior.storageKey) private var chatSendBehaviorRaw = ChatSendBehavior.defaultValue.rawValue
            @AppStorage("compactChatModeEnabled") private var compactChatModeEnabled = false
#endif
            private struct InputHeightPreferenceKey: PreferenceKey {
                static var defaultValue: CGFloat { 0 }
                static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
            }
            // Keep the input aligned with surrounding buttons; slightly shorter on macOS.
            private var usesCompactComposer: Bool {
#if os(iOS)
                compactChatModeEnabled && horizontalSizeClass == .compact
#else
                false
#endif
            }

            private var controlHeight: CGFloat {
#if os(macOS)
                return 32
#elseif os(iOS)
                return usesCompactComposer ? 42 : 48
#else
                return 48
#endif
            }
            // Let the composer grow up to 2x its base control height, then rely on
            // the text input's internal scrolling for additional lines.
            private var inputMaxHeight: CGFloat {
                controlHeight * 2
            }
            private var inputVerticalPadding: CGFloat {
#if os(macOS)
                return 4
#else
                return usesCompactComposer ? 3 : 4
#endif
            }
            private var inputBottomInset: CGFloat {
#if os(macOS)
                return 4
#else
                return usesCompactComposer ? 1 : 2
#endif
            }
            private var inputOuterVerticalPadding: CGFloat {
#if os(macOS)
                return 2
#else
                return usesCompactComposer ? 1 : 2
#endif
            }

            private var accessoryRowSpacing: CGFloat {
                usesCompactComposer ? 5 : 8
            }

            private var composerRowAlignment: VerticalAlignment {
#if os(macOS)
                let hasAccessoryTray = !vm.pendingImageURLs.isEmpty
                    || !vm.pendingMediaAttachments.isEmpty
                    || vm.audioRecordingError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                return composerContainerHeight > controlHeight + 8 || hasAccessoryTray ? .bottom : .center
#else
                return .center
#endif
            }

            private var composerActionSpacing: CGFloat {
#if os(macOS)
                return 8
#else
                return 12
#endif
            }

            private var inputShellHorizontalPadding: CGFloat {
#if os(macOS)
                return 6
#else
                return 10
#endif
            }

            private var resolvedHeight: CGFloat {
                let minContent = max(controlHeight - (inputOuterVerticalPadding * 2), 0)
                let maxContent = max(inputMaxHeight - (inputOuterVerticalPadding * 2), minContent)
                // Fallback for explicit line breaks so growth still works even if
                // measurement lags during rapid edits.
                let explicitLineCount = max(1, text.replacingOccurrences(of: "\r\n", with: "\n")
                    .split(separator: "\n", omittingEmptySubsequences: false).count)
                let estimatedFromLines = CGFloat(explicitLineCount) * 22 + (inputVerticalPadding * 2) + inputBottomInset
                let measuredOrEstimated = max(measuredHeight, estimatedFromLines)
                let clamped = min(max(measuredOrEstimated, minContent), maxContent)
                return clamped
            }

            private var composerContainerHeight: CGFloat {
                resolvedHeight + (inputOuterVerticalPadding * 2)
            }

            private var composerCornerRadius: CGFloat {
#if os(macOS)
                let expandedRadius: CGFloat = 16
#else
                let expandedRadius = UIConstants.largeCornerRadius
#endif
                return UIConstants.adaptiveComposerCornerRadius(
                    currentHeight: composerContainerHeight,
                    collapsedHeight: controlHeight,
                    expandedHeight: inputMaxHeight,
                    expandedRadius: expandedRadius
                )
            }

            private var measurementText: String {
                text.isEmpty ? "Ask…" : text + " "
            }

            private var hasActiveChatModel: Bool { vm.canAcceptChatInput }

            private var hasText: Bool {
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            private struct RuntimeStatus {
                let title: String
                let detail: String
                let icon: String
                let tint: Color
            }

            private struct ContextMeterSnapshot {
                let messages: Int
                let system: Int
                let tools: Int
                let retrieval: Int
                let images: Int
                let typed: Int
                let reservedResponseTokens: Int
                let usablePromptTokens: Int
                let contextWindow: Int

                var usedTokens: Int {
                    messages + system + tools + retrieval + images + typed
                }

                var freeTokens: Int {
                    max(0, contextWindow - usedTokens - reservedResponseTokens)
                }

                var fraction: Double {
                    guard usablePromptTokens > 0 else { return 0 }
                    return min(1, Double(usedTokens) / Double(usablePromptTokens))
                }

                var tint: Color {
                    if fraction >= 0.92 { return .red }
                    if fraction >= 0.75 { return .orange }
                    return .green
                }

                /// One slice of the consumed context, ordered largest-concept-first.
                struct Slice: Identifiable {
                    let id: String
                    let title: String
                    let value: Int
                    /// 0…1 position in the shade ramp of the health tint.
                    let shade: Double
                }

                /// Non-zero consumers, in display order. Titles are localized by the caller.
                func slices(titles: [String: String]) -> [Slice] {
                    let raw: [(String, Int, Double)] = [
                        ("messages", messages, 1.0),
                        ("system", system, 0.78),
                        ("tools", tools, 0.6),
                        ("retrieval", retrieval, 0.46),
                        ("images", images, 0.34),
                        ("typed", typed, 0.22)
                    ]
                    return raw.compactMap { key, value, shade in
                        guard value > 0 else { return nil }
                        return Slice(id: key, title: titles[key] ?? key, value: value, shade: shade)
                    }
                }
            }

            private enum ContextCapability: String, CaseIterable, Identifiable {
                case web
                case python
                case memory
                case rag
                case datasets
                case charts
                case calendar

                var id: String { rawValue }
            }

            private struct ContextCapabilityItem: Identifiable {
                let id: ContextCapability
                let title: String
                let isOn: Bool
                let isAvailable: Bool
            }

            private var runtimeStatus: RuntimeStatus {
                if vm.loading || vm.stillLoading {
                    return RuntimeStatus(
                        title: String(localized: "Loading model"),
                        detail: modelManager.loadedModel?.name ?? String(localized: "Preparing runtime"),
                        icon: "hourglass",
                        tint: .orange
                    )
                }

                if vm.isAutoRoutingActive, let model = resolvedLoadedModel {
                    let detail: String
                    if vm.autoRoutingStage == .deciding {
                        detail = String(localized: "Routing…")
                    } else {
                        let config = AutopilotConfigStore.load()
                        if config.isReadyToArm,
                           let escalationName = config.escalationDisplayName {
                            detail = String.localizedStringWithFormat(
                                String(localized: "%1$@ · %2$@ on call"), model.name, escalationName)
                        } else {
                            detail = String(localized: "local only")
                        }
                    }
                    return RuntimeStatus(
                        title: String(localized: "Auto"),
                        detail: detail,
                        icon: "arrow.triangle.branch",
                        tint: .cyan
                    )
                }

                if let model = resolvedLoadedModel {
                    let format = vm.loadedModelFormat?.displayName ?? model.format.displayName
                    let title = vm.canAcceptChatInput ? String(localized: "Ready") : String(localized: "Model selected")
                    return RuntimeStatus(
                        title: title,
                        detail: "\(model.name) · \(format)",
                        icon: vm.canAcceptChatInput ? "checkmark.circle.fill" : "circle.dashed",
                        tint: vm.canAcceptChatInput ? .green : .gray
                    )
                }

                if vm.canAcceptChatInput {
                    return RuntimeStatus(
                        title: String(localized: "Remote ready"),
                        detail: String(localized: "Connected backend"),
                        icon: "network",
                        tint: .green
                    )
                }

                return RuntimeStatus(
                    title: String(localized: "No model loaded"),
                    detail: String(localized: "Select a model to start chatting."),
                    icon: "exclamationmark.circle",
                    tint: .gray
                )
            }

            private var resolvedLoadedModel: LocalModel? {
                // Only surface a model once it is actually resident. After the
                // background unload controller frees the runtime on app exit,
                // `modelManager.loadedModel` lingers as the last selection, but
                // `vm.modelLoaded` flips false — so the status bar must not keep
                // showing the freed model's name. Loading state is handled by the
                // caller (runtimeStatus) before this property is consulted.
                guard vm.modelLoaded else { return nil }
                if let model = modelManager.loadedModel {
                    return model
                }
                guard let url = vm.loadedModelURL else { return nil }
                return modelManager.downloadedModels.first { candidate in
                    candidate.url == url || candidate.url.path == url.path
                }
            }

            private var latestRAGInfo: ChatVM.Msg.RAGInjectionInfo? {
                vm.streamMsgs.reversed().first { $0.ragInjectionInfo != nil }?.ragInjectionInfo
            }

            private var contextMeterSnapshot: ContextMeterSnapshot {
                let mediaTranscriptTokens = vm.pendingMediaAttachments.reduce(0) { total, attachment in
                    total + estimatedTokenCount(attachment.transcript?.effectiveTranscriptText ?? "")
                }
                let typedTokens = estimatedTokenCount(text) + mediaTranscriptTokens
                let retrievalTokens = latestRAGInfo?.injectedContextTokens ?? 0
                let imageTokens = vm.pendingImageURLs.count * 576

                let breakdown = vm.contextBudgetBreakdown(
                    typedTokens: typedTokens,
                    retrievalTokens: retrievalTokens,
                    imageTokens: imageTokens
                )

                return ContextMeterSnapshot(
                    messages: breakdown.messages,
                    system: breakdown.system,
                    tools: breakdown.tools,
                    retrieval: breakdown.retrieval,
                    images: breakdown.images,
                    typed: breakdown.typed,
                    reservedResponseTokens: breakdown.reserved,
                    usablePromptTokens: breakdown.usablePromptTokens,
                    contextWindow: breakdown.contextWindow
                )
            }

            private var hasCompletedMediaTranscript: Bool {
                vm.pendingMediaAttachments.contains(where: \.hasCompletedTranscript)
            }

            private var canKeyboardSubmit: Bool {
                (hasText || hasCompletedMediaTranscript) && !canStop && !vm.isStreamingInAnotherSession && !(vm.loading || vm.stillLoading)
            }

            private var chatSendBehavior: ChatSendBehavior {
#if os(iOS)
                ChatSendBehavior.from(chatSendBehaviorRaw)
#else
                .defaultValue
#endif
            }

#if canImport(UIKit)
            private var submitConfiguration: MobileBottomAnchoredTextEditor.SubmitConfiguration? {
#if os(iOS)
                MobileBottomAnchoredTextEditor.SubmitConfiguration(
                    behavior: chatSendBehavior,
                    canSubmit: canKeyboardSubmit,
                    onSubmit: triggerSendFromKeyboard
                )
#else
                nil
#endif
            }
#endif

            private var composerAccessibilityHint: LocalizedStringKey {
                LocalizedStringKey(chatSendBehavior.accessibilityHintKey)
            }

            private func triggerSendFromKeyboard() {
                guard canKeyboardSubmit else { return }
                performSend()
            }

            private func performSend() {
                let isChatReady = hasActiveChatModel

                guard isChatReady else {
                    showModelRequiredAlert = true
                    focus.wrappedValue = false
                    return
                }
                guard !vm.isStreamingInAnotherSession else {
                    vm.crossSessionSendBlocked = true
                    focus.wrappedValue = false
                    return
                }
                if UIConstants.showMultimodalUI && vm.supportsImageInput && !vm.pendingImageURLs.isEmpty && vm.contextLimit < 5000 {
                    showSmallCtxAlert = true
                    return
                }
#if canImport(Speech)
                if vm.isDictating {
                    // Finish dictation first so the final transcript lands in the
                    // prompt and no stale partials refill the field after send.
                    Task { @MainActor in
                        await vm.stopLiveDictation()
                        text = vm.prompt
                        send()
                        text = ""
                    }
                    return
                }
#endif
                send()
                text = ""
            }

            /// Extracted so `composerRow` stays type-checkable; macOS uses a clean
            /// filled circle while iOS/visionOS keep the glass pill treatment.
            @ViewBuilder
            private func sendButtonLabel(canSend: Bool) -> some View {
#if os(macOS)
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: controlHeight - 8, height: controlHeight - 8)
                    .background(
                        Circle().fill(
                            canSend
                                ? Color.accentColor
                                : Color.primary.opacity(0.055)
                        )
                    )
                    .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.72))
                    .frame(width: controlHeight, height: controlHeight)
                    .contentShape(Circle())
#else
                let sendShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: controlHeight, height: controlHeight)
                    .background(
                        sendShape
                            .fill(Color.clear)
                            .glassifyIfAvailable(in: sendShape)
                            .overlay(
                                sendShape.fill(
                                    canSend
                                        ? Color.accentColor.opacity(0.36)
                                        : Color.white.opacity(0.06)
                                )
                            )
                            .overlay(
                                sendShape.strokeBorder(
                                    canSend
                                        ? Color.accentColor.opacity(0.44)
                                        : Color.white.opacity(0.22),
                                    lineWidth: 0.8
                                )
                            )
                            .shadow(
                                color: canSend ? Color.accentColor.opacity(0.28) : .clear,
                                radius: canSend ? 10 : 0,
                                y: canSend ? 5 : 0
                            )
                    )
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
#endif
            }


            var body: some View {
#if os(macOS)
                macUnifiedInputContainer
#else
                VStack(spacing: accessoryRowSpacing) {
#if os(iOS)
                    if let doc = vm.attachedDocument {
                        attachedDocumentCard(doc)
                    }
#endif
                    statusBarRow
                    composerRow
                }
#if os(iOS)
                .animation(.easeInOut(duration: 0.2), value: vm.attachedDocument != nil)
#endif
#endif
            }

            private func attachedDocumentCard(_ doc: AttachedDocumentState) -> some View {
                AttachedDocChip(doc: doc, onRemove: { vm.removeAttachedDocument() })
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: ChatTheme.controlRadius, style: .continuous)
                            .fill(ChatTheme.cardSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ChatTheme.controlRadius, style: .continuous)
                            .strokeBorder(ChatTheme.hairline, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: ChatTheme.controlRadius, style: .continuous))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

#if os(macOS)
            /// One clean composer surface: the input row sits on a single card
            /// and the runtime status collapses into a quiet footer line.
            private var macUnifiedInputContainer: some View {
                VStack(spacing: 8) {
                    // Attached document floats as its own pill ABOVE the composer card,
                    // rather than sitting inside it — keeps the input clean and uses the
                    // Mac's extra width for the embedding progress.
                    if let doc = vm.attachedDocument {
                        attachedDocumentCard(doc)
                    }
                    macComposerCard
                }
                .animation(.easeInOut(duration: 0.2), value: vm.attachedDocument != nil)
            }

            private var macComposerCard: some View {
                VStack(spacing: 0) {
                    composerRow
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    Divider()
                        .opacity(0.45)
                        .padding(.horizontal, 14)
                    statusBarRow
                }
                .background(
                    RoundedRectangle(cornerRadius: ChatTheme.composerRadius, style: .continuous)
                        .fill(ChatTheme.cardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChatTheme.composerRadius, style: .continuous)
                        .stroke(
                            focus.wrappedValue ? Color.accentColor.opacity(0.34) : ChatTheme.hairline,
                            lineWidth: focus.wrappedValue ? 1.2 : 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: ChatTheme.composerRadius, style: .continuous))
                .animation(.easeOut(duration: 0.16), value: focus.wrappedValue)
            }
#endif

            @ViewBuilder
            private var statusBarRow: some View {
                if usesCompactComposer {
                    compactComposerStatusRow
                } else {
                    runtimeStatusBar
                }
            }

            private var composerRow: some View {
                HStack(alignment: composerRowAlignment, spacing: 8) {
#if os(macOS)
                    VisionAttachmentButton(
                        showWebSearchOption: false,
                        showPythonOption: false,
                        showPlusIcon: true,
                        onModelRequiredTap: {
                            showModelRequiredAlert = true
                            focus.wrappedValue = false
                        }
                    )
                        .guideHighlight(.chatWebSearch)
                        .frame(width: controlHeight, height: controlHeight)
                        .help("Attach")
#endif
#if os(iOS) || os(visionOS)
                    VisionAttachmentButton(
                        showWebSearchOption: false,
                        showPythonOption: false,
                        showPlusIcon: true,
                        onModelRequiredTap: {
                            showModelRequiredAlert = true
                            focus.wrappedValue = false
                        }
                    )
                        .guideHighlight(.chatWebSearch)
                        .frame(width: controlHeight, height: controlHeight)
#endif
                    let isChatReady = hasActiveChatModel
                    let isComposerBusy = vm.loading || vm.stillLoading
                    VStack(spacing: accessoryRowSpacing) {
                        // Images displayed above the text field
                        if UIConstants.showMultimodalUI && vm.supportsImageInput && !vm.pendingImageURLs.isEmpty {
                            pendingImagesTray
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if !vm.pendingMediaAttachments.isEmpty || vm.audioRecordingError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                            pendingMediaTray
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        // Input area with vision attachments and multi-line text entry
                        HStack(alignment: composerRowAlignment, spacing: composerActionSpacing) {
                            ZStack(alignment: .topLeading) {
#if os(iOS) || os(visionOS)
                                MobileBottomAnchoredTextEditor(
                                    text: $text,
                                    focus: focus,
                                    isDisabled: isComposerBusy,
                                    topInset: inputVerticalPadding,
                                    bottomInset: inputVerticalPadding + inputBottomInset,
                                    font: .preferredFont(forTextStyle: .body),
                                    submitConfiguration: submitConfiguration
                                )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(maxHeight: resolvedHeight, alignment: .topLeading)
                                    .padding(.horizontal, 4)
                                    .disabled(isComposerBusy)
                                    .accessibilityLabel(Text("Message input"))
                                    .accessibilityIdentifier("message-input")
                                    .accessibilityHint(composerAccessibilityHint)

                                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    HStack {
                                        Text("Ask…")
                                            .foregroundColor(.secondary)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.top, inputVerticalPadding)
                                    .padding(.bottom, inputVerticalPadding + inputBottomInset)
                                    .frame(maxWidth: .infinity, maxHeight: resolvedHeight, alignment: .topLeading)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                }
#else
                                MacAutoScrollingTextEditor(
                                    text: $text,
                                    focus: focus,
                                    isDisabled: isComposerBusy,
                                    topInset: inputVerticalPadding,
                                    bottomInset: inputVerticalPadding + inputBottomInset,
                                    font: .systemFont(ofSize: NSFont.systemFontSize),
                                    onCommandReturn: triggerSendFromKeyboard
                                )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(maxHeight: resolvedHeight, alignment: .topLeading)
                                    .padding(.horizontal, 4)
                                    .background(Color.clear)
                                    .accessibilityLabel(Text("Message input"))
                                    .accessibilityIdentifier("message-input")
                                    .accessibilityHint(composerAccessibilityHint)

                                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Ask…")
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.top, inputVerticalPadding)
                                        .frame(maxWidth: .infinity, maxHeight: resolvedHeight, alignment: .topLeading)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
#endif
                                // Invisible measurement text keeps the control compact until content grows.
                                Text(measurementText)
                                    .font(.body)
                                    .lineLimit(nil)
                                    .padding(.horizontal, 4)
                                    .padding(.top, inputVerticalPadding)
                                    .padding(.bottom, inputVerticalPadding + inputBottomInset)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .background(
                                        GeometryReader { proxy in
                                            Color.clear.preference(key: InputHeightPreferenceKey.self, value: proxy.size.height)
                                        }
                                    )
                                    .hidden()
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)

                            }
                            .onPreferenceChange(InputHeightPreferenceKey.self) { measuredHeight = $0 }
                            .padding(.horizontal, inputShellHorizontalPadding)
                            .padding(.vertical, inputOuterVerticalPadding)
                            .frame(minHeight: controlHeight,
                                   maxHeight: inputMaxHeight,
                                   alignment: .topLeading)
                            .frame(height: composerContainerHeight, alignment: .topLeading)
                            .clipShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
                            // macOS gets no inner stroke or glass — the editor sits
                            // flush on the single composer card instead of nesting
                            // surfaces.
#if !os(macOS)
                            .glassPill(cornerRadius: composerCornerRadius)
#endif
                            .frame(maxWidth: .infinity)
#if os(iOS) || os(visionOS)
                            .overlay {
                                if !isChatReady {
                                    RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                                        .fill(Color.clear)
                                        .contentShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
                                        .onTapGesture {
                                            showModelRequiredAlert = true
                                            focus.wrappedValue = false
                                        }
                                }
                            }
#endif

#if canImport(AVFoundation)
                            voiceRecordButton(isDisabled: isComposerBusy)
#endif
#if canImport(AVFoundation) && canImport(Speech)
                            voiceModeButton(isDisabled: isComposerBusy)
#endif
                        }
                    }
                    // Value-scoped: only fires when attachments are added/removed,
                    // so typing never re-animates the row (see note below the HStack).
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.pendingImageURLs.count)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.pendingMediaAttachments.count)
                    if canStop {
                        Button(action: stop) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: controlHeight, height: controlHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.red)
                                )
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain) // Avoid default gray button chrome behind the custom red pill
                        .accessibilityLabel(Text("Stop generating"))
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    } else {
                        let canSend = isChatReady
                            && !isComposerBusy
                            && !vm.isStreamingInAnotherSession
                            && (hasText || hasCompletedMediaTranscript)
                        Button(action: {
                            performSend()
                        }) {
                            sendButtonLabel(canSend: canSend)
                        }
#if os(macOS)
                        .help("Send")
#endif
                        .accessibilityIdentifier("chat-send-button")
                        .buttonStyle(.plain)
                        .disabled((!hasText && !hasCompletedMediaTranscript) || vm.isStreamingInAnotherSession || isComposerBusy)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                // Avoid animating the entire input row on every keystroke,
                // which caused attachment thumbnails to flicker.
                // The animations below are value-scoped to the send/stop swap only;
                // keystrokes don't change `canStop`, so they can't re-trigger it.
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: canStop)
                .alert("Finish current response", isPresented: Binding(
                    get: { vm.crossSessionSendBlocked },
                    set: { vm.crossSessionSendBlocked = $0 }
                )) {
                    Button("OK", role: .cancel) { vm.crossSessionSendBlocked = false }
                } message: {
                    Text("Wait for the response in your other chat to finish before sending a new message.")
                }
                .alert("Small context may cause image crash", isPresented: $showSmallCtxAlert) {
                    Button("Send Anyway") {
                        send()
                        text = ""
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Context length is under 5000 tokens. With images and multi-sequence decoding (n_seq_max=16), per-sequence memory can be too small, leading to a crash. Increase context to at least 8192 in Model Settings.")
                }
                .alert("Load a model to chat", isPresented: $showModelRequiredAlert) {
                    Button(LocalizedStringKey("Open Stored")) {
                        tabRouter.selection = .stored
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(LocalizedStringKey("Open Stored to choose a model to run locally or connect to a remote endpoint."))
                }
                .confirmationDialog(
                    Text(LocalizedStringKey("Remove unsaved transcript?")),
                    isPresented: Binding(
                        get: { pendingRemovalAttachment != nil },
                        set: { if !$0 { pendingRemovalAttachment = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(LocalizedStringKey("Remove"), role: .destructive) {
                        if let attachment = pendingRemovalAttachment {
                            vm.removePendingMediaAttachment(id: attachment.id)
                        }
                        pendingRemovalAttachment = nil
                    }
                    Button(LocalizedStringKey("Cancel"), role: .cancel) {
                        pendingRemovalAttachment = nil
                    }
                } message: {
                    Text(LocalizedStringKey("This transcript has not been sent or saved yet."))
                }
                .confirmationDialog(
                    Text(LocalizedStringKey("Upload media for remote transcription?")),
                    isPresented: Binding(
                        get: { remoteUploadConfirmationAttachment != nil },
                        set: { if !$0 { remoteUploadConfirmationAttachment = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(LocalizedStringKey("Upload and Transcribe")) {
                        if let attachment = remoteUploadConfirmationAttachment {
                            TranscriptionSettings.confirmRemoteUpload()
                            vm.beginTranscribingPendingMediaAttachment(id: attachment.id)
                        }
                        remoteUploadConfirmationAttachment = nil
                    }
                    Button(LocalizedStringKey("Cancel"), role: .cancel) {
                        remoteUploadConfirmationAttachment = nil
                    }
                } message: {
                    Text(LocalizedStringKey("Remote ASR sends the selected media to your configured audio-language endpoint. Use it only with endpoints you trust."))
                }
                .sheet(item: $transcriptReviewAttachment) { attachment in
                    TranscriptReviewSheet(
                        attachment: latestPendingAttachment(matching: attachment) ?? attachment,
                        allowsEditing: true,
                        onSaveEdits: { title, transcriptText in
                            vm.updatePendingMediaTranscript(id: attachment.id, title: title, transcriptText: transcriptText)
                        },
                        onQuickAction: { action in
                            performTranscriptQuickAction(action, for: latestPendingAttachment(matching: attachment) ?? attachment)
                        },
                        onSaveNewDataset: {
                            if let latest = latestPendingAttachment(matching: attachment) {
                                saveTranscriptAttachment(latest)
                            }
                        },
                        onSaveExistingDataset: {
                            existingDatasetSaveAttachment = latestPendingAttachment(matching: attachment) ?? attachment
                        }
                    )
                }
                .sheet(item: $existingDatasetSaveAttachment) { attachment in
                    TranscriptDatasetPickerSheet(datasets: vm.datasetManager?.datasets ?? []) { dataset in
                        if let latest = latestPendingAttachment(matching: attachment) {
                            saveTranscriptAttachment(latest, toExistingDataset: dataset)
                        } else {
                            saveTranscriptAttachment(attachment, toExistingDataset: dataset)
                        }
                    }
                }
                .onChangeCompat(of: vm.pendingImageURLs) { oldURLs, newURLs in
                    handlePendingImagesChange(from: oldURLs, to: newURLs)
                }
#if os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: .mcpInsertComposerText)) { notification in
                    guard let inserted = notification.object as? String, !inserted.isEmpty else { return }
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "\n\n" }
                    text += inserted
                    focus.wrappedValue = true
                }
#endif
                .onDisappear {
                    pendingImageFeedbackTask?.cancel()
                }
            }

            private var statusModelName: String? {
                if let remote = modelManager.activeRemoteSession {
                    return remote.modelName
                }
                if let model = resolvedLoadedModel {
                    return model.name
                }
                return nil
            }

            /// A compact runtime rail that expands into the conversation's capabilities
            /// and context budget, spoken in the industrial Stored dialect: mono-caps
            /// microtype, hairlines, dots, tinted r4 badges.
            private var statusDetailFont: Font {
#if os(macOS)
                .caption2
#else
                .caption
#endif
            }

            private var statusRowVerticalPadding: CGFloat {
#if os(macOS)
                8
#else
                10
#endif
            }

            private var runtimeStatusBar: some View {
                let status = runtimeStatus
                let snapshot = contextMeterSnapshot
                let showsBudget = snapshot.contextWindow > 0 && vm.modelLoaded
                return VStack(spacing: 0) {
                    Button {
                        // No withAnimation here: statusBarExpanded is @AppStorage, whose
                        // update can land outside the transaction. The scoped
                        // .animation(value:) on the container drives the animation instead.
                        statusBarExpanded.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(status.tint)
                                .frame(width: 6, height: 6)
                                .opacity(reduceMotion
                                    ? (vm.autoRoutingStage == .deciding ? 0.7 : 1)
                                    : (autopilotDotPulsing ? 0.35 : 1))
                            Text(verbatim: status.title)
                                .textCase(.uppercase)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(0.3)
                                .foregroundStyle(Color.primary.opacity(0.6))
                                .lineLimit(1)
                                .fixedSize()
                            if let name = statusModelName {
                                Text(verbatim: name)
                                    .font(statusDetailFont)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 6)
                            if showsBudget {
                                Text(verbatim: "\(Self.shortTokenLabel(snapshot.usedTokens)) / \(Self.shortTokenLabel(snapshot.contextWindow))")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(snapshot.tint.opacity(0.85))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .layoutPriority(1)
                                collapsedContextTrack(snapshot)
                                    .frame(width: collapsedContextTrackWidth, height: 2)
                                    .layoutPriority(1)
                            }
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(statusBarExpanded ? 180 : 0))
                                .animation(
                                    reduceMotion ? nil : .easeInOut(duration: 0.18),
                                    value: statusBarExpanded
                                )
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, statusRowVerticalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(String.localizedStringWithFormat(
                        String(localized: "Runtime status: %@, %@"), status.title, status.detail)))
                    .accessibilityHint(Text(statusBarExpanded
                        ? String(localized: "Collapse tool and context details")
                        : String(localized: "Expand tool and context details")))

                    if statusBarExpanded {
                        VStack(spacing: 0) {
                            IndustrialHairline()
                            expandedStatusDrawer
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .padding(.bottom, 12)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
#if !os(macOS)
                .background(
                    RoundedRectangle(cornerRadius: ChatTheme.composerRadius, style: .continuous)
                        .fill(ChatTheme.cardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChatTheme.composerRadius, style: .continuous)
                        .stroke(ChatTheme.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: ChatTheme.composerRadius, style: .continuous))
#endif
                // A short value-scoped animation lets the container resize while the
                // contents fade as one surface. Individual controls do not move in.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: statusBarExpanded)
                .onChangeCompat(of: vm.autoRoutingStage) { _, stage in
                    syncAutopilotPulse(deciding: stage == .deciding)
                }
                .onAppear {
                    syncAutopilotPulse(deciding: vm.autoRoutingStage == .deciding)
                }
            }

            private var collapsedContextTrackWidth: CGFloat {
#if os(macOS)
                58
#else
                42
#endif
            }

            private func collapsedContextTrack(_ snapshot: ContextMeterSnapshot) -> some View {
                let window = Double(max(1, snapshot.contextWindow))
                return GeometryReader { proxy in
                    let width = proxy.size.width
                    let usedWidth = snapshot.usedTokens > 0
                        ? max(2, width * Double(snapshot.usedTokens) / window)
                        : 0
                    let reserveWidth = width * Double(snapshot.reservedResponseTokens) / window
                    HStack(spacing: 0) {
                        Capsule(style: .continuous)
                            .fill(snapshot.tint.opacity(0.85))
                            .frame(width: usedWidth)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.32))
                            .frame(width: reserveWidth)
                        Spacer(minLength: 0)
                    }
                }
                .background(Color.secondary.opacity(0.14))
                .clipShape(Capsule(style: .continuous))
                .accessibilityHidden(true)
            }

            /// Two columns wherever the composer is wide enough (Mac, iPad regular
            /// width, visionOS); one stacked column on iPhone. Width-driven, not
            /// platform-driven, so all three platforms share one drawer.
            private var drawerUsesColumns: Bool {
#if os(macOS)
                return true
#else
                return horizontalSizeClass == .regular
#endif
            }

            @ViewBuilder
            private var expandedStatusDrawer: some View {
                if drawerUsesColumns {
                    HStack(alignment: .top, spacing: 16) {
                        capabilityColumn
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        contextBudgetMeter
                            .frame(minWidth: 250, idealWidth: 310, maxWidth: 350, alignment: .topLeading)
                            .padding(.leading, 16)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(ChatTheme.hairline)
                                    .frame(width: 1)
                            }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        capabilityColumn
                        contextBudgetMeter
                    }
                }
            }

            private var capabilityColumn: some View {
                VStack(alignment: .leading, spacing: 10) {
                    toolsSection
                    if vm.currentModelSupportsReasoning {
                        IndustrialHairline()
                        reasoningToggleRow
                    }
                    if vm.isAutoRoutingActive {
                        IndustrialHairline()
                        autopilotLedgerRow
                    }
                }
            }

            // State-driven repeatForever, mirroring ToolCallView.syncPulse: withAnimation
            // on a @State flag, never on the @AppStorage-backed bar state.
            private func syncAutopilotPulse(deciding: Bool) {
                if deciding && !reduceMotion {
                    guard !autopilotDotPulsing else { return }
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        autopilotDotPulsing = true
                    }
                } else if autopilotDotPulsing {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        autopilotDotPulsing = false
                    }
                }
            }

            private var autopilotLedgerRow: some View {
                let totals = autopilotLedger.totals
                let percent = Int((totals.onDeviceFraction * 100).rounded())
                let savedLabel = String(format: "%.1f", totals.whSaved)
                return HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cyan)
                    Text(verbatim: "AUTOPILOT")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 6)
                    if totals.totalTurns == 0 {
                        Text(String(localized: "no routed answers yet"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: String.localizedStringWithFormat(
                            String(localized: "%1$d%% on-device · ≈%2$@ Wh saved"),
                            percent, savedLabel))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(totals.totalTurns == 0
                    ? String(localized: "Autopilot: no routed answers yet")
                    : String.localizedStringWithFormat(
                        String(localized: "Autopilot: %1$d percent on device, approximately %2$@ watt hours saved, estimate."),
                        percent, savedLabel)))
            }

            private var runtimeStatusPill: some View {
                let status = runtimeStatus
                return HStack(spacing: 7) {
                    Circle()
                        .fill(status.tint)
                        .frame(width: 6, height: 6)
                    Text(verbatim: status.title)
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineLimit(1)
                    Text(verbatim: status.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(String.localizedStringWithFormat(String(localized: "Runtime status: %@, %@"), status.title, status.detail)))
            }

            private var compactComposerStatusRow: some View {
                let snapshot = contextMeterSnapshot
                let percent = Int((snapshot.fraction * 100).rounded())
                let usedTokens = snapshot.usedTokens
                let usableTokens = max(0, snapshot.usablePromptTokens)
                let showTokenCounts = isAdvancedMode && showGenerationDiagnostics
                let showContextGauge = vm.modelLoaded
                let hideChatTools = vm.afmChatToolsUnavailable
                return HStack(spacing: 6) {
                    runtimeStatusPill
                        .layoutPriority(1)
                    if !hideChatTools {
                    Menu {
                        toolPermissionMenuItems
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.system(size: 10, weight: .semibold))
                            Text(verbatim: "\(chatToolEnabledCount)/\(chatToolTotalCount)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(String.localizedStringWithFormat(
                        String(localized: "Chat tools: %1$d of %2$d allowed"),
                        chatToolEnabledCount, chatToolTotalCount
                    )))
                    } // if !hideChatTools

                    if showContextGauge {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(snapshot.tint)
                                .frame(width: 5, height: 5)
                            if showTokenCounts {
                                Text(verbatim: "\(usedTokens)/\(usableTokens)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            } else {
                                Text(verbatim: "\(percent)%")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            }
                        }
                        .foregroundStyle(snapshot.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(snapshot.tint.opacity(0.12))
                        )
                        .accessibilityLabel(Text(String.localizedStringWithFormat(
                            String(localized: "Context used: %lld of %lld tokens (%d%%)"),
                            Int64(usedTokens), Int64(usableTokens), percent
                        )))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            @ViewBuilder
            private var toolPermissionMenuItems: some View {
                let hideChatTools = vm.afmChatToolsUnavailable
                if !hideChatTools {
                    Toggle(isOn: toolPermissionBinding(.webSearch)) {
                        Label(LocalizedStringKey("Web Search"), systemImage: "globe")
                    }
                    .disabled(!settings.webSearchEnabled)

                    Toggle(isOn: toolPermissionBinding(.python)) {
                        Label(LocalizedStringKey("Python"), systemImage: "terminal")
                    }
                    .disabled(!settings.pythonEnabled || !PythonRuntime.status().isAvailable)

                    Toggle(isOn: toolPermissionBinding(.memory)) {
                        Label(LocalizedStringKey("Memory"), systemImage: "brain")
                    }
                    .disabled(!settings.memoryEnabled)
                }

                Toggle(isOn: toolPermissionBinding(.datasetRetrieval)) {
                    Label(LocalizedStringKey("Dataset Retrieval"), systemImage: "doc.text.magnifyingglass")
                }

#if os(macOS)
                if !mcpManager.servers.isEmpty {
                    Divider()
                    Section(LocalizedStringKey("MCP Servers")) {
                        ForEach(mcpManager.servers) { server in
                            let enabledToolCount = server.tools.filter {
                                server.configuration.policy.isToolEnabled($0.originalName)
                            }.count
                            Toggle(isOn: Binding(
                                get: { vm.activeToolPermissions.selectedMCPServerIDs.contains(server.id) },
                                set: { vm.setMCPServerPermissionForActiveSession(server.id, enabled: $0) }
                            )) {
                                Label(server.configuration.displayName, systemImage: "point.3.connected.trianglepath.dotted")
                            }
                            .disabled(server.state != .ready || enabledToolCount == 0)
                        }
                    }
                }
#endif

                // Compact-mode home for the reasoning toggle (mirrors the expanded panel's
                // reasoningToggleRow). Same auto-saving write-through via vm.setReasoningEnabled.
                if vm.currentModelSupportsReasoning {
                    Divider()
                    Toggle(isOn: Binding(get: { vm.reasoningEnabled },
                                         set: { vm.setReasoningEnabled($0) })) {
                        Label(LocalizedStringKey("Reasoning"), systemImage: "brain")
                    }
                }

                Divider()

                Button {
                    vm.setAllToolPermissionsForActiveSession(enabled: true)
                } label: {
                    Label(LocalizedStringKey("Allow All Tools"), systemImage: "checkmark.circle")
                }

                Button {
                    vm.setAllToolPermissionsForActiveSession(enabled: false)
                } label: {
                    Label(LocalizedStringKey("Block Chat Tools"), systemImage: "slash.circle")
                }
            }

            private var toolsSection: some View {
                let hideChatTools = vm.afmChatToolsUnavailable
                let items = contextCapabilityItems
                let activeCount = items.filter { $0.isOn && $0.isAvailable }.count

                return VStack(alignment: .leading, spacing: 9) {
                    IndustrialSectionHeader("Capabilities") {
                        Text(verbatim: "\(activeCount)/\(items.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.4))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(LocalizedStringKey("Capabilities")))
                    .accessibilityValue(Text(String.localizedStringWithFormat(
                        String(localized: "%1$d of %2$d on"),
                        activeCount, items.count
                    )))

                    if drawerUsesColumns {
                        ChipFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            ForEach(items) { item in
                                toolToggleChip(item)
                            }
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(items) { item in
                                    toolToggleChip(item)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
#if os(macOS)
                    if !mcpManager.servers.isEmpty {
                        IndustrialSectionHeader("MCP Servers") {
                            Text(verbatim: "\(mcpManager.servers.count)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.4))
                        }
                        .padding(.top, 3)
                        ForEach(mcpManager.servers) { server in
                            mcpServerRow(server)
                        }
                    }
#endif
                    if hideChatTools {
                        Text(LocalizedStringKey("Web search, Python, and Memory are not available with Apple Foundation Models."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if !currentModelToolCapable {
                        Text(LocalizedStringKey("Loaded model lacks tool calling"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

#if os(macOS)
            private func mcpServerRow(_ server: MCPServerStatus) -> some View {
                let enabledToolCount = server.tools.filter {
                    server.configuration.policy.isToolEnabled($0.originalName)
                }.count
                let selected = vm.activeToolPermissions.selectedMCPServerIDs.contains(server.id)
                return Button {
                    vm.setMCPServerPermissionForActiveSession(server.id, enabled: !selected)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(server.state == .ready ? Color.accentColor : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text(verbatim: server.configuration.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(selected ? Color.primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        IndustrialBadge(
                            verbatim: String.localizedStringWithFormat(
                                String(localized: "%lld tools"), enabledToolCount),
                            tint: selected ? .accentColor : .secondary
                        )
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(server.state != .ready || enabledToolCount == 0)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
#endif

            private var currentModelToolCapable: Bool {
                let defaults = UserDefaults.standard
                let supportsFC = defaults.object(forKey: "currentModelSupportsFunctionCalling") as? Bool ?? false
                let isRemoteModel = defaults.object(forKey: "currentModelIsRemote") as? Bool ?? false
                let localFormat: ModelFormat? = isRemoteModel ? nil : vm.loadedModelFormat
                return !vm.afmChatToolsUnavailable && (localFormat == nil || supportsFC)
            }

            private var contextCapabilityItems: [ContextCapabilityItem] {
                let permissions = vm.activeToolPermissions
                let toolCapable = currentModelToolCapable
                let webAvailable = toolCapable && settings.webSearchEnabled
                let pythonAvailable = toolCapable && settings.pythonEnabled && PythonRuntime.status().isAvailable
                let memoryAvailable = toolCapable && settings.memoryEnabled
                let ragAvailable = vm.activeSessionDataset?.isIndexed == true

                return [
                    ContextCapabilityItem(
                        id: .web,
                        title: String(localized: "Web"),
                        isOn: settings.webSearchArmed,
                        isAvailable: webAvailable
                    ),
                    ContextCapabilityItem(
                        id: .python,
                        title: String(localized: "Python"),
                        isOn: settings.pythonArmed,
                        isAvailable: pythonAvailable
                    ),
                    ContextCapabilityItem(
                        id: .memory,
                        title: String(localized: "Memory"),
                        isOn: permissions.memory,
                        isAvailable: memoryAvailable
                    ),
                    ContextCapabilityItem(
                        id: .rag,
                        title: String(localized: "RAG"),
                        isOn: permissions.datasetRetrieval,
                        isAvailable: ragAvailable
                    ),
                    ContextCapabilityItem(
                        id: .datasets,
                        title: String(localized: "Datasets"),
                        isOn: settings.datasetSearchToolEnabled,
                        isAvailable: toolCapable
                    ),
                    ContextCapabilityItem(
                        id: .charts,
                        title: String(localized: "Charts"),
                        isOn: settings.chartToolEnabled,
                        isAvailable: toolCapable
                    ),
                    ContextCapabilityItem(
                        id: .calendar,
                        title: String(localized: "Calendar"),
                        isOn: settings.calendarToolEnabled,
                        isAvailable: toolCapable
                    )
                ]
            }

            private func toggleCapability(_ capability: ContextCapability) {
                switch capability {
                case .web:
                    let newValue = !settings.webSearchArmed
                    settings.webSearchArmed = newValue
                    vm.setToolPermissionForActiveSession(.webSearch, enabled: newValue)
                case .python:
                    let newValue = !settings.pythonArmed
                    settings.pythonArmed = newValue
                    vm.setToolPermissionForActiveSession(.python, enabled: newValue)
                case .memory:
                    vm.setToolPermissionForActiveSession(.memory, enabled: !vm.activeToolPermissions.memory)
                case .rag:
                    vm.setToolPermissionForActiveSession(
                        .datasetRetrieval,
                        enabled: !vm.activeToolPermissions.datasetRetrieval
                    )
                case .datasets:
                    settings.datasetSearchToolEnabled.toggle()
                case .charts:
                    settings.chartToolEnabled.toggle()
                case .calendar:
                    settings.calendarToolEnabled.toggle()
                }
            }

            private var chatToolEnabledCount: Int {
#if os(macOS)
                vm.activeToolPermissions.enabledCount + vm.activeToolPermissions.selectedMCPServerIDs.filter { id in
                    mcpManager.servers.contains { server in
                        server.id == id && server.state == .ready
                            && server.tools.contains { server.configuration.policy.isToolEnabled($0.originalName) }
                    }
                }.count
#else
                vm.activeToolPermissions.enabledCount
#endif
            }

            private var chatToolTotalCount: Int {
#if os(macOS)
                4 + mcpManager.servers.count
#else
                4
#endif
            }

            /// Per-conversation reasoning switch, shown only for models whose runtime can
            /// actually toggle thinking (vm.currentModelSupportsReasoning). Unlike Model
            /// Settings, flipping it here auto-saves to the loaded model's settings and
            /// takes effect on the next message — no reload needed.
            private var reasoningToggleRow: some View {
                let binding = Binding<Bool>(
                    get: { vm.reasoningEnabled },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            vm.setReasoningEnabled(newValue)
                        }
                    }
                )
                return HStack(spacing: 8) {
                    Circle()
                        .fill(vm.reasoningEnabled ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(LocalizedStringKey("Reasoning"))
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(Color.primary.opacity(0.6))
                    Spacer(minLength: 8)
                    Toggle("", isOn: binding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.accentColor)
#if os(macOS)
                        .controlSize(.small)
#endif
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(LocalizedStringKey("Reasoning")))
                .accessibilityValue(Text(reasoningStateCaption))
            }

            private var reasoningStateCaption: LocalizedStringKey {
                vm.reasoningEnabled
                    ? LocalizedStringKey("Thinks before replying")
                    : LocalizedStringKey("Replies without thinking")
            }

            private var chipVerticalPadding: CGFloat {
#if os(macOS)
                5
#else
                8
#endif
            }

            /// R4 mono-caps badge per the industrial dialect: on = 12% tint fill,
            /// tinted text, 5pt dot; off = hairline ghost; unavailable = dimmed ghost.
            private func toolToggleChip(_ item: ContextCapabilityItem) -> some View {
                let enabled = item.isOn && item.isAvailable
                let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                return Button {
                    withAnimation(reduceMotion ? nil : AppMotion.snappy) {
                        toggleCapability(item.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if enabled {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                        }
                        Text(verbatim: item.title)
                            .textCase(.uppercase)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
                            .lineLimit(1)
                    }
                    .foregroundStyle(enabled ? Color.accentColor : Color.primary.opacity(0.55))
                    .padding(.horizontal, 9)
                    .padding(.vertical, chipVerticalPadding)
                    .background(shape.fill(enabled ? Color.accentColor.opacity(0.12) : .clear))
                    .overlay(
                        shape.stroke(
                            enabled ? .clear : Color.primary.opacity(0.14),
                            lineWidth: 1
                        )
                    )
                    .opacity(item.isAvailable ? 1 : 0.45)
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .disabled(!item.isAvailable)
                .accessibilityLabel(Text(item.title))
                .accessibilityAddTraits(enabled ? .isSelected : [])
            }

            /// Leading-aligned wrap for the capability chips; hug-width chips flow
            /// onto as many rows as the column needs.
            private struct ChipFlowLayout: Layout {
                var horizontalSpacing: CGFloat = 6
                var verticalSpacing: CGFloat = 6

                func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
                    guard !subviews.isEmpty else { return .zero }
                    let maxWidth = proposal.width ?? .infinity
                    var x: CGFloat = 0
                    var y: CGFloat = 0
                    var rowHeight: CGFloat = 0
                    var usedWidth: CGFloat = 0
                    for subview in subviews {
                        let size = subview.sizeThatFits(.unspecified)
                        if x > 0 && x + size.width > maxWidth {
                            x = 0
                            y += rowHeight + verticalSpacing
                            rowHeight = 0
                        }
                        rowHeight = max(rowHeight, size.height)
                        x += size.width
                        usedWidth = max(usedWidth, x)
                        x += horizontalSpacing
                    }
                    return CGSize(width: min(usedWidth, maxWidth), height: y + rowHeight)
                }

                func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
                    let maxWidth = bounds.width
                    var x = bounds.minX
                    var y = bounds.minY
                    var rowHeight: CGFloat = 0
                    for subview in subviews {
                        let size = subview.sizeThatFits(.unspecified)
                        if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                            x = bounds.minX
                            y += rowHeight + verticalSpacing
                            rowHeight = 0
                        }
                        subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                        rowHeight = max(rowHeight, size.height)
                        x += size.width + horizontalSpacing
                    }
                }
            }

            private func toolPermissionBinding(_ kind: ChatVM.ChatToolPermissionKind) -> Binding<Bool> {
                Binding(
                    get: {
                        let permissions = vm.activeToolPermissions
                        switch kind {
                        case .webSearch: return permissions.webSearch
                        case .python: return permissions.python
                        case .memory: return permissions.memory
                        case .datasetRetrieval: return permissions.datasetRetrieval
                        }
                    },
                    set: { enabled in
                        vm.setToolPermissionForActiveSession(kind, enabled: enabled)
                    }
                )
            }

            private var contextSliceTitles: [String: String] {
                [
                    "messages": String(localized: "Messages"),
                    "system": String(localized: "System"),
                    "tools": String(localized: "Tools"),
                    "retrieval": String(localized: "Retrieval"),
                    "images": String(localized: "Images"),
                    "typed": String(localized: "Draft")
                ]
            }

            /// Shade of the health tint for a slice — darker (more opaque) for the
            /// largest concept (messages) fading to lighter for the draft.
            private func contextSliceColor(_ tint: Color, shade: Double) -> Color {
                tint.opacity(0.32 + shade * 0.6)
            }

            private var contextBudgetMeter: some View {
                let snapshot = contextMeterSnapshot
                let slices = snapshot.slices(titles: contextSliceTitles)
                return VStack(alignment: .leading, spacing: 10) {
                    IndustrialSectionHeader("Context", dotColor: snapshot.tint) {
                        Text(verbatim: "\(Self.shortTokenLabel(snapshot.usedTokens)) / \(Self.shortTokenLabel(snapshot.contextWindow))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.4))
                    }

                    // Single health-tinted bar, split into shaded segments per consumer.
                    segmentedContextBar(slices: slices, snapshot: snapshot)
                        .frame(height: 3)

                    HStack(spacing: 6) {
                        contextStat(String(localized: "Prompt"), snapshot.usedTokens, tint: snapshot.tint)
                        contextStatSeparator
                        contextStat(String(localized: "Reserve"), snapshot.reservedResponseTokens)
                        contextStatSeparator
                        contextStat(String(localized: "Free space"), snapshot.freeTokens)
                    }
                    .minimumScaleFactor(0.75)

                    Button {
                        // @AppStorage writes outside the initiating transaction, so the
                        // value-scoped animation below owns this disclosure transition.
                        contextBreakdownExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Text(LocalizedStringKey("Breakdown"))
                                .textCase(.uppercase)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(0.5)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(contextBreakdownExpanded ? 180 : 0))
                                .animation(
                                    reduceMotion ? nil : .easeInOut(duration: 0.16),
                                    value: contextBreakdownExpanded
                                )
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .padding(.top, 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if contextBreakdownExpanded {
                        VStack(spacing: 0) {
                            ForEach(slices) { slice in
                                contextBreakdownRow(
                                    color: contextSliceColor(snapshot.tint, shade: slice.shade),
                                    title: slice.title,
                                    value: slice.value,
                                    window: snapshot.contextWindow
                                )
                            }
                            if snapshot.reservedResponseTokens > 0 {
                                contextBreakdownRow(
                                    color: Color.secondary.opacity(0.3),
                                    title: String(localized: "Reserve"),
                                    value: snapshot.reservedResponseTokens,
                                    window: snapshot.contextWindow
                                )
                            }
                            contextBreakdownRow(
                                color: Color.secondary.opacity(0.14),
                                title: String(localized: "Free space"),
                                value: snapshot.freeTokens,
                                window: snapshot.contextWindow
                            )
                        }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: contextBreakdownExpanded)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(String.localizedStringWithFormat(
                    String(localized: "Context budget: %@ of %@ used"),
                    Self.shortTokenLabel(snapshot.usedTokens),
                    Self.shortTokenLabel(snapshot.contextWindow)
                )))
            }

            private var contextStatSeparator: some View {
                Text(verbatim: "·")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.25))
            }

            private func contextStat(_ title: String, _ value: Int, tint: Color? = nil) -> some View {
                HStack(spacing: 5) {
                    Text(verbatim: title)
                        .textCase(.uppercase)
                        .tracking(0.3)
                        .foregroundStyle(Color.primary.opacity(0.4))
                    Text(verbatim: value.formatted())
                        .foregroundStyle(tint ?? Color.primary.opacity(0.7))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
            }

            /// One bar in the current health color, divided into shaded segments sized
            /// against the full context window; the unfilled remainder is free space.
            private func segmentedContextBar(slices: [ContextMeterSnapshot.Slice],
                                             snapshot: ContextMeterSnapshot) -> some View {
                let window = Double(max(1, snapshot.contextWindow))
                return GeometryReader { proxy in
                    let w = proxy.size.width
                    HStack(spacing: 0) {
                        ForEach(slices) { slice in
                            Rectangle()
                                .fill(contextSliceColor(snapshot.tint, shade: slice.shade))
                                .frame(width: max(0, w * Double(slice.value) / window))
                        }
                        if snapshot.reservedResponseTokens > 0 {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(width: max(0, w * Double(snapshot.reservedResponseTokens) / window))
                        }
                        Rectangle().fill(Color.clear)
                    }
                }
                .background(Color.secondary.opacity(0.14))
                .clipShape(Capsule(style: .continuous))
            }

            private func contextBreakdownRow(color: Color, title: String, value: Int, window: Int) -> some View {
                let fraction = window > 0 ? Double(value) / Double(window) : 0
                return VStack(spacing: 0) {
                    IndustrialHairline()
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(color)
                            .frame(width: 5, height: 5)
                        Text(verbatim: title)
                            .textCase(.uppercase)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(0.3)
                            .foregroundStyle(Color.primary.opacity(0.6))
                        Spacer(minLength: 6)
                        Text(verbatim: value.formatted())
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.7))
                        Text(verbatim: Self.contextPercentLabel(fraction))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.4))
                            .frame(width: 46, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
            }

            private static func contextPercentLabel(_ fraction: Double) -> String {
                let pct = max(0, fraction) * 100
                if pct > 0 && pct < 0.1 { return "<0.1%" }
                return String(format: "%.1f%%", pct)
            }

            private func estimatedTokenCount(_ value: String) -> Int {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return 0 }
                let wordEstimate = trimmed.split { $0.isWhitespace || $0.isNewline }.count
                let charEstimate = Int(ceil(Double(trimmed.count) / 4.0))
                return max(1, max(wordEstimate, charEstimate))
            }

            private static func shortTokenLabel(_ value: Int) -> String {
                if value >= 10_000 {
                    return String(format: "%.1fk", Double(value) / 1000.0)
                }
                if value >= 1_000 {
                    return String(format: "%.1fk", Double(value) / 1000.0)
                }
                return "\(value)"
            }

            private var pendingImagesWithIndices: [(index: Int, url: URL)] {
                Array(vm.pendingImageURLs.prefix(5).enumerated()).map { (index: $0.offset, url: $0.element) }
            }

            /// Compact attachment tray: one quiet surface, tight rows, no
            /// oversized glass card.
            private var pendingMediaTray: some View {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let error = vm.audioRecordingError, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            audioRecordingErrorRow(error)
                            if !vm.pendingMediaAttachments.isEmpty {
                                Divider()
                                    .padding(.vertical, 8)
                            }
                        }
                        ForEach(Array(vm.pendingMediaAttachments.enumerated()), id: \.element.id) { index, attachment in
                            pendingMediaRow(attachment)
                            if index < vm.pendingMediaAttachments.count - 1 {
                                Divider()
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: trayMaxHeight)
                .background(
                    RoundedRectangle(cornerRadius: ChatTheme.controlRadius, style: .continuous)
                        .fill(ChatTheme.cardSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: ChatTheme.controlRadius, style: .continuous)
                                .strokeBorder(ChatTheme.hairline, lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: ChatTheme.controlRadius, style: .continuous))
            }

            private var trayMaxHeight: CGFloat { 220 }

            /// Composer chip for an attached document. Observes DatasetManager directly so
            /// per-tick embedding progress re-renders only this leaf — not the whole composer
            /// or chat body (which is why a just-attached PDF used to make the chat laggy).
            private struct AttachedDocChip: View {
                @EnvironmentObject var datasetManager: DatasetManager
                let doc: AttachedDocumentState
                let onRemove: () -> Void

                var body: some View {
                    let multi = doc.files.count > 1
                    HStack(alignment: multi ? .top : .center, spacing: 10) {
                        Image(systemName: multi ? "doc.on.doc.fill" : "doc.text.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.blue)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(multi
                                 ? String.localizedStringWithFormat(String(localized: "%d documents"), doc.files.count)
                                 : doc.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if multi {
                                Text(doc.files.map(\.name).joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            switch doc.phase {
                            case .preparing:
                                let status = doc.datasetID.flatMap { datasetManager.processingStatus[$0] }
                                Text(Self.statusLine(status))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                ProgressView(value: max(0, min(status?.progress ?? 0, 1)))
                                    .progressViewStyle(.linear)
                                    .tint(.blue)
                            case .ready:
                                Label(Self.readyLine(expiresAt: doc.expiresAt), systemImage: "checkmark.seal.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            case .failed(let message):
                                Label(message, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        Button(action: onRemove) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(multi ? "Remove documents" : "Remove document"))
                    }
                    .padding(.vertical, 2)
                }

                private static func statusLine(_ status: DatasetProcessingStatus?) -> String {
                    let stageText: String
                    switch status?.stage {
                    case .some(.compressing): stageText = String(localized: "Compressing…")
                    case .some(.embedding): stageText = String(localized: "Embedding…")
                    case .some(.completed): stageText = String(localized: "Finishing…")
                    case .some(.failed): stageText = String(localized: "Failed")
                    case .some(.extracting), .none: stageText = String(localized: "Extracting text…")
                    }
                    let pct = Int(max(0, min(status?.progress ?? 0, 1)) * 100)
                    return "\(stageText) \(pct)%"
                }

                private static func readyLine(expiresAt: Date?) -> String {
                    guard let expiresAt else {
                        return String(localized: "Ready — ask about this document")
                    }
                    let remaining = expiresAt.timeIntervalSinceNow
                    guard remaining > 0 else { return String(localized: "Ready") }
                    let hours = Int(remaining / 3600)
                    if hours >= 24 {
                        return String.localizedStringWithFormat(String(localized: "Ready · expires in %dd"), hours / 24)
                    } else if hours >= 1 {
                        return String.localizedStringWithFormat(String(localized: "Ready · expires in %dh"), hours)
                    } else {
                        return String.localizedStringWithFormat(String(localized: "Ready · expires in %dm"), max(1, Int(remaining / 60)))
                    }
                }
            }

#if canImport(AVFoundation)
            // Voice-note recording is started from the "+" menu; this button stays its
            // stop control while a recording is live, and is live dictation otherwise.
            private func voiceRecordButton(isDisabled: Bool) -> some View {
                let isRecording = vm.isRecordingAudio
                let isDictating = vm.isDictating
                let isActive = isRecording || isDictating
#if os(macOS)
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
#else
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
#endif

                return Button {
                    if isRecording {
                        Task { await vm.toggleAudioRecording() }
                    } else {
#if canImport(Speech)
                        Task { await vm.toggleLiveDictation() }
#else
                        Task { await vm.toggleAudioRecording() }
#endif
                    }
                } label: {
                    ZStack {
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
#if os(macOS)
                            .font(.system(size: 13, weight: .medium))
#else
                            .font(.system(size: 17, weight: .semibold))
#endif
                        if isActive {
                            VStack {
                                Spacer()
                                MicLevelBars(meter: vm.micLevelMeter)
#if os(macOS)
                                    // MicLevelBars hardcodes white bars; multiply
                                    // to the tint so they read on the flat chip.
                                    .colorMultiply(Color.red)
                                    .padding(.bottom, 2)
#else
                                    .padding(.bottom, 6)
#endif
                            }
                        }
                    }
                    .frame(width: controlHeight, height: controlHeight)
#if os(macOS)
                    .background(shape.fill(isActive ? Color.red.opacity(0.12) : ChatTheme.quietSurface))
                    .overlay(
                        shape.strokeBorder(
                            isActive ? Color.red.opacity(0.28) : Color.clear,
                            lineWidth: 0.8
                        )
                    )
                    .foregroundStyle(isActive ? Color.red : Color.secondary)
#else
                    .background(
                        shape
                            .fill(Color.clear)
                            .glassifyIfAvailable(in: shape)
                            .overlay(
                                shape.fill(
                                    isActive
                                        ? Color.red.opacity(0.34)
                                        : Color.white.opacity(0.06)
                                )
                            )
                            .overlay(
                                shape.strokeBorder(
                                    isActive
                                        ? Color.red.opacity(0.52)
                                        : Color.white.opacity(0.22),
                                    lineWidth: 0.8
                                )
                            )
                    )
                    .foregroundStyle(isActive ? Color.white : Color.secondary)
#endif
                    .overlay(alignment: .top) {
                        if isRecording, let started = vm.audioRecordingStartedAt {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                Text(Self.recordingElapsedLabel(from: started, to: context.date))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
#if os(macOS)
                                    .foregroundStyle(Color.red)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Color.red.opacity(0.12))
                                    )
#else
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.red.opacity(0.7))
                                    )
#endif
                                    .offset(y: -8)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
#if os(macOS)
                .help(LocalizedStringKey(
                    isRecording ? "Stop Recording" : (isDictating ? "Stop Dictation" : "Start Dictation")
                ))
#endif
                .accessibilityLabel(Text(LocalizedStringKey(
                    isRecording ? "Stop Recording" : (isDictating ? "Stop Dictation" : "Start Dictation")
                )))
                .accessibilityHint(Text(LocalizedStringKey("Dictates speech into the message field.")))
            }

            private func voiceModeButton(isDisabled: Bool) -> some View {
#if os(macOS)
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
#else
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
#endif
                return Button {
                    focus.wrappedValue = false
                    showVoiceMode = true
                } label: {
                    Image(systemName: "waveform")
#if os(macOS)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: controlHeight, height: controlHeight)
                        .background(shape.fill(showVoiceMode ? Color.accentColor.opacity(0.12) : ChatTheme.quietSurface))
                        .overlay(
                            shape.strokeBorder(
                                showVoiceMode ? Color.accentColor.opacity(0.28) : Color.clear,
                                lineWidth: 0.8
                            )
                        )
                        .foregroundStyle(showVoiceMode ? Color.accentColor : Color.secondary)
#else
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: controlHeight, height: controlHeight)
                        .background(
                            shape
                                .fill(Color.clear)
                                .glassifyIfAvailable(in: shape)
                                .overlay(shape.fill(Color.white.opacity(0.06)))
                                .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8))
                        )
                        .foregroundStyle(Color.secondary)
#endif
                }
                .buttonStyle(.plain)
                .disabled(isDisabled || vm.isRecordingAudio || vm.isDictating || vm.isStreaming || !hasActiveChatModel)
#if os(iOS) || os(visionOS)
                .fullScreenCover(isPresented: $showVoiceMode) {
                    VoiceModeView(chatVM: vm)
                }
#else
                .sheet(isPresented: $showVoiceMode) {
                    VoiceModeView(chatVM: vm)
                }
                .help("Voice Mode")
#endif
                .accessibilityLabel(Text("Voice Mode"))
                .accessibilityHint(Text("Start a spoken conversation."))
            }

            private static func recordingElapsedLabel(from start: Date, to now: Date) -> String {
                let elapsed = max(0, Int(now.timeIntervalSince(start)))
                return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            }
#endif

            private func audioRecordingErrorRow(_ message: String) -> some View {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white, Color.red)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.red.opacity(0.10))
                            )

                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            vm.audioRecordingError = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.primary.opacity(0.06)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(LocalizedStringKey("Dismiss")))
                    }

                    recoveryActionsRow(message: message, attachment: nil)
                }
            }

            private func pendingMediaRow(_ attachment: ChatMediaAttachment) -> some View {
                VStack(alignment: .leading, spacing: 8) {
                    mediaHeader(for: attachment)

                    // "Ready to transcribe" is implied by the Transcribe button;
                    // only surface standalone status text when something is wrong.
                    if attachment.status == .failed, attachment.status.showsStandaloneStatusLabel {
                        Text(mediaStatusText(attachment))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if attachment.status == .transcribing,
                       let partial = attachment.partialTranscript,
                       !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(partial)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(ChatTheme.quietSurface)
                            )
                    }

                    if let transcript = attachment.transcript {
                        Text(transcript.provenanceSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    mediaActionRow(for: attachment)
                }
                .accessibilityElement(children: .combine)
            }

            private func mediaHeader(for attachment: ChatMediaAttachment) -> some View {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: attachment.kind.iconName)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Color.accentColor)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor.opacity(0.10))
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.transcript?.displaySourceName ?? attachment.originalFilename)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let mediaDetailLabel = attachment.mediaDetailLabel {
                            Text(mediaDetailLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    Button {
                        if attachment.hasCompletedTranscript && transcriptSaveFeedback[attachment.id]?.isSaved != true {
                            pendingRemovalAttachment = attachment
                        } else {
                            vm.removePendingMediaAttachment(id: attachment.id)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(LocalizedStringKey("Remove")))
                }
            }

            private func mediaStatusBadge(_ status: ChatMediaTranscriptionStatus) -> some View {
                Text(LocalizedStringKey(mediaStatusBadgeKey(status)))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(mediaStatusBadgeForeground(status))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(mediaStatusBadgeBackground(status))
                    )
            }

            private func mediaStatusBadgeKey(_ status: ChatMediaTranscriptionStatus) -> String {
                status.badgeLocalizationKey
            }

            private func mediaStatusBadgeForeground(_ status: ChatMediaTranscriptionStatus) -> Color {
                switch status {
                case .failed:
                    return .red
                case .completed:
                    return .green
                case .transcribing:
                    return .accentColor
                case .notStarted:
                    return .secondary
                }
            }

            private func mediaStatusBadgeBackground(_ status: ChatMediaTranscriptionStatus) -> Color {
                switch status {
                case .failed:
                    return Color.red.opacity(0.12)
                case .completed:
                    return Color.green.opacity(0.12)
                case .transcribing:
                    return Color.accentColor.opacity(0.12)
                case .notStarted:
                    return Color.primary.opacity(0.06)
                }
            }

            @ViewBuilder
            private func mediaActionRow(for attachment: ChatMediaAttachment) -> some View {
                if attachment.status == .transcribing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text(LocalizedStringKey("Transcribing..."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        cancelTranscriptionButton(for: attachment)
                    }
                } else if attachment.hasCompletedTranscript {
                    let saveFeedback = transcriptSaveFeedback[attachment.id]
                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            completedTranscriptActionsWide(for: attachment, saveFeedback: saveFeedback)
                            completedTranscriptActionsStacked(for: attachment, saveFeedback: saveFeedback)
                        }

                        if let saveFeedback, let message = saveFeedback.message {
                            Text(message)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(saveFeedback.isSaved ? Color.green : (saveFeedback.isSaving ? Color.secondary : Color.red))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if attachment.status != .completed {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = attachment.errorMessage, attachment.status == .failed {
                            recoveryActionsRow(message: error, attachment: attachment)
                        }

                        HStack {
                            Spacer(minLength: 0)
                            Button {
                                beginTranscribingWithRemoteConfirmation(attachment)
                            } label: {
                                Label {
                                    Text(LocalizedStringKey("Transcribe"))
                                } icon: {
                                    Image(systemName: "waveform")
                                }
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            }
                            .buttonStyle(.industrial(.prominent))
                            .controlSize(.small)
                        }
                    }
                }
            }

            private func completedTranscriptActionsWide(for attachment: ChatMediaAttachment, saveFeedback: TranscriptSaveFeedback?) -> some View {
                HStack(spacing: 8) {
                    transcriptTextActionButton(title: "Summarize", systemImage: "text.bubble") {
                        performTranscriptQuickAction(.summarize, for: attachment)
                    }

                    transcriptTextActionButton(title: "Review", systemImage: "doc.text.magnifyingglass") {
                        transcriptReviewAttachment = attachment
                    }

                    Spacer(minLength: 0)

                    transcriptMoreActionsMenu(for: attachment)
                    transcriptSaveMenu(for: attachment, saveFeedback: saveFeedback)
                }
            }

            private func completedTranscriptActionsStacked(for attachment: ChatMediaAttachment, saveFeedback: TranscriptSaveFeedback?) -> some View {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        transcriptTextActionButton(title: "Summarize", systemImage: "text.bubble") {
                            performTranscriptQuickAction(.summarize, for: attachment)
                        }

                        transcriptTextActionButton(title: "Review", systemImage: "doc.text.magnifyingglass") {
                            transcriptReviewAttachment = attachment
                        }
                    }

                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        transcriptMoreActionsMenu(for: attachment)
                        transcriptSaveMenu(for: attachment, saveFeedback: saveFeedback)
                    }
                }
            }

            private func cancelTranscriptionButton(for attachment: ChatMediaAttachment) -> some View {
                Button {
                    vm.cancelPendingMediaTranscription(id: attachment.id)
                } label: {
                    Label {
                        Text(LocalizedStringKey("Cancel"))
                    } icon: {
                        Image(systemName: "xmark.circle")
                    }
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                }
                .buttonStyle(.industrial(.quiet))
                .controlSize(.small)
            }

            private func transcriptTextActionButton(
                title: LocalizedStringKey,
                systemImage: String,
                minWidth: CGFloat? = nil,
                action: @escaping () -> Void
            ) -> some View {
                Button(action: action) {
                    Label {
                        Text(title)
                    } icon: {
                        Image(systemName: systemImage)
                    }
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.industrial(.quiet))
                .controlSize(.small)
                .frame(minWidth: minWidth)
            }

            private func transcriptIconActionLabel(systemImage: String) -> some View {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 20)
            }

            private func transcriptMoreActionsMenu(for attachment: ChatMediaAttachment) -> some View {
                Menu {
                    ForEach(TranscriptQuickAction.allCases.filter { $0 != .summarize && $0 != .ask }) { action in
                        Button {
                            performTranscriptQuickAction(action, for: attachment)
                        } label: {
                            Label(action.titleKey, systemImage: action.iconName)
                        }
                    }
                } label: {
                    transcriptIconActionLabel(systemImage: "ellipsis")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(Text(LocalizedStringKey("More actions")))
                .help(Text("More actions"))
            }

            private func transcriptSaveMenu(for attachment: ChatMediaAttachment, saveFeedback: TranscriptSaveFeedback?) -> some View {
                Menu {
                    Button {
                        saveTranscriptAttachment(attachment)
                    } label: {
                        Label(LocalizedStringKey("Save to Stored"), systemImage: "tray.and.arrow.down")
                    }
                    Button {
                        existingDatasetSaveAttachment = attachment
                    } label: {
                        Label(LocalizedStringKey("Save to existing dataset"), systemImage: "folder.badge.plus")
                    }
                } label: {
                    if saveFeedback?.isSaving == true {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 26, height: 20)
                    } else {
                        transcriptIconActionLabel(systemImage: saveFeedback?.isSaved == true ? "checkmark" : "tray.and.arrow.down")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(saveFeedback?.isSaving == true || saveFeedback?.isSaved == true)
                .accessibilityLabel(Text(LocalizedStringKey("Save transcript")))
                .help(Text("Save transcript to Stored"))
            }

            private func saveTranscriptAttachment(_ attachment: ChatMediaAttachment) {
                guard transcriptSaveFeedback[attachment.id]?.isSaving != true else { return }
                transcriptSaveFeedback[attachment.id] = .saving
                Task {
                    let result = await vm.saveTranscriptAttachmentAsDataset(attachment)
                    await MainActor.run {
                        switch result {
                        case .success(let dataset):
                            transcriptSaveFeedback[attachment.id] = .saved(dataset.name)
                        case .failure(let error):
                            transcriptSaveFeedback[attachment.id] = .failed(
                                String.localizedStringWithFormat(
                                    String(localized: "Transcript save failed: %@"),
                                    error.localizedDescription
                                )
                            )
                        }
                    }
                }
            }

            private func saveTranscriptAttachment(_ attachment: ChatMediaAttachment, toExistingDataset dataset: LocalDataset) {
                guard transcriptSaveFeedback[attachment.id]?.isSaving != true else { return }
                transcriptSaveFeedback[attachment.id] = .saving
                Task {
                    let result = await vm.saveTranscriptAttachment(attachment, toExistingDataset: dataset)
                    await MainActor.run {
                        switch result {
                        case .success(let dataset):
                            transcriptSaveFeedback[attachment.id] = .saved(dataset.name)
                        case .failure(let error):
                            transcriptSaveFeedback[attachment.id] = .failed(
                                String.localizedStringWithFormat(
                                    String(localized: "Transcript save failed: %@"),
                                    error.localizedDescription
                                )
                            )
                        }
                    }
                }
            }

            private func latestPendingAttachment(matching attachment: ChatMediaAttachment) -> ChatMediaAttachment? {
                vm.pendingMediaAttachments.first { $0.id == attachment.id }
            }

            private func performTranscriptQuickAction(_ action: TranscriptQuickAction, for attachment: ChatMediaAttachment) {
                let title = attachment.transcript?.displaySourceName ?? attachment.originalFilename
                text = action.prompt(for: title)
                if action == .ask {
                    focus.wrappedValue = true
                } else {
                    performSend()
                }
            }

            private func beginTranscribingWithRemoteConfirmation(_ attachment: ChatMediaAttachment) {
                if TranscriptionSettings.selectedEngineID == .audioLanguageModel,
                   !TranscriptionSettings.hasConfirmedRemoteUpload {
                    remoteUploadConfirmationAttachment = attachment
                    return
                }
                vm.beginTranscribingPendingMediaAttachment(id: attachment.id)
            }

            @ViewBuilder
            private func recoveryActionsRow(message: String, attachment: ChatMediaAttachment?) -> some View {
                let actions = ASRRecoveryAction.actions(
                    for: message,
                    includeRetry: attachment != nil,
                    includeRemoteEndpoint: TranscriptionSettings.selectedEngineID == .audioLanguageModel
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(actions) { action in
                            Button {
                                handleRecoveryAction(action, attachment: attachment)
                            } label: {
                                Label(action.titleKey, systemImage: action.iconName)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(.industrial(.quiet))
                            .controlSize(.mini)
                        }
                    }
                }
            }

            private func handleRecoveryAction(_ action: ASRRecoveryAction, attachment: ChatMediaAttachment?) {
                switch action {
                case .retry:
                    if let attachment {
                        beginTranscribingWithRemoteConfirmation(attachment)
                    }
                case .openSettings, .chooseLocale, .downloadWhisperModel, .configureEndpoint:
                    tabRouter.selection = .settings
                }
            }

            private func mediaStatusText(_ attachment: ChatMediaAttachment) -> String {
                switch attachment.status {
                case .notStarted:
                    return String(localized: "Ready to transcribe")
                case .transcribing:
                    return String(localized: "Transcribing...")
                case .completed:
                    return String(localized: "Transcript ready")
                case .failed:
                    return attachment.errorMessage ?? String(localized: "Transcription failed")
                }
            }

            private var pendingImagesTray: some View {
                VStack(alignment: .leading, spacing: 6) {
                    let estimate = pendingImageBudgetEstimate
                    HStack(spacing: 8) {
                        Label(LocalizedStringKey("Images"), systemImage: "photo.stack")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(pendingImageBudgetTint(estimate.status))
                        Text(verbatim: "\(estimate.imageCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(pendingImageBudgetSummary(estimate))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(pendingImagesWithIndices, id: \.url.path) { item in
                                pendingImageTile(index: item.index, url: item.url)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: UIConstants.largeCornerRadius, style: .continuous)
                        .fill(Color(.secondarySystemBackground).opacity(0.72))
                        .overlay(
                            RoundedRectangle(cornerRadius: UIConstants.largeCornerRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
                        )
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: vm.pendingImageURLs.count)
            }

            private var pendingImageBudgetEstimate: ImagePromptBudgetEstimate {
                let totalBytes = vm.pendingImageURLs.reduce(Int64(0)) { total, url in
                    total + pendingImageFileSizeBytes(for: url)
                }
                return ImagePromptBudgetEstimator.estimate(
                    imageCount: vm.pendingImageURLs.count,
                    totalFileBytes: totalBytes,
                    usablePromptTokens: ChatVM.promptBudget(for: vm.contextLimit).usablePromptTokens
                )
            }

            private func pendingImageBudgetSummary(_ estimate: ImagePromptBudgetEstimate) -> String {
                let totalSize = estimate.totalFileBytes > 0
                    ? ByteCountFormatter.string(fromByteCount: estimate.totalFileBytes, countStyle: .file)
                    : String(localized: "Size unknown")
                return String.localizedStringWithFormat(
                    String(localized: "%@ · %@ img tok"),
                    totalSize,
                    Self.shortTokenLabel(estimate.estimatedPromptTokens)
                )
            }

            private func pendingImageBudgetTint(_ status: ImagePromptBudgetEstimate.Status) -> Color {
                switch status {
                case .comfortable: return .green
                case .tight: return .orange
                case .overBudget: return .red
                }
            }

            @ViewBuilder
            private func pendingImageTile(index: Int, url: URL) -> some View {
                let thumbnail = vm.pendingThumbnail(for: url)
                let isRecentlyAdded = (recentlyAddedImageURL == url)

                VStack(alignment: .leading, spacing: 5) {
                    ZStack(alignment: .topTrailing) {
                        pendingImageContent(thumbnail)
                            .frame(width: 88, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
                            )
                            .overlay(alignment: .bottomTrailing) {
                                if isRecentlyAdded {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(Color.white, Color.green)
                                        .padding(6)
                                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                                }
                            }

                        Button(action: { vm.removePendingImage(at: index) }) {
                            Image(systemName: "xmark")
                                .foregroundColor(.white)
                                .font(.system(size: 10, weight: .black))
                                .padding(6)
                                .background(
                                    Circle()
                                        .fill(Color.black.opacity(0.72))
                                        .overlay(
                                            Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                                        )
                                )
                                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                        .padding(5)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(pendingImageDimensionLabel(thumbnail))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(pendingImageBudgetLabel(for: url))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 88, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(pendingImagePreflightAccessibilityLabel(thumbnail: thumbnail, url: url)))
                }
                .frame(width: 88, alignment: .leading)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.9).combined(with: .opacity),
                    removal: .scale(scale: 0.92).combined(with: .opacity)
                ))
            }

            private func pendingImageDimensionLabel(_ thumbnail: UIImage?) -> String {
                guard let size = thumbnail?.size else { return String(localized: "Preparing image") }
                let scale = max(thumbnail?.scale ?? 1, 1)
                let width = max(1, Int((size.width * scale).rounded()))
                let height = max(1, Int((size.height * scale).rounded()))
                return "\(width)x\(height)"
            }

            private func pendingImageBudgetLabel(for url: URL) -> String {
                let fileSize = pendingImageFileSizeLabel(for: url)
                return String.localizedStringWithFormat(
                    String(localized: "%@ · %@ img tok"),
                    fileSize,
                    Self.shortTokenLabel(576)
                )
            }

            private func pendingImageFileSizeLabel(for url: URL) -> String {
                let bytes = pendingImageFileSizeBytes(for: url)
                guard bytes > 0 else {
                    return String(localized: "Size unknown")
                }
                return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }

            private func pendingImageFileSizeBytes(for url: URL) -> Int64 {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? NSNumber else {
                    return 0
                }
                return max(0, size.int64Value)
            }

            private func pendingImagePreflightAccessibilityLabel(thumbnail: UIImage?, url: URL) -> String {
                String.localizedStringWithFormat(
                    String(localized: "Image preflight: %@, %@."),
                    pendingImageDimensionLabel(thumbnail),
                    pendingImageBudgetLabel(for: url)
                )
            }

            @ViewBuilder
            private func pendingImageContent(_ thumbnail: UIImage?) -> some View {
                if let ui = thumbnail {
                    Image(platformImage: ui)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(
                            ProgressView().scaleEffect(0.6)
                        )
                }
            }

            private func handlePendingImagesChange(from oldURLs: [URL], to newURLs: [URL]) {
                let previous = Set(oldURLs)
                guard let latestAdded = newURLs.last(where: { !previous.contains($0) }) else { return }

                pendingImageFeedbackTask?.cancel()
#if os(iOS)
                Haptics.impact(.light)
#endif
                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                    recentlyAddedImageURL = latestAdded
                }

                pendingImageFeedbackTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        if recentlyAddedImageURL == latestAdded {
                            recentlyAddedImageURL = nil
                        }
                    }
                }
            }

        }

        var body: some View {
            NavigationStack {
#if os(macOS)
                macChatContainer
#else
                ZStack(alignment: .leading) {
                    chatContent
                        .guideHighlight(.chatCanvas)
                    if showSidebar {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture { withAnimation { showSidebar = false } }
                            // Fade the scrim in step with the sidebar slide instead of popping.
                            .transition(.opacity)
                        sidebar
                            .frame(width: currentDeviceWidth() * 0.48)
                            .transition(.move(edge: .leading))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
#if os(iOS) || os(visionOS)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        modelHeader
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        let slots = adaptiveTrailingSlots
                        HStack(spacing: 6) {
                            if slots >= 2 { sidebarToolbarButton }
                            moreToolbarMenu(includeSidebar: slots < 2, includeNewChat: slots == 0)
                            if slots >= 1 { newChatToolbarButton }
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
#endif
#endif
            }
#if os(macOS)
            .navigationTitle("Chat")
#endif
            .alert(item: $datasetManager.embedAlert) { info in
                Alert(title: Text(info.message))
            }
            .alert("Context Length Exceeded", isPresented: $showContextOverflowAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.contextOverflowAlertBody)
            }
            .alert(vm.memoryPromptBudgetAlertTitle, isPresented: $showMemoryPromptBudgetAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.memoryPromptBudgetAlertBody)
            }
            .sheet(isPresented: $showRuntimeInfo) {
                ChatRuntimeInfoSheet()
                    .environmentObject(vm)
                    .environmentObject(modelManager)
            }
            .sheet(isPresented: $showScratchpad) {
                ChatScratchpadSheet(
                    text: $scratchpadDraft,
                    titleKey: "Private Scratchpad",
                    placeholderKey: "Notes for this chat",
                    clearTitleKey: "Clear Scratchpad",
                    onCancel: { showScratchpad = false },
                    onSave: {
                        vm.setScratchpadForActiveSession(scratchpadDraft)
                        showScratchpad = false
                    },
                    onClear: {
                        scratchpadDraft = ""
                        vm.setScratchpadForActiveSession("")
                        showScratchpad = false
                    }
                )
            }
            .sheet(isPresented: $showChatInstructions) {
                ChatScratchpadSheet(
                    text: $chatInstructionsDraft,
                    titleKey: "Chat Instructions",
                    placeholderKey: "Instructions for this chat",
                    clearTitleKey: "Clear Instructions",
                    onCancel: { showChatInstructions = false },
                    onSave: {
                        vm.setChatInstructionsForActiveSession(chatInstructionsDraft)
                        showChatInstructions = false
                    },
                    onClear: {
                        chatInstructionsDraft = ""
                        vm.setChatInstructionsForActiveSession("")
                        showChatInstructions = false
                    }
                )
            }
            .sheet(isPresented: $showChatSnapshot) {
                ChatSnapshotSheet(
                    rows: chatSnapshotRows,
                    exportText: chatSnapshotExportText
                )
            }
            .sheet(isPresented: $showChatExportPack) {
                ChatExportPackSheet(
                    noteTitle: sessionDisplayTitle(for: vm.sessions.first { $0.id == vm.activeSessionID } ?? ChatVM.Session(title: "", messages: [], date: Date())),
                    markdownNote: chatMarkdownNoteText,
                    citationsJSON: chatCitationsJSONText,
                    promptReceipt: chatSnapshotExportText,
                    generationReplayJSON: chatGenerationReplayJSONText
                )
            }
            .sheet(isPresented: $showContextPlan) {
                ChatContextPlanSheet(
                    rows: contextPlanRows,
                    summary: contextPlanSummary
                )
            }
#if os(macOS)
            .onAppear { syncSidebarSettings() }
            .onChange(of: modelManager.loadedModel?.id) { _ in syncSidebarSettings() }
            .onReceive(modelManager.$modelSettings) { newMap in syncSidebarSettings(map: newMap) }
            .onChange(of: advancedSettings) { newValue in
                persistSidebarSettings(newValue)
            }
            .onChange(of: isAdvancedMode) { newValue in
                if !newValue {
                    withAnimation(.easeInOut(duration: 0.2)) { macChatChrome.showAdvancedControls = false }
                }
            }
            .onChange(of: macChatChrome.runtimeInfoRequested) { requested in
                if requested {
                    showRuntimeInfo = true
                    macChatChrome.runtimeInfoRequested = false
                }
            }
#endif
        }

#if os(macOS)
        private var macChatContainer: some View {
            HStack(spacing: 0) {
                macChatDrawer
                Divider()
                chatContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let cfRun = jspaceCounterfactual {
                    JSpaceCounterfactualPanel(
                        run: cfRun,
                        rerun: { vm.runJSpaceCounterfactual() },
                        close: { withAnimation(.easeInOut(duration: 0.2)) { vm.cancelJSpaceCounterfactual() } }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if isAdvancedMode && macChatChrome.showAdvancedControls {
                    AdvancedSettingsSidebar(
                        settings: $advancedSettings,
                        model: modelManager.loadedModel,
                        models: modelManager.downloadedModels,
                        hide: { withAnimation(.easeInOut(duration: 0.2)) { macChatChrome.showAdvancedControls = false } }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if macChatChrome.showJSpaceLens {
                    JSpaceLensSidebar(
                        hide: { withAnimation(.easeInOut(duration: 0.2)) { macChatChrome.showJSpaceLens = false } },
                        runCounterfactual: { vm.runJSpaceCounterfactual() }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.easeInOut(duration: 0.2), value: jspaceCounterfactual == nil)
            .onReceive(JSpaceLensController.shared.$counterfactual) { jspaceCounterfactual = $0 }
        }

        private var macChatDrawer: some View {
            ZStack(alignment: .topLeading) {
                AppTheme.sidebarBackground
                    .glassifyIfAvailable(in: Rectangle())
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Chats")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        ChatToolbarIconButton(systemImage: "plus", help: "New Chat") {
                            vm.startNewSession()
                        }
                        .contextMenu {
                            if vm.activeSessionDataset != nil {
                                Button {
                                    vm.startNewSession(carryingActiveDataset: false)
                                } label: {
                                    newChatWithoutDatasetLabel
                                }
                            }
                        }
                        .guideHighlight(.chatNewChatButton)
                    }
                    .padding(.horizontal, ChatTheme.spacingL)
                    .padding(.top, ChatTheme.spacingM)
                    .padding(.bottom, 6)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        TextField(LocalizedStringKey("Search chats"), text: $drawerFilterText)
                    }
                    .industrialField()
                    .padding(.horizontal, ChatTheme.spacingL)
                    .padding(.bottom, 4)

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredDrawerSessions) { session in
                                drawerRow(for: session)
                                    .contentShape(Rectangle())
                                    .onTapGesture { vm.select(session) }
                                    .contextMenu {
                                        Button(session.isFavorite ? "Remove Favorite" : "Favorite") {
                                            vm.toggleFavorite(session)
                                        }
                                        Button("Rename") {
                                            renameDraft = drawerTitle(for: session)
                                            sessionToRename = session
                                        }
                                        Button(role: .destructive) {
                                            sessionToDelete = session
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(.top, 12)
                        .padding(.horizontal, 8)
                    }

                    // Display preference pinned to the bottom of the sidebar:
                    // show the model's raw, unformatted output. Defaults off.
                    IndustrialHairline()
                    Toggle(isOn: $showRawAssistantOutput) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 11, weight: .medium))
                            Text("Show Raw Output")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(IndustrialToggleStyle())
                    .help("Show Raw Output")
                    .padding(.horizontal, ChatTheme.spacingL)
                    .padding(.vertical, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 264)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .guideHighlight(.chatSidebar)
            .confirmationDialog(
                "Delete chat \(sessionToDelete.map { drawerTitle(for: $0) } ?? "New chat")?",
                isPresented: Binding(
                    get: { sessionToDelete != nil },
                    set: { if !$0 { sessionToDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let session = sessionToDelete {
                        vm.delete(session)
                    }
                    sessionToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    sessionToDelete = nil
                }
            }
            .alert(
                "Rename",
                isPresented: Binding(
                    get: { sessionToRename != nil },
                    set: { if !$0 { sessionToRename = nil } }
                )
            ) {
                TextField(LocalizedStringKey("New chat"), text: $renameDraft)
                Button("Save") { commitSessionRename() }
                Button("Cancel", role: .cancel) { sessionToRename = nil }
            }
        }

        private var filteredDrawerSessions: [ChatVM.Session] {
            let query = drawerFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return vm.sessions }
            return vm.sessions.filter { session in
                drawerTitle(for: session).localizedCaseInsensitiveContains(query)
                    || (drawerPreview(for: session)?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }

        /// Writing through `vm.sessions` is the persistence path: its `didSet`
        /// runs the coalesced session save, so no explicit save call is needed.
        private func commitSessionRename() {
            defer { sessionToRename = nil }
            guard let session = sessionToRename,
                  let idx = vm.sessions.firstIndex(where: { $0.id == session.id }) else { return }
            let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            vm.sessions[idx].title = trimmed
        }

        private struct HideMacListBackgroundIfAvailable: ViewModifier {
            func body(content: Content) -> some View {
                if #available(macOS 13, *) {
                    content.scrollContentBackground(.hidden)
                } else {
                    content
                }
            }
        }

        private func drawerRow(for session: ChatVM.Session) -> some View {
            MacChatDrawerRow(
                title: drawerTitle(for: session),
                preview: drawerPreview(for: session) ?? "",
                isSelected: session.id == vm.activeSessionID,
                isFavorite: session.isFavorite
            )
        }

        /// One chat row in the macOS drawer: quiet by default, a pale neutral
        /// wash on hover, and a subtle (non-accent) selection state.
        private struct MacChatDrawerRow: View {
            let title: String
            let preview: String
            let isSelected: Bool
            let isFavorite: Bool

            @State private var hovering = false

            var body: some View {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(isSelected ? .medium : .regular))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.75)))

                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.yellow.opacity(0.8))
                        }

                        Spacer(minLength: 0)
                    }

                    Text(preview.isEmpty ? " " : preview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .opacity(preview.isEmpty ? 0 : 1)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, ChatTheme.spacingM)
                .background(
                    RoundedRectangle(cornerRadius: ChatTheme.controlRadius - 2, style: .continuous)
                        .fill(isSelected
                              ? ChatTheme.selectionSurface
                              : (hovering ? ChatTheme.hoverSurface : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChatTheme.controlRadius - 2, style: .continuous)
                        .stroke(ChatTheme.hairline.opacity(isSelected ? 1 : 0), lineWidth: 1)
                )
                .onHover { hovering = $0 }
            }
        }

        private func drawerPreview(for session: ChatVM.Session) -> String? {
            func stripThinkBlocks(_ text: String) -> String {
                var result = text

                while let start = result.range(of: "<think>", options: .caseInsensitive) {
                    if let end = result.range(of: "</think>", options: .caseInsensitive, range: start.upperBound..<result.endIndex) {
                        result.removeSubrange(start.lowerBound..<end.upperBound)
                    } else {
                        result.removeSubrange(start.lowerBound..<result.endIndex)
                        break
                    }
                }

                return result.replacingOccurrences(of: "</think>", with: "", options: .caseInsensitive)
            }

            func condense(_ text: String) -> String? {
                let sanitized = stripThinkBlocks(text)
                let condensed = sanitized
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                guard !condensed.isEmpty else { return nil }

                if condensed.count > 80 {
                    let prefix = condensed.prefix(77)
                    return prefix + "…"
                }
                return condensed
            }

            var fallback: String?

            for message in session.messages.reversed() {
                let roleLowercased = message.role.lowercased()
                guard roleLowercased != "system" else { continue }
                if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

                let isAssistant = roleLowercased == "assistant" || message.role == "🤖"
                if isAssistant {
                    if let finalText = vm.finalAnswerText(for: message),
                       let condensed = condense(finalText) {
                        return condensed
                    }
                    continue
                }

                if fallback == nil {
                    fallback = condense(message.text)
                }
            }

            return fallback
        }

        private func drawerTitle(for session: ChatVM.Session) -> String {
            let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "New chat" : trimmed
        }

        /// `map` is the freshly emitted `$modelSettings` value. @Published fires on
        /// willSet, so reading `modelManager.settings(for:)` from inside that handler
        /// returns the PRE-change settings — the sidebar would then hold a stale
        /// snapshot whose next persist reverts whatever was just saved in Model
        /// Settings. Resolving from the emitted map avoids the stale read.
        private func syncSidebarSettings(map: [String: ModelSettings]? = nil) {
            guard let model = modelManager.loadedModel else {
                advancedSettings = ModelSettings()
                return
            }
            let latest: ModelSettings
            if let map, let value = map[model.url.path] {
                latest = modelManager.normalizeLocalSettings(value, for: model)
            } else {
                latest = modelManager.settings(for: model)
            }
            guard latest != advancedSettings else { return }
            advancedSettings = latest
        }

        private func persistSidebarSettings(_ settings: ModelSettings) {
            guard let model = modelManager.loadedModel else { return }
            // The sidebar owns only sampling + speculative controls. Merge them into
            // the latest stored settings so a stale sidebar snapshot can never
            // clobber fields it doesn't edit (context length, KV cache, prompts, …),
            // and skip the write entirely when nothing it owns changed.
            var merged = modelManager.settings(for: model)
            merged.applySamplingSettings(from: settings)
            merged.speculativeDecoding = settings.speculativeDecoding
            merged = modelManager.normalizeLocalSettings(merged, for: model)
            guard merged != modelManager.settings(for: model) else { return }
            modelManager.updateSettings(merged, for: model)
            vm.syncActiveLocalModelSamplingSettingsIfNeeded(model: model, settings: merged)
        }
#endif

        private var scrollBottomInset: CGFloat {
#if os(macOS)
            return 16
#else
            // The input stack is a safeAreaInset now, so the viewport already
            // ends above it — this is just breathing room under the last message.
            return 12
#endif
        }

        private var hasActiveChatModel: Bool { vm.hasActiveChatModel }

        private var bookmarkedMessages: [BookmarkedMessageReference] {
            vm.sessions.flatMap { session in
                session.messages
                    .filter { $0.isBookmarked && $0.role.lowercased() != "system" }
                    .map { BookmarkedMessageReference(session: session, message: $0) }
            }
        }

        private var chatRecallResults: [ChatRecallResult] {
            let terms = recallSearchTerms(from: chatRecallQuery)
            guard !terms.isEmpty else { return [] }

            return vm.sessions.flatMap { session in
                session.messages.compactMap { message -> ChatRecallResult? in
                    guard message.role.lowercased() != "system" else { return nil }
                    let text = recallSearchText(for: message)
                    guard !text.isEmpty else { return nil }

                    let searchable = "\(sessionDisplayTitle(for: session)) \(message.role) \(text)"
                        .lowercased()
                    var score = 0
                    for term in terms {
                        if searchable.contains(term) {
                            score += term.count >= 5 ? 5 : 3
                            score += searchable.components(separatedBy: term).count - 1
                        }
                    }
                    if message.isBookmarked { score += 2 }
                    guard score > 0 else { return nil }
                    return ChatRecallResult(session: session, message: message, score: score)
                }
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.message.timestamp > rhs.message.timestamp
            }
            .prefix(12)
            .map { $0 }
        }

        private func sessionDisplayTitle(for session: ChatVM.Session) -> String {
            let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? String(localized: "New chat") : trimmed
        }

        private var activeScratchpadHasText: Bool {
            !vm.activeScratchpad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private var activeChatInstructionsHasText: Bool {
            !vm.activeChatInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private var chatModeBinding: Binding<ChatVM.ChatMode> {
            Binding(
                get: { vm.activeChatMode },
                set: { vm.setChatModeForActiveSession($0) }
            )
        }

        private var answerStyleBinding: Binding<ChatVM.AnswerStyle> {
            Binding(
                get: { vm.activeAnswerStyle },
                set: { vm.setAnswerStyleForActiveSession($0) }
            )
        }

        private var chatSnapshotRows: [ChatSnapshotRow] {
            let session = vm.sessions.first { $0.id == vm.activeSessionID }
            let modelName = modelManager.activeRemoteSession?.modelName
                ?? modelManager.loadedModel?.name
                ?? String(localized: "No model loaded")
            let backend = modelManager.activeRemoteSession?.backendName
                ?? modelManager.loadedModel?.format.displayName
                ?? String(localized: "None")
            let datasetName = vm.activeSessionDataset?.name ?? String(localized: "No dataset")
            let modeTitle = String(localized: String.LocalizationValue(vm.activeChatMode.titleKey))
            let answerStyleTitle = String(localized: String.LocalizationValue(vm.activeAnswerStyle.titleKey))
            let instructionsStatus = activeChatInstructionsHasText ? String(localized: "Set") : String(localized: "Inherited")
#if os(macOS)
            let permissionCount = vm.activeToolPermissions.enabledCount + vm.activeToolPermissions.selectedMCPServerIDs.filter { id in
                MCPServerManager.shared.servers.contains { server in
                    server.id == id && server.state == .ready
                        && server.tools.contains { server.configuration.policy.isToolEnabled($0.originalName) }
                }
            }.count
            let permissionTotal = 4 + MCPServerManager.shared.servers.count
#else
            let permissionCount = vm.activeToolPermissions.enabledCount
            let permissionTotal = 4
#endif
            let messageCount = vm.msgs.filter { $0.role.lowercased() != "system" }.count
            let prompt = vm.systemPromptText
            let settingsSummary = activeSettingsSummary()

            return [
                ChatSnapshotRow(title: String(localized: "Created"), value: Date().formatted(date: .abbreviated, time: .shortened)),
                ChatSnapshotRow(title: String(localized: "Chat"), value: sessionDisplayTitle(for: session ?? ChatVM.Session(title: "", messages: [], date: Date()))),
                ChatSnapshotRow(title: String(localized: "Active Model"), value: modelName),
                ChatSnapshotRow(title: String(localized: "Backend"), value: backend),
                ChatSnapshotRow(title: String(localized: "Chat Mode"), value: modeTitle),
                ChatSnapshotRow(title: String(localized: "Answer Style"), value: answerStyleTitle),
                ChatSnapshotRow(title: String(localized: "Chat Instructions"), value: instructionsStatus),
                ChatSnapshotRow(title: String(localized: "Active Dataset"), value: datasetName),
                ChatSnapshotRow(title: String(localized: "Tool Permissions"), value: "\(permissionCount) / \(permissionTotal)"),
                ChatSnapshotRow(title: String(localized: "Message Count"), value: "\(messageCount)"),
                ChatSnapshotRow(title: String(localized: "System Prompt Fingerprint"), value: "len=\(prompt.count) hash=\(ChatVM.diagnosticHash(for: prompt))"),
                ChatSnapshotRow(title: String(localized: "Settings Summary"), value: settingsSummary)
            ]
        }

        private var chatSnapshotExportText: String {
            var lines = [String(localized: "Chat Snapshot")]
            lines.append(String(repeating: "-", count: 24))
            for row in chatSnapshotRows {
                lines.append("\(row.title): \(row.value)")
            }
            return lines.joined(separator: "\n")
        }

        private var chatMarkdownNoteText: String {
            let session = vm.sessions.first { $0.id == vm.activeSessionID }
            let title = sessionDisplayTitle(for: session ?? ChatVM.Session(title: "", messages: [], date: Date()))
            var lines: [String] = ["# \(title)", ""]
            lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .shortened))")
            lines.append("")
            lines.append("## Snapshot")
            for row in chatSnapshotRows {
                lines.append("- \(row.title): \(row.value)")
            }
            lines.append("")
            lines.append("## Conversation")

            let visibleMessages = vm.msgs.filter { $0.role.lowercased() != "system" }
            if visibleMessages.isEmpty {
                lines.append("")
                lines.append("_\(String(localized: "No messages"))_")
            } else {
                for message in visibleMessages {
                    let roleTitle = markdownRoleTitle(for: message)
                    let text = markdownMessageText(for: message)
                    guard !text.isEmpty else { continue }
                    lines.append("")
                    lines.append("### \(roleTitle) - \(message.timestamp.formatted(date: .omitted, time: .shortened))")
                    lines.append("")
                    lines.append(text)
                    if let citations = message.citations, !citations.isEmpty {
                        lines.append("")
                        lines.append("Citations:")
                        for (index, citation) in citations.enumerated() {
                            let source = (citation.source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            let score = citation.score.map { String(format: "%.3f", $0) } ?? String(localized: "n/a")
                            lines.append("\(index + 1). \(source.isEmpty ? String(localized: "Unknown Source") : source) (score \(score))")
                        }
                    }
                }
            }

            return lines.joined(separator: "\n")
        }

        private var chatCitationsJSONText: String {
            let formatter = ISO8601DateFormatter()
            let messages: [[String: Any]] = vm.msgs.enumerated().compactMap { index, message in
                guard let citations = message.citations, !citations.isEmpty else { return nil }
                return [
                    "message_index": index,
                    "message_id": message.id.uuidString,
                    "role": markdownRoleTitle(for: message),
                    "timestamp": formatter.string(from: message.timestamp),
                    "citations": citations.enumerated().map { citationIndex, citation in
                        var citationPayload: [String: Any] = [
                            "index": citationIndex + 1,
                            "source": citation.source ?? "",
                            "text": citation.text
                        ]
                        if let score = citation.score {
                            citationPayload["score"] = score
                        }
                        return citationPayload
                    }
                ]
            }
            let payload: [String: Any] = [
                "chat_title": sessionDisplayTitle(for: vm.sessions.first { $0.id == vm.activeSessionID } ?? ChatVM.Session(title: "", messages: [], date: Date())),
                "exported_at": formatter.string(from: Date()),
                "messages": messages
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return "{\n  \"messages\" : []\n}"
            }
            return text
        }

        private var chatGenerationReplayJSONText: String {
            let formatter = ISO8601DateFormatter()
            let session = vm.sessions.first { $0.id == vm.activeSessionID }
            let visibleMessages: [[String: Any]] = vm.msgs.enumerated().compactMap { index, message in
                guard message.role.lowercased() != "system" else { return nil }
                var payload: [String: Any] = [
                    "index": index,
                    "id": message.id.uuidString,
                    "role": markdownRoleTitle(for: message),
                    "timestamp": formatter.string(from: message.timestamp),
                    "text": markdownMessageText(for: message)
                ]
                if let datasetID = message.datasetID, !datasetID.isEmpty {
                    payload["dataset_id"] = datasetID
                }
                if let datasetName = message.datasetName, !datasetName.isEmpty {
                    payload["dataset_name"] = datasetName
                }
                if let perf = message.perf {
                    payload["timings"] = [
                        "token_count": perf.tokenCount,
                        "avg_tokens_per_second": perf.avgTokPerSec,
                        "time_to_first_token_seconds": perf.timeToFirst,
                        "latency_samples_ms": perf.latencySamplesMs
                    ]
                }
                if let promptProcessing = message.promptProcessing {
                    payload["prompt_processing"] = [
                        "progress": promptProcessing.progress
                    ]
                }
                if let rag = message.ragInjectionInfo {
                    var ragPayload: [String: Any] = [
                        "dataset_name": rag.datasetName,
                        "stage": rag.stage.rawValue,
                        "requested_max_chunks": rag.requestedMaxChunks,
                        "retrieved_chunk_count": rag.retrievedChunkCount,
                        "injected_chunk_count": rag.injectedChunkCount,
                        "trimmed_chunk_count": rag.trimmedChunkCount,
                        "partial_chunk_injected": rag.partialChunkInjected,
                        "configured_context_tokens": rag.configuredContextTokens,
                        "reserved_response_tokens": rag.reservedResponseTokens,
                        "context_budget_tokens": rag.contextBudgetTokens,
                        "injected_context_tokens": rag.injectedContextTokens,
                        "decision_reason": rag.decisionReason
                    ]
                    if let method = rag.method {
                        ragPayload["method"] = method.rawValue
                    }
                    if let estimate = rag.fullContentEstimateTokens {
                        ragPayload["full_content_estimate_tokens"] = estimate
                    }
                    payload["rag"] = ragPayload
                }
                if let citations = message.citations, !citations.isEmpty {
                    payload["citations"] = citations.enumerated().map { citationIndex, citation in
                        var citationPayload: [String: Any] = [
                            "index": citationIndex + 1,
                            "text": citation.text,
                            "source": citation.source ?? ""
                        ]
                        if let score = citation.score {
                            citationPayload["score"] = score
                        }
                        return citationPayload
                    }
                }
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    payload["tool_calls"] = toolCalls.map { toolCall in
                        var toolPayload: [String: Any] = [
                            "id": toolCall.id.uuidString,
                            "tool_name": toolCall.toolName,
                            "display_name": toolCall.displayName,
                            "phase": toolCall.phase.rawValue,
                            "timestamp": formatter.string(from: toolCall.timestamp),
                            "request_params": jsonReadyDictionary(toolCall.requestParams.mapValues { $0.value })
                        ]
                        if let externalID = toolCall.externalToolCallID {
                            toolPayload["external_tool_call_id"] = externalID
                        }
                        if let result = toolCall.result {
                            toolPayload["result"] = result
                        }
                        if let error = toolCall.error {
                            toolPayload["error"] = error
                        }
                        return toolPayload
                    }
                }
                if let webHits = message.webHits, !webHits.isEmpty {
                    payload["web_hits"] = webHits.map { hit in
                        [
                            "id": hit.id,
                            "title": hit.title,
                            "snippet": hit.snippet,
                            "url": hit.url,
                            "engine": hit.engine,
                            "score": hit.score
                        ]
                    }
                }
                if let webError = message.webError, !webError.isEmpty {
                    payload["web_error"] = webError
                }
                if let imagePaths = message.imagePaths, !imagePaths.isEmpty {
                    payload["image_count"] = imagePaths.count
                    payload["image_names"] = imagePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                }
                if let attachments = message.mediaAttachments, !attachments.isEmpty {
                    payload["media_attachment_count"] = attachments.count
                }
                payload["used_web_search"] = message.usedWebSearch ?? false
                payload["used_remote_backend"] = message.usedRemoteBackend ?? false
                if let backend = message.remoteBackendName, !backend.isEmpty {
                    payload["remote_backend_name"] = backend
                }
                if let model = message.remoteModelName, !model.isEmpty {
                    payload["remote_model_name"] = model
                }
                return payload
            }

            let payload: [String: Any] = [
                "schema": "noema.generation_replay",
                "schema_version": 1,
                "exported_at": formatter.string(from: Date()),
                "chat_title": sessionDisplayTitle(for: session ?? ChatVM.Session(title: "", messages: [], date: Date())),
                "prompt_receipt": chatSnapshotRows.map { ["title": $0.title, "value": $0.value] },
                "messages": visibleMessages
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return "{\n  \"schema\" : \"noema.generation_replay\",\n  \"messages\" : []\n}"
            }
            return text
        }

        private func jsonReadyDictionary(_ dictionary: [String: Any]) -> [String: Any] {
            dictionary.mapValues { jsonReadyValue($0) }
        }

        private func jsonReadyValue(_ value: Any) -> Any {
            switch value {
            case let string as String:
                return string
            case let bool as Bool:
                return bool
            case let int as Int:
                return int
            case let double as Double:
                return double
            case let float as Float:
                return Double(float)
            case let dictionary as [String: Any]:
                return dictionary.mapValues { jsonReadyValue($0) }
            case let array as [Any]:
                return array.map { jsonReadyValue($0) }
            default:
                return String(describing: value)
            }
        }

        private func markdownRoleTitle(for message: ChatVM.Msg) -> String {
            let role = message.role.lowercased()
            if role == "assistant" || message.role == "🤖" {
                return String(localized: "Assistant")
            }
            if role == "user" || message.role == "🧑‍💻" {
                return String(localized: "User")
            }
            return message.role
        }

        private func markdownMessageText(for message: ChatVM.Msg) -> String {
            let role = message.role.lowercased()
            let text: String?
            if role == "assistant" || message.role == "🤖" {
                text = vm.finalAnswerText(for: message)
            } else {
                text = message.text
            }
            return (text ?? "")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var contextPlanRows: [ContextPlanRow] {
            let compactionState = vm.activeConversationCompaction
            let messages = ChatVM.historyByApplyingConversationCompaction(
                vm.msgs,
                state: compactionState
            ).filter { $0.role.lowercased() != "system" }
            let usableBudget = ChatVM.promptBudget(for: vm.contextLimit).usablePromptTokens
            let summaryTokens = compactionState.map(vm.conversationCompactionContextTokens) ?? 0
            var used = summaryTokens
            var keptIDs = Set<UUID>()

            for message in messages.reversed() {
                let tokens = estimatedContextTokens(for: message)
                if used + tokens <= usableBudget || keptIDs.isEmpty {
                    keptIDs.insert(message.id)
                    used += tokens
                }
            }

            var rows: [ContextPlanRow] = []
            if let compactionState,
               let summaryID = compactionState.coveredMessageIDs.first {
                rows.append(
                    ContextPlanRow(
                        id: summaryID,
                        roleTitle: String(localized: "Retained Summary"),
                        preview: compactionState.summary,
                        tokenCount: summaryTokens,
                        statusKey: "Kept",
                        tint: .green
                    )
                )
            }
            rows.append(contentsOf: messages.map { message in
                let kept = keptIDs.contains(message.id)
                return ContextPlanRow(
                    id: message.id,
                    roleTitle: markdownRoleTitle(for: message),
                    preview: contextPlanPreview(for: message),
                    tokenCount: estimatedContextTokens(for: message),
                    statusKey: kept ? "Kept" : "At risk",
                    tint: kept ? .green : .orange
                )
            })
            return rows
        }

        private var contextPlanSummary: String {
            let rows = contextPlanRows
            let used = rows.filter { $0.statusKey == "Kept" }.reduce(0) { $0 + $1.tokenCount }
            let budget = ChatVM.promptBudget(for: vm.contextLimit).usablePromptTokens
            return String.localizedStringWithFormat(
                String(localized: "%@ of %@ estimated"),
                shortTokenLabel(used),
                shortTokenLabel(budget)
            )
        }

        private func contextPlanPreview(for message: ChatVM.Msg) -> String {
            let text = markdownMessageText(for: message)
            let condensed = text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !condensed.isEmpty else { return String(localized: "Empty message") }
            if condensed.count > 120 {
                return String(condensed.prefix(117)) + "..."
            }
            return condensed
        }

        private func estimatedContextTokens(for message: ChatVM.Msg) -> Int {
            var total = estimatedTokenCount(markdownMessageText(for: message)) + 8
            if let retrievedContext = message.retrievedContext {
                total += estimatedTokenCount(retrievedContext)
            }
            if let citations = message.citations, !citations.isEmpty {
                total += citations.reduce(0) { $0 + estimatedTokenCount($1.text) }
            }
            if let imagePaths = message.imagePaths {
                total += imagePaths.count * 576
            }
            if let mediaAttachments = message.mediaAttachments {
                total += mediaAttachments.reduce(0) { partial, attachment in
                    partial + estimatedTokenCount(attachment.transcript?.effectiveTranscriptText ?? "")
                }
            }
            return max(1, total)
        }

        private func estimatedTokenCount(_ value: String) -> Int {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            let wordEstimate = trimmed.split { $0.isWhitespace || $0.isNewline }.count
            let charEstimate = Int(ceil(Double(trimmed.count) / 4.0))
            return max(1, max(wordEstimate, charEstimate))
        }

        private func shortTokenLabel(_ value: Int) -> String {
            if value >= 1_000 {
                return String(format: "%.1fk", Double(value) / 1000.0)
            }
            return "\(value)"
        }

        private func activeSettingsSummary() -> String {
            let settings = vm.loadedModelSettings
                ?? modelManager.loadedModel.map { modelManager.settings(for: $0) }
            guard let settings else { return String(localized: "None") }
            let context = Int(settings.contextLength.rounded())
            let gpu = settings.gpuLayers < 0 ? String(localized: "Auto") : "\(settings.gpuLayers)"
            return "ctx=\(context), temp=\(String(format: "%.2f", settings.temperature)), top-p=\(String(format: "%.2f", settings.topP)), gpu=\(gpu)"
        }

        private func openScratchpad() {
            scratchpadDraft = vm.activeScratchpad
            showScratchpad = true
        }

        private func openChatInstructions() {
            chatInstructionsDraft = vm.activeChatInstructions
            showChatInstructions = true
        }

        private func bookmarkPreview(for message: ChatVM.Msg) -> String {
            let sourceText = recallSearchText(for: message)
            let condensed = sourceText
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !condensed.isEmpty else { return String(localized: "Empty message") }
            if condensed.count > 90 {
                return String(condensed.prefix(87)) + "..."
            }
            return condensed
        }

        private func recallSearchTerms(from query: String) -> [String] {
            let parts = query
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
            var seen = Set<String>()
            return parts.filter { seen.insert($0).inserted }
        }

        private func recallSearchText(for message: ChatVM.Msg) -> String {
            let visible = message.trimmedVisibleAssistantText
            return visible.isEmpty ? message.text : visible
        }

        private func openMessage(session: ChatVM.Session, messageID: UUID) {
            shouldAutoScrollToBottom = false
            vm.select(session)
            withAnimation { showSidebar = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                vm.focus(onMessageWithID: messageID)
            }
        }

        private func openBookmark(_ bookmark: BookmarkedMessageReference) {
            openMessage(session: bookmark.session, messageID: bookmark.message.id)
        }

        private func openRecallResult(_ result: ChatRecallResult) {
            openMessage(session: result.session, messageID: result.message.id)
        }

        // MARK: - Chat status pills

#if os(macOS)
        /// Flat industrial chip label for the macOS status row: 5pt dot +
        /// mono caps text, tint-on-tint — no gradients, glass, or shadows.
        private func macStatusChipLabel(_ text: Text, tint: Color) -> some View {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                text
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
        }
#endif

        /// Shared capsule chrome for the status pills above the transcript,
        /// matching the dataset pill's tinted-glass look.
        private func statusPillBackground(tint: Color, secondary: Color) -> some View {
            Capsule()
                .fill(tint.opacity(0.22))
                .glassifyIfAvailable(in: Capsule())
                .overlay(
                    Capsule().fill(
                        LinearGradient(
                            colors: [tint.opacity(0.35), secondary.opacity(0.20)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .overlay(
                    Capsule().strokeBorder(tint.opacity(0.48), lineWidth: 0.9)
                )
        }

        /// Status row above the transcript: active dataset, context overflow,
        /// and memory budget pills. Scrolls horizontally so multiple pills
        /// never clip on narrow screens.
        @ViewBuilder
        private var chatStatusPillRow: some View {
            let hasModel = modelManager.activeRemoteSession != nil || modelManager.loadedModel != nil
            let overflowBanner = hasModel ? vm.contextOverflowBanner : nil
            let memoryNotice = hasModel ? vm.memoryPromptBudgetNoticeText : nil
            let compactionNotice = hasModel ? vm.conversationCompactionNoticeText : nil
            // Persistent, non-dismissable safety pill whenever a medical Knowledge
            // Pack is the active retrieval dataset (independent of retrieval result).
            let showMedicalDisclaimer = vm.activeSessionDataset
                .map { KnowledgePackCatalog.pack(forID: $0.datasetID)?.disclaimerKey == "medical" } ?? false
            if vm.activeSessionDataset != nil || overflowBanner != nil || memoryNotice != nil || compactionNotice != nil {
#if os(macOS)
                // Flat chips aligned with the conversation column; variable-width
                // chips truncate instead of scrolling.
                HStack(spacing: 8) {
                    if let ds = vm.activeSessionDataset {
                        datasetStatusPill(ds)
                    }
                    if showMedicalDisclaimer {
                        medicalDisclaimerPill()
                            .layoutPriority(1)
                    }
                    if let banner = overflowBanner {
                        contextOverflowPill(banner)
                            .layoutPriority(1)
                    }
                    if let memoryNotice {
                        memoryBudgetPill(memoryNotice)
                    }
                    if let compactionNotice {
                        conversationCompactionPill(compactionNotice)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, ChatTheme.conversationHorizontalInset)
                .padding(.vertical, 8)
                .frame(maxWidth: ChatTheme.conversationMaxWidth + ChatTheme.conversationHorizontalInset * 2)
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .move(edge: .top)))
#else
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let ds = vm.activeSessionDataset {
                            datasetStatusPill(ds)
                        }
                        if showMedicalDisclaimer {
                            medicalDisclaimerPill()
                        }
                        if let banner = overflowBanner {
                            contextOverflowPill(banner)
                        }
                        if let memoryNotice {
                            memoryBudgetPill(memoryNotice)
                        }
                        if let compactionNotice {
                            conversationCompactionPill(compactionNotice)
                        }
                    }
                    .padding(.horizontal, UIConstants.defaultPadding)
                    .padding(.vertical, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
#endif
            }
        }

        private func medicalDisclaimerPill() -> some View {
#if os(macOS)
            return macStatusChipLabel(Text(LocalizedStringKey("Reference only — not medical advice")), tint: .red)
#else
            return HStack(spacing: 8) {
                Image(systemName: "cross.case.fill")
                    .font(.caption.weight(.semibold))
                Text(LocalizedStringKey("Reference only — not medical advice"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(statusPillBackground(tint: .red, secondary: .orange))
            .shadow(color: Color.red.opacity(0.25), radius: 8, x: 0, y: 4)
#endif
        }

        private func datasetStatusPill(_ ds: LocalDataset) -> some View {
            Menu {
                Button(role: .destructive) {
                    vm.setDatasetForActiveSession(nil)
                } label: {
                    Label(LocalizedStringKey("Stop Using Dataset"), systemImage: "xmark.circle")
                }
                Button {
                    openStoredDatasetDetails(ds)
                } label: {
                    Label("See details", systemImage: "info.circle")
                }
            } label: {
#if os(macOS)
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                    Text("Using \(ds.name)")
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .opacity(0.8)
                }
                .foregroundStyle(Color.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                )
#else
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                    Text("Using \(ds.name)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(statusPillBackground(tint: .blue, secondary: .cyan))
                .shadow(color: Color.blue.opacity(0.25), radius: 8, x: 0, y: 4)
#endif
            }
            .buttonStyle(.plain)
#if os(macOS)
            .menuIndicator(.hidden)
#endif
        }

        private func contextOverflowPill(_ banner: ChatVM.ContextOverflowBannerState) -> some View {
            let isStop = banner.strategy.isHardStop
            let tint: Color = isStop ? .red : .orange
#if os(macOS)
            return HStack(spacing: 0) {
                Button {
                    showContextOverflowAlert = true
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                        Text(LocalizedStringKey(banner.strategy.pillTitleKey))
                            .textCase(.uppercase)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.leading, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(banner.strategy.pillTitleKey)))
                .accessibilityHint(Text("Shows details about the context window."))

                Button {
                    vm.dismissActiveContextOverflowBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.85)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss context warning"))
            }
            .foregroundStyle(tint)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
#else
            let secondary: Color = isStop ? .orange : .yellow
            return HStack(spacing: 0) {
                Button {
                    showContextOverflowAlert = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: banner.strategy.pillSymbolName)
                            .font(.caption.weight(.semibold))
                        Text(LocalizedStringKey(banner.strategy.pillTitleKey))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(banner.strategy.pillTitleKey)))
                .accessibilityHint(Text("Shows details about the context window."))

                Button {
                    vm.dismissActiveContextOverflowBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.85)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss context warning"))
            }
            .foregroundStyle(.white)
            .background(statusPillBackground(tint: tint, secondary: secondary))
            .shadow(color: tint.opacity(0.25), radius: 8, x: 0, y: 4)
#endif
        }

        private func memoryBudgetPill(_ notice: String) -> some View {
            Button {
                showMemoryPromptBudgetAlert = true
            } label: {
#if os(macOS)
                // Orange (not yellow) tint: yellow-on-yellow fails in light mode.
                macStatusChipLabel(Text(verbatim: notice), tint: .orange)
#else
                HStack(spacing: 7) {
                    Image(systemName: "bookmark.slash.fill")
                        .font(.caption.weight(.semibold))
                    Text(notice)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(statusPillBackground(tint: .yellow, secondary: .orange))
                .shadow(color: Color.yellow.opacity(0.25), radius: 8, x: 0, y: 4)
#endif
            }
            .buttonStyle(.plain)
            .accessibilityLabel(notice)
        }

        private func conversationCompactionPill(_ notice: String) -> some View {
            let isRunning = vm.conversationCompactionInProgressSessionID == vm.activeSessionID
            return Group {
#if os(macOS)
                macStatusChipLabel(Text(verbatim: notice), tint: isRunning ? .blue : .orange)
#else
                HStack(spacing: 7) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.caption.weight(.semibold))
                    }
                    Text(notice)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    statusPillBackground(
                        tint: isRunning ? .blue : .orange,
                        secondary: isRunning ? .indigo : .red
                    )
                )
                .shadow(
                    color: (isRunning ? Color.blue : Color.orange).opacity(0.25),
                    radius: 8,
                    x: 0,
                    y: 4
                )
#endif
            }
            .accessibilityLabel(notice)
        }

        private var chatContent: some View {
            return VStack(spacing: 0) {
                chatStatusPillRow

#if os(macOS)
                // The composer is the SAME structural node in both states, so
                // the hand-off animates only its position — no matched-geometry
                // duplicate, no NSTextView remount, focus carries over.
                if isMacNewChatCanvas {
                    Spacer(minLength: ChatTheme.spacingXL)
                    Text("How can I help you today?")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.bottom, 30)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    conversationScrollArea
                        .transition(.opacity)
                }
                macComposerStack
                if isMacNewChatCanvas {
                    macSuggestionPills
                        .padding(.top, 22)
                        .transition(.opacity)
                    Spacer(minLength: ChatTheme.spacingXL)
                    Spacer(minLength: 0)
                }
#else
                conversationScrollArea
#if !os(iOS)
                nonMacDesktopComposerStack
#endif
#endif
            }
#if os(macOS)
            // One coherent spring drives the hero→bottom composer hand-off.
            .animation(.spring(response: 0.42, dampingFraction: 0.9), value: isMacNewChatCanvas)
#endif
            .onAppear {
                // Pick suggestions when entering a new empty chat (only once)
                let isEmpty = vm.msgs.first(where: { $0.role != "system" }) == nil
                if isEmpty {
                    suggestionTriplet = ChatSuggestions.nextThree(datasetName: vm.activeSessionDataset?.name)
                    suggestionsSessionID = vm.activeSessionID
                }
            }
            .onChangeCompat(of: vm.activeSessionID) { _, newID in
                showContextOverflowAlert = false
#if os(macOS)
                macComposerHandOff = false
#endif
                // Rotate suggestions per new session if starting empty
                let isEmpty = vm.msgs.first(where: { $0.role != "system" }) == nil
                if isEmpty && newID != suggestionsSessionID {
                    suggestionTriplet = ChatSuggestions.nextThree(datasetName: vm.activeSessionDataset?.name)
                    suggestionsSessionID = newID
                }
            }
            .onChangeCompat(of: vm.activeSessionDataset?.datasetID) { _, _ in
                let isEmpty = vm.msgs.first(where: { $0.role != "system" }) == nil
                if isEmpty {
                    suggestionTriplet = ChatSuggestions.nextThree(datasetName: vm.activeSessionDataset?.name)
                    suggestionsSessionID = vm.activeSessionID
                }
            }
#if os(iOS)
            // Decorative bottom glow. Stays an overlay (anchored to the full
            // chat bounds, behind the input stack) and never intercepts touches.
            .overlay(alignment: .bottom) {
                GeometryReader { proxy in
                    let menuBarOffset = max(proxy.safeAreaInsets.bottom, 52)
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.18), location: 0.0),
                            .init(color: Color.white.opacity(0.11), location: 0.22),
                            .init(color: Color.white.opacity(0.06), location: 0.52),
                            .init(color: Color.white.opacity(0.03), location: 0.78),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 620)
                    .offset(y: menuBarOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
            // The input stack is a safe-area inset (NOT an overlay) so the
            // ScrollView's viewport ends above it: `scrollTo(_, anchor: .bottom)`
            // and manual scrolling both land the last message's bottom —
            // badges, perf footer — fully visible above the status bar +
            // composer, while content still scrolls beneath the glass.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    ChatInputBox(text: $draftText, focus: inputFocusBinding,
                                 showModelRequiredAlert: $showModelRequiredAlert,
                                 send: { let text = draftText; draftText = ""; prepareUIForSend(); Task { await vm.sendMessage(text) } },
                                 stop: { vm.stop() },
                                 stopAfterParagraph: { vm.requestStopAfterParagraph() },
                                 canStop: vm.isStreaming,
                                 stopAfterParagraphPending: vm.stopAfterParagraphRequested)
                    .guideHighlight(.chatInput)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                }
            }
#endif
            .alert("Load Failed", isPresented: Binding(get: { vm.loadError != nil }, set: { _ in vm.loadError = nil })) {
                if vm.pendingETRepairCandidate != nil {
                    Button("Repair") {
                        Task { await vm.repairPendingETArtifacts() }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.loadError ?? "")
            }
            // Keep draftText in sync when ChatVM sets prompt externally — e.g.
            // branch creation pre-fills the input, or a blocked send restores it.
            .onChangeCompat(of: vm.prompt) { _, newPrompt in
                if draftText != newPrompt { draftText = newPrompt }
            }
            .onChangeCompat(of: draftText) { oldDraft, newDraft in
                if oldDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !newDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AutopilotAFMBrain.syncWarmState(armed: modelManager.autoRoutingArmed)
                }
            }
            // Value-scoped: only animates the status pill row appearing/disappearing.
            .animation(.easeInOut(duration: 0.2), value: vm.contextOverflowBanner)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }

        private var conversationScrollArea: some View {
                let compactionState = vm.activeConversationCompaction
                let compactionAnchorMessageID = ChatVM.conversationCompactionAnchorMessageID(
                    in: vm.msgs,
                    state: compactionState
                )
                return ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: ChatTheme.spacingM) {
                            ForEach(vm.msgs.filter { $0.role != "system" }) { m in
                                StreamingAwareMessageView(msg: m, store: vm.streamingStore)
                                    .id(m.id)

                                if let compactionState,
                                   m.id == compactionAnchorMessageID {
                                    ConversationCompactionReceiptView(state: compactionState)
                                        .id("conversation-compaction-\(compactionState.revision)")
                                        // This is an inline activity row, not a separate
                                        // message. Cancel both the second inter-message gap
                                        // and the following assistant bubble's 6-point top
                                        // inset so adjacent activity rows keep their normal
                                        // tool/reasoning rhythm.
                                        .padding(.bottom, -(ChatTheme.spacingM + 6))
                                        // Assistant activity rows reserve this trailing gap
                                        // beside their spacer; match their visible width.
                                        .padding(.trailing, ChatTheme.spacingS)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            // Drives auto-scroll from the streaming store so the view
                            // follows tokens smoothly without re-rendering the whole list.
                            StreamingScrollAnchor(store: vm.streamingStore, proxy: proxy, enabled: shouldAutoScrollToBottom && !isVoiceOverActive)
                        }
#if os(macOS)
                        // Constrain the conversation to a readable column with
                        // generous breathing room on either side.
                        .padding(.vertical, ChatTheme.spacingL)
                        .padding(.horizontal, ChatTheme.conversationHorizontalInset)
                        .frame(maxWidth: ChatTheme.conversationMaxWidth + ChatTheme.conversationHorizontalInset * 2)
                        .frame(maxWidth: .infinity)
#else
                        .padding()
#endif
                        .padding(.bottom, scrollBottomInset)
#if os(macOS)
                        .background(
                            MacChatScrollObserver { nearBottom, userInitiated in
                                if nearBottom {
                                    if !shouldAutoScrollToBottom {
                                        shouldAutoScrollToBottom = true
                                    }
                                } else if userInitiated {
                                    shouldAutoScrollToBottom = false
                                }
                            }
                            .frame(width: 0, height: 0)
                        )
#endif
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
#if canImport(UIKit) && !os(visionOS)
                    // On iOS/iPadOS, stop auto-scrolling when the user drags the list.
                    // Avoid attaching this drag gesture on macOS so text selection remains uninterrupted.
                    .simultaneousGesture(DragGesture().onChanged { _ in shouldAutoScrollToBottom = false })
#endif
#if !os(macOS)
                    // Centered suggestions overlay for brand-new empty chats
                    // (macOS uses the dedicated new-chat canvas instead).
                    .overlay(alignment: .center) {
                        let isEmptyChat = vm.msgs.first(where: { $0.role != "system" }) == nil
                        let hasPendingMediaSurface = !vm.pendingMediaAttachments.isEmpty
                            || vm.audioRecordingError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        let showsSuggestions = isEmptyChat && !hasPendingMediaSurface && !vm.isStreaming && !vm.loading
                        Group {
                            if showsSuggestions {
                                SuggestionsOverlay(
                                    suggestions: suggestionTriplet,
                                    enabled: hasActiveChatModel,
                                    onTap: { text in
                                        guard hasActiveChatModel else { return }
                                        guard !vm.isStreamingInAnotherSession else {
                                            vm.crossSessionSendBlocked = true
                                            return
                                        }
                                        suggestionTriplet = []
                                        prepareUIForSend()
                                        Task { await vm.sendMessage(text) }
                                    },
                                    onDisabledTap: {
                                        inputFocused = false
                                        showModelRequiredAlert = true
                                    }
                                )
                                // Pure opacity fade. `.scale` forces a per-frame layout +
                                // re-rasterization of the pills' shadows on the main thread, which
                                // drops below 30fps exactly when these appear (right after a model
                                // finishes loading, while the main thread is busy). Opacity is a pure
                                // GPU compositor blend — no per-frame main-thread work — so it stays
                                // smooth under contention, and reads as a fade rather than a pop.
                                .transition(.opacity)
                            }
                        }
                        // The gating state changes outside withAnimation (vm publishes),
                        // so bind the animation to the value or the transition never fires.
                        .animation(.easeInOut(duration: 0.3), value: showsSuggestions)
                    }
#endif
                    .overlay(alignment: .bottomTrailing) {
                        let showsJumpToBottom = !shouldAutoScrollToBottom && vm.isStreaming
                        Group {
                            if showsJumpToBottom {
                                Button {
                                    if let id = vm.msgs.last?.id {
                                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                                    }
                                    shouldAutoScrollToBottom = true
                                } label: {
                                    Image(systemName: "arrow.down")
                                        .font(.caption)
                                        .padding(10)
                                        .background(.thinMaterial)
                                        .clipShape(Circle())
                                }
                                .padding(.trailing, 16)
                                // The input stack is a safeAreaInset, so the
                                // overlay's bottom already sits above it.
                                .padding(.bottom, 12)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                        // Driven by drag gestures / vm state, never withAnimation —
                        // animate on the value so the button doesn't pop in.
                        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: showsJumpToBottom)
                    }
                    .overlay(alignment: .bottom) { OverfitNoticeHost() }
                    .onTapGesture {
                        let wasInputFocused = inputFocused
                        DispatchQueue.main.async {
                            // Ignore taps that transferred focus into the composer
                            // during the same gesture pass.
                            if !wasInputFocused && inputFocused {
                                return
                            }
                            inputFocused = false
                            hideKeyboard()
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .thinkToggled)) { note in
                        guard let info = note.userInfo,
                              let idStr = info["messageId"] as? String,
                              let uuid = UUID(uuidString: idStr) else { return }
                        // Don't reposition under a VoiceOver cursor.
                        guard !isVoiceOverActive else { return }
                        // Scroll to the message that had its think box closed
                        withAnimation {
                            proxy.scrollTo(uuid, anchor: .top)
                        }
                    }
                    .onChangeCompat(of: vm.spotlightMessageID) { _, id in
                        guard let id else { return }
                        // Recall/bookmark navigation deliberately jumps even
                        // under VoiceOver (the user asked to go there), so this
                        // is intentionally NOT gated; reset spotlight after the
                        // jump so it can't re-fire on a later identical navigation.
                        withAnimation {
                            proxy.scrollTo(id, anchor: .center)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            if vm.spotlightMessageID == id { vm.spotlightMessageID = nil }
                        }
                    }
                    .onChangeCompat(of: vm.msgs) { _, msgs in
                        // Never auto-scroll while VoiceOver is active: a
                        // programmatic scrollTo moves the viewport out from
                        // under the VoiceOver cursor and makes focus jump.
                        guard !isVoiceOverActive else { return }
                        if shouldAutoScrollToBottom, let id = msgs.last?.id {
                            // Critically damped spring while streaming: matches
                            // StreamingScrollAnchor's follow animation so the
                            // pinned view glides instead of snapping. (Instant
                            // scroll was only needed before the anchor was
                            // throttled to ~12 Hz.)
                            if vm.isStreaming {
                                withAnimation(.spring(response: 0.28, dampingFraction: 1.0)) {
                                    proxy.scrollTo(id, anchor: .bottom)
                                }
                            } else {
                                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                            }
                        }
                    }
                }
        }

        /// The composer instance shared by every desktop placement (hero canvas
        /// and bottom bar) so its bindings and identity stay consistent.
        private var composerCore: some View {
            ChatInputBox(text: $draftText, focus: inputFocusBinding,
                         showModelRequiredAlert: $showModelRequiredAlert,
                         send: { sendCurrentDraft() },
                         stop: { vm.stop() },
                         stopAfterParagraph: { vm.requestStopAfterParagraph() },
                         canStop: vm.isStreaming,
                         stopAfterParagraphPending: vm.stopAfterParagraphRequested)
                .guideHighlight(.chatInput)
        }

        /// Side-effects fired the moment a message is sent from the composer:
        /// re-pin the conversation to the bottom — mirroring the manual
        /// jump-to-bottom button, so the just-sent message and the streaming
        /// reply stay in view even if the user had scrolled up — and, on iOS,
        /// retract the keyboard.
        private func prepareUIForSend() {
            shouldAutoScrollToBottom = true
#if os(iOS)
            inputFocused = false
            hideKeyboard()
#endif
        }

        private func sendCurrentDraft() {
            let text = draftText
            draftText = ""
#if os(macOS)
            if isMacNewChatCanvas {
                sendWithMacHandOff(text)
                return
            }
#endif
            prepareUIForSend()
            Task { await vm.sendMessage(text) }
        }

#if os(macOS)
        /// True when the active chat has no visible conversation yet — the
        /// composer is centered on a hero canvas until the first send.
        private var isMacNewChatCanvas: Bool {
            !macComposerHandOff
                && vm.msgs.first(where: { $0.role != "system" }) == nil
                && !vm.isStreaming
        }

        /// First send in a fresh chat: collapse the hero canvas and let the
        /// composer slide to the bottom *before* inference starts. Prompt
        /// prefill saturates CPU and GPU, so an animation overlapping it drops
        /// to single frames — the short deferral keeps the hand-off fluid.
        private func sendWithMacHandOff(_ text: String) {
            prepareUIForSend()
            macComposerHandOff = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                await vm.sendMessage(text)
                macComposerHandOff = false
            }
        }

        /// Compact, quiet starter prompts under the hero composer.
        @ViewBuilder
        private var macSuggestionPills: some View {
            if !suggestionTriplet.isEmpty && !vm.loading {
                VStack(spacing: ChatTheme.spacingS) {
                    ForEach(suggestionTriplet.prefix(3), id: \.self) { suggestion in
                        Button {
                            guard hasActiveChatModel else {
                                inputFocused = false
                                showModelRequiredAlert = true
                                return
                            }
                            guard !vm.isStreamingInAnotherSession else {
                                vm.crossSessionSendBlocked = true
                                return
                            }
                            suggestionTriplet = []
                            sendWithMacHandOff(suggestion)
                        } label: {
                            Text(suggestion)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, ChatTheme.spacingM)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(ChatTheme.quietSurface))
                                .overlay(Capsule().stroke(ChatTheme.hairline, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .opacity(hasActiveChatModel ? 1 : 0.55)
                    }
                }
                .frame(maxWidth: ChatTheme.heroComposerMaxWidth)
            }
        }

        /// The composer bar: centered narrow on the new-chat canvas, aligned
        /// with the conversation column once a chat is underway. One node in
        /// both states — only its width and position animate.
        private var macComposerStack: some View {
            VStack(spacing: 0) {
                composerCore
                    .frame(maxWidth: isMacNewChatCanvas
                           ? ChatTheme.heroComposerMaxWidth
                           : ChatTheme.conversationMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, ChatTheme.conversationHorizontalInset)
                    .padding(.top, ChatTheme.spacingM)
                    .padding(.bottom, ChatTheme.spacingM)
            }
        }
#endif

#if os(visionOS)
        /// visionOS keeps the previous bottom composer arrangement.
        @ViewBuilder
        private var nonMacDesktopComposerStack: some View {
            composerCore
                .padding()
        }
#endif

        private func openStoredDatasetDetails(_ dataset: LocalDataset) {
            tabRouter.pendingStoredDatasetID = dataset.datasetID
#if os(iOS) || os(visionOS)
            withAnimation(.easeInOut(duration: 0.2)) {
                tabRouter.selection = .stored
            }
#else
            tabRouter.selection = .stored
#endif
        }

        // MARK: - Adaptive top bar

        /// Estimated widths used to decide how many trailing icons fit beside the model name.
        private static let toolbarIconSlotWidth: CGFloat = 44   // one toolbar icon button + spacing
        /// Nav-bar insets, glass-capsule padding, and the gap between the leading and
        /// trailing groups. Underestimating this makes the system collapse the trailing
        /// buttons into its own nested "•••" overflow (a second tap to reach the menu),
        /// so err high.
        private static let toolbarChromeWidth: CGFloat = 104
        private static let modelChipChromeWidth: CGFloat = 18   // disclosure chevron + spacing
        private static let minModelChipWidth: CGFloat = 90

        /// True only when a local model is genuinely resident in memory (or actively
        /// loading). `modelManager.loadedModel` is kept as the "last selected" model
        /// even after the runtime is freed in the background, so the chat chrome must
        /// consult the live `modelLoaded` flag before showing a model name — otherwise
        /// it would advertise a model that was already auto-unloaded on app exit.
        private var hasActiveLocalModel: Bool {
            vm.modelLoaded || vm.loading || vm.stillLoading
        }

        private var currentModelDisplayName: String {
            if let remote = modelManager.activeRemoteSession { return remote.modelName }
            if hasActiveLocalModel, let loaded = modelManager.loadedModel { return loaded.name }
            return String(localized: "No model")
        }

        /// Precise rendered width of a string in the model-name font, computed synchronously
        /// so the toolbar can size itself without a measurement/relayout pass.
        private func modelNameDisplayWidth(_ name: String) -> CGFloat {
#if canImport(UIKit)
            let base = UIFont.preferredFont(forTextStyle: .subheadline)
            let font = UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor,
                              size: base.pointSize)
#else
            let font = NSFont.preferredFont(forTextStyle: .subheadline)
#endif
            return ceil((name as NSString).size(withAttributes: [.font: font]).width)
        }

        /// Upper bound for the model-name chip so the trailing controls that stay inline
        /// always have room — preventing the system's own nested overflow.
        private var maxModelNameWidth: CGFloat {
            let inlineButtons = CGFloat(adaptiveTrailingSlots + 1)  // More (•••) is always inline
            let total = currentDeviceWidth()
            return max(Self.minModelChipWidth,
                       total - Self.toolbarChromeWidth - inlineButtons * Self.toolbarIconSlotWidth)
        }

        /// Trailing tier beside the model name: 2 = sidebar + More + New inline,
        /// 1 = More + New (sidebar folds into More), 0 = More only (New Chat folds too).
        private var adaptiveTrailingSlots: Int {
            let total = currentDeviceWidth()
            let available = total - Self.toolbarChromeWidth
            let nameWidth = modelNameDisplayWidth(currentModelDisplayName) + Self.modelChipChromeWidth
            if nameWidth + 3 * Self.toolbarIconSlotWidth <= available { return 2 }
            if Self.minModelChipWidth + 2 * Self.toolbarIconSlotWidth <= available { return 1 }
            return 0
        }

        @ViewBuilder
        private var sidebarToolbarButton: some View {
            Button {
                withAnimation { showSidebar.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .guideHighlight(.chatSidebarButton)
        }

        @ViewBuilder
        private var chatModePickers: some View {
            Picker(LocalizedStringKey("Chat Mode"), selection: chatModeBinding) {
                ForEach(ChatVM.ChatMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                }
            }
            Divider()
            Picker(LocalizedStringKey("Answer Style"), selection: answerStyleBinding) {
                ForEach(ChatVM.AnswerStyle.allCases) { style in
                    Text(LocalizedStringKey(style.titleKey)).tag(style)
                }
            }
        }

        @ViewBuilder
        private var newChatToolbarButton: some View {
            Button { vm.startNewSession() } label: { Image(systemName: "plus") }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
                .contextMenu {
                    if vm.activeSessionDataset != nil {
                        Button {
                            vm.startNewSession(carryingActiveDataset: false)
                        } label: {
                            newChatWithoutDatasetLabel
                        }
                    }
                }
                .guideHighlight(.chatNewChatButton)
        }

        private var newChatWithoutDatasetLabel: some View {
            Label {
                Text(verbatim: "\(String(localized: "New Chat")) · \(String(localized: "No Dataset"))")
            } icon: {
                Image(systemName: "circle.slash")
            }
        }

        /// Single flat overflow menu. Folds in the sidebar/new-chat controls when they
        /// don't fit as inline icons, so options always open directly (never a nested menu).
        @ViewBuilder
        private func moreToolbarMenu(includeSidebar: Bool, includeNewChat: Bool) -> some View {
            Menu {
                if includeNewChat {
                    Button { vm.startNewSession() } label: {
                        Label("New Chat", systemImage: "plus")
                    }
                }
                if vm.activeSessionDataset != nil {
                    Button {
                        vm.startNewSession(carryingActiveDataset: false)
                    } label: {
                        newChatWithoutDatasetLabel
                    }
                }
                if includeSidebar {
                    Button {
                        withAnimation { showSidebar.toggle() }
                    } label: {
                        Label("Chat History", systemImage: "line.3.horizontal")
                    }
                }
                Button { showRuntimeInfo = true } label: {
                    Label("Runtime Information", systemImage: "info.circle")
                }
                Button { showContextPlan = true } label: {
                    Label("Context Plan", systemImage: "list.bullet.rectangle")
                }
                Toggle(isOn: $showRawAssistantOutput) {
                    Label("Show Raw Output", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Divider()
                Button { openScratchpad() } label: {
                    Label("Private Scratchpad", systemImage: activeScratchpadHasText ? "note.text" : "note.text.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .accessibilityLabel(Text("More options"))
        }

        private var modelHeader: some View {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let remote = modelManager.activeRemoteSession {
                        Menu {
                            Section(remote.backendName) {
                                Button(role: .destructive) {
                                    performMediumImpact()
                                    AppSoundPlayer.play(.loadPress)
                                    vm.deactivateRemoteSession()
                                } label: {
                                    Label(LocalizedStringKey("Disconnect"), systemImage: "eject")
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                remoteConnectionIndicator(for: remote)
                                Text(remote.modelName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: maxModelNameWidth, alignment: .leading)
                        }
                        .menuIndicator(.hidden)
                    } else if hasActiveLocalModel, let loaded = modelManager.loadedModel {
                        Menu {
                            Button(role: .destructive) {
                                performMediumImpact()
                                AppSoundPlayer.play(.loadPress)
                                modelManager.loadedModel = nil
                                Task { await vm.unload() }
                            } label: {
                                Label(LocalizedStringKey("Unload Model"), systemImage: "eject")
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(loaded.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: maxModelNameWidth, alignment: .leading)
                        }
                        .menuIndicator(.hidden)
                    } else {
                        let favourites = quickLoadFavourites
                        let recents = quickLoadRecents
                        Menu {
                            if favourites.isEmpty && recents.isEmpty {
                                Button(LocalizedStringKey("Open Model Library")) {
                                    tabRouter.selection = .explore
                                    UserDefaults.standard.set(ExploreSection.models.rawValue, forKey: "exploreSection")
                                }
                            } else {
                                if !favourites.isEmpty {
                                    Section(LocalizedStringKey("Favorites")) {
                                        ForEach(favourites, id: \.id) { model in
                                            Button {
                                                quickLoadIfPossible(model)
                                            } label: {
                                                quickLoadLabel(for: model, isFavourite: true)
                                            }
                                        }
                                    }
                                }
                                if !recents.isEmpty {
                                    Section(LocalizedStringKey("Recent")) {
                                        ForEach(recents, id: \.id) { model in
                                            Button {
                                                quickLoadIfPossible(model)
                                            } label: {
                                                quickLoadLabel(for: model, isFavourite: false)
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(LocalizedStringKey("No model >"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .menuIndicator(.hidden)
                        .disabled(vm.loading)
                    }
                }

            }
        }

        private func remoteConnectionBadge(for session: ActiveRemoteSession) -> some View {
            let color: Color
            switch session.transport {
            case .cloudRelay:
                color = .teal
            case .lan:
                color = .green
            case .direct:
                color = .blue
            }
            return HStack(spacing: 6) {
                Image(systemName: session.transport.symbolName)
                Text(session.transport.label)
                if session.streamingEnabled {
                    Image(systemName: "waveform")
                }
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundColor(color)
            .accessibilityLabel("Connection via \(session.transport.label)")
        }


        @ViewBuilder
        private func remoteConnectionIndicator(for session: ActiveRemoteSession) -> some View {
            if session.endpointType == .noemaRelay {
                let color: Color = {
                    switch session.transport {
                    case .cloudRelay: return .teal
                    case .lan: return .green
                    case .direct: return .blue
                    }
                }()
                HStack(spacing: 4) {
                    Image(systemName: session.transport.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                    if session.streamingEnabled {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .padding(6)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
                .accessibilityLabel("Connection via \(session.transport.label)")
            } else {
                remoteConnectionBadge(for: session)
            }
        }

        private var quickLoadFavourites: [LocalModel] {
            modelManager.favouriteModels(limit: modelManager.favouriteCapacity)
        }

        private var quickLoadRecents: [LocalModel] {
            let favouriteIDs = Set(quickLoadFavourites.map(\.id))
            return modelManager.recentModels(limit: 3, excludingIDs: favouriteIDs)
        }

        @ViewBuilder
        private func quickLoadLabel(for model: LocalModel, isFavourite: Bool) -> some View {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(quickLoadSubtitle(for: model))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: isFavourite ? "star.fill" : "clock")
                    .foregroundColor(isFavourite ? .yellow : .secondary)
            }
        }

        private func quickLoadSubtitle(for model: LocalModel) -> String {
            var parts: [String] = []
            if !model.quant.isEmpty {
                parts.append(model.quant)
            }
            parts.append(model.format.displayName)
            parts.append(quickLoadContextEstimate(for: model))
            parts.append(quickLoadMemoryEstimate(for: model))
            return parts.joined(separator: " · ")
        }

        private func quickLoadContextEstimate(for model: LocalModel) -> String {
            let settings = modelManager.settings(for: model)
            let context = Int(settings.contextLength.rounded())
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: context), number: .decimal)
            return String.localizedStringWithFormat(String(localized: "%@ ctx"), formatted)
        }

        private func quickLoadMemoryEstimate(for model: LocalModel) -> String {
            let settings = modelManager.settings(for: model)
            let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
            let layerHint: Int? = model.totalLayers > 0 ? model.totalLayers : nil
            let kvCacheEstimate = model.format == .gguf
                ? ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings)
                : .f16F16
            let estimate = ModelRAMAdvisor.estimateAndBudget(
                format: model.format,
                sizeBytes: sizeBytes,
                contextLength: Int(settings.contextLength),
                layerCount: layerHint,
                moeInfo: model.moeInfo,
                kvCacheEstimate: kvCacheEstimate,
                runtimeConfiguration: .resolved(from: settings, modelURL: model.url)
            )
            let estimateText = ByteCountFormatter.string(fromByteCount: estimate.estimate, countStyle: .memory)
            if let budget = estimate.budget, estimate.estimate > budget {
                return String.localizedStringWithFormat(String(localized: "~%@ over budget"), estimateText)
            }
            return String.localizedStringWithFormat(String(localized: "~%@ load"), estimateText)
        }

        private func quickLoadIfPossible(_ model: LocalModel) {
            guard quickLoadInProgress == nil else { return }
            guard !vm.loading else { return }
            quickLoad(model)
        }

        private func quickLoad(_ model: LocalModel) {
            quickLoadInProgress = model.id
            Task { @MainActor in
                defer { quickLoadInProgress = nil }

                if model.format == .et {
                    var settings = modelManager.settings(for: model)
                    settings.contextLength = max(1, settings.contextLength)
                    let success = await vm.load(url: model.url, settings: settings, format: .et, forceReload: true)
                    if success {
                        modelManager.updateSettings(settings, for: model)
                        modelManager.markModelUsed(model)
                        tabRouter.selection = .chat
                    } else {
                        modelManager.loadedModel = nil
                    }
                    return
                }

                await vm.unload()
                try? await Task.sleep(nanoseconds: 200_000_000)

                var settings = modelManager.settings(for: model)
                if model.format == .gguf && settings.gpuLayers == 0 {
                    settings.gpuLayers = -1
                }

                let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
                let ctx = Int(settings.contextLength)
                let layerHint: Int? = model.totalLayers > 0 ? model.totalLayers : nil
                let kvCacheEstimate = ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings)
                let bypassRAM = UserDefaults.standard.bool(forKey: "bypassRAMCheck")
                if !bypassRAM && !ModelRAMAdvisor.fitsInRAM(
                    format: model.format,
                    sizeBytes: sizeBytes,
                    contextLength: ctx,
                    layerCount: layerHint,
                    moeInfo: model.moeInfo,
                    kvCacheEstimate: kvCacheEstimate,
                    runtimeConfiguration: .resolved(from: settings, modelURL: model.url)
                ) {
                    AppSoundPlayer.play(.error)
                    Haptics.error()
                    vm.loadError = String(
                        localized: "Model likely exceeds memory budget. Lower context or choose a smaller quant.",
                        locale: LocalizationManager.preferredLocale()
                    )
                    modelManager.loadedModel = nil
                    return
                }

                var loadURL = model.url
                switch model.format {
                case .gguf:
                    var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                            if isDir.boolValue {
                                if let f = InstalledModelsStore.firstGGUF(in: loadURL) {
                                    loadURL = f
                                } else {
                                    vm.loadError = String(
                                        localized: "Model file missing (.gguf)",
                                        locale: LocalizationManager.preferredLocale()
                                    )
                                    modelManager.loadedModel = nil
                                    return
                                }
                            } else if loadURL.pathExtension.lowercased() != "gguf" || !InstalledModelsStore.isValidGGUF(at: loadURL) {
                                if let f = InstalledModelsStore.firstGGUF(in: loadURL.deletingLastPathComponent()) {
                                    loadURL = f
                                } else {
                                    vm.loadError = String(
                                        localized: "Model file missing (.gguf)",
                                        locale: LocalizationManager.preferredLocale()
                                    )
                                    modelManager.loadedModel = nil
                                    return
                                }
                            }
                    } else {
                        if let alt = InstalledModelsStore.firstGGUF(in: InstalledModelsStore.baseDir(for: .gguf, modelID: model.modelID)) {
                            loadURL = alt
                        } else {
                            vm.loadError = String(
                                localized: "Model path missing",
                                locale: LocalizationManager.preferredLocale()
                            )
                            modelManager.loadedModel = nil
                            return
                        }
                    }
                case .mlx:
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                        loadURL = isDir.boolValue ? loadURL : loadURL.deletingLastPathComponent()
                    } else {
                        var d: ObjCBool = false
                        let dir = InstalledModelsStore.baseDir(for: .mlx, modelID: model.modelID)
                        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &d), d.boolValue {
                            loadURL = dir
                        } else {
                            vm.loadError = String(
                                localized: "Model path missing",
                                locale: LocalizationManager.preferredLocale()
                            )
                            modelManager.loadedModel = nil
                            return
                        }
                    }
                case .et:
                    return
                case .ane:
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                        loadURL = isDir.boolValue ? loadURL : loadURL.deletingLastPathComponent()
                    } else {
                        let dir = InstalledModelsStore.baseDir(for: .ane, modelID: model.modelID)
                        var d: ObjCBool = false
                        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &d), d.boolValue {
                            loadURL = dir
                        } else {
                            vm.loadError = String(
                                localized: "Model path missing",
                                locale: LocalizationManager.preferredLocale()
                            )
                            modelManager.loadedModel = nil
                            return
                        }
                    }
                case .afm:
                    loadURL = InstalledModelsStore.baseDir(for: .afm, modelID: model.modelID)
                    try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
                case .coreai:
                    loadURL = InstalledModelsStore.baseDir(for: .coreai, modelID: model.modelID)
                    try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
                }

                var pendingFlagSet = false
                defer {
                    if pendingFlagSet {
                        UserDefaults.standard.set(false, forKey: "bypassRAMLoadPending")
                    }
                }

                UserDefaults.standard.set(true, forKey: "bypassRAMLoadPending")
                pendingFlagSet = true

                let success = await vm.load(url: loadURL, settings: settings, format: model.format)
                if success {
                    modelManager.updateSettings(settings, for: model)
                    modelManager.markModelUsed(model)
                    tabRouter.selection = .chat
                } else {
                    modelManager.loadedModel = nil
                }
            }
        }

        private struct ChatSnapshotSheet: View {
            @Environment(\.dismiss) private var dismiss
            let rows: [ChatSnapshotRow]
            let exportText: String

            var body: some View {
                NavigationStack {
                    List {
                        Section(LocalizedStringKey("Snapshot Receipt")) {
                            ForEach(rows) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(LocalizedStringKey(row.title))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(row.value)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .navigationTitle(Text("Chat Snapshot"))
#if os(iOS) || os(visionOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: exportText) {
                                Label("Share Snapshot", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
#if os(macOS)
                .frame(minWidth: 500, idealWidth: 580, minHeight: 460, idealHeight: 580)
#endif
            }
        }

        private struct ChatExportPackSheet: View {
            @Environment(\.dismiss) private var dismiss
            let noteTitle: String
            let markdownNote: String
            let citationsJSON: String
            let promptReceipt: String
            let generationReplayJSON: String
            @State private var exportFileURLs: [ChatExportPackBuilder.ExportKind: URL] = [:]
            @State private var exportFileError: String?
            @State private var markdownNoteURL: URL?
            @State private var markdownNoteError: String?

            var body: some View {
                NavigationStack {
                    List {
                        Section(LocalizedStringKey("Export Pack")) {
                            exportFileRow(
                                kind: .markdown,
                                titleKey: "Markdown Note",
                                subtitleKey: "Clean conversation note",
                                systemImage: "doc.plaintext"
                            )
                            exportFileRow(
                                kind: .pdf,
                                titleKey: "PDF Document",
                                subtitleKey: "Paginated conversation copy",
                                systemImage: "doc.richtext"
                            )
                            exportFileRow(
                                kind: .docx,
                                titleKey: "DOCX Document",
                                subtitleKey: "Word-compatible conversation package",
                                systemImage: "doc.text"
                            )
                            exportFileRow(
                                kind: .citationsJSON,
                                titleKey: "Citations JSON",
                                subtitleKey: "Source metadata for cited answers",
                                systemImage: "curlybraces"
                            )
                            exportFileRow(
                                kind: .promptReceipt,
                                titleKey: "Prompt Receipt",
                                subtitleKey: "Model, settings, dataset, and prompt fingerprint",
                                systemImage: "doc.badge.gearshape"
                            )
                            exportFileRow(
                                kind: .generationReplayJSON,
                                titleKey: "Replay JSON",
                                subtitleKey: "Prompt, output, timings, tools, and citations",
                                systemImage: "arrow.trianglehead.clockwise"
                            )

                            if let exportFileError, !exportFileError.isEmpty {
                                Text(exportFileError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        Section(LocalizedStringKey("Local Note")) {
                            Button {
                                saveMarkdownNote()
                            } label: {
                                Label(LocalizedStringKey("Save Markdown Note"), systemImage: "square.and.arrow.down")
                            }

                            if let markdownNoteURL {
                                ShareLink(item: markdownNoteURL) {
                                    Label(LocalizedStringKey("Share Saved Note"), systemImage: "square.and.arrow.up")
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(LocalizedStringKey("Note File"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(markdownNoteURL.lastPathComponent)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 4)
                            }

                            if let markdownNoteError, !markdownNoteError.isEmpty {
                                Text(markdownNoteError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else {
                                Text(LocalizedStringKey("Save the conversation as a local Markdown note."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationTitle(Text("Export Pack"))
#if os(iOS) || os(visionOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                    .task(id: exportTaskID) {
                        generateExportFiles()
                    }
                }
#if os(macOS)
                .frame(minWidth: 500, idealWidth: 560, minHeight: 360, idealHeight: 460)
#endif
            }

            private var exportTaskID: String {
                "\(noteTitle)|\(markdownNote.count)|\(citationsJSON.count)|\(promptReceipt.count)|\(generationReplayJSON.count)"
            }

            @ViewBuilder
            private func exportFileRow(
                kind: ChatExportPackBuilder.ExportKind,
                titleKey: String,
                subtitleKey: String,
                systemImage: String
            ) -> some View {
                if let url = exportFileURLs[kind] {
                    ShareLink(item: url) {
                        exportFileLabel(titleKey: titleKey, subtitleKey: subtitleKey, systemImage: systemImage)
                    }
                } else {
                    Button {
                        generateExportFiles()
                    } label: {
                        exportFileLabel(titleKey: titleKey, subtitleKey: subtitleKey, systemImage: systemImage)
                    }
                }
            }

            private func exportFileLabel(titleKey: String, subtitleKey: String, systemImage: String) -> some View {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey(titleKey))
                            .font(.body.weight(.medium))
                        Text(LocalizedStringKey(subtitleKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: systemImage)
                }
                .padding(.vertical, 4)
            }

            private func generateExportFiles() {
                do {
                    exportFileURLs = try ChatExportPackBuilder.writeExportPack(
                        title: noteTitle,
                        markdownNote: markdownNote,
                        citationsJSON: citationsJSON,
                        promptReceipt: promptReceipt,
                        generationReplayJSON: generationReplayJSON
                    )
                    exportFileError = nil
                } catch {
                    exportFileURLs = [:]
                    exportFileError = error.localizedDescription
                }
            }

            private func saveMarkdownNote() {
                do {
                    let filename = "\(ChatExportPackBuilder.sanitizedFileStem(noteTitle))-note-\(ChatExportPackBuilder.fileTimestamp()).md"
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                    try markdownNote.write(to: url, atomically: true, encoding: .utf8)
                    markdownNoteURL = url
                    markdownNoteError = nil
                } catch {
                    markdownNoteURL = nil
                    markdownNoteError = error.localizedDescription
                }
            }
        }

        private struct ChatContextPlanSheet: View {
            @Environment(\.dismiss) private var dismiss
            let rows: [ContextPlanRow]
            let summary: String

            var body: some View {
                NavigationStack {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Prompt window")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(verbatim: summary)
                                    .font(.body.weight(.medium))
                            }
                            .padding(.vertical, 4)
                        } footer: {
                            Text("Older messages marked at risk are the first candidates for summarizing or dropping when the prompt gets too large.")
                        }

                        Section(LocalizedStringKey("Messages")) {
                            if rows.isEmpty {
                                Text("No conversation messages")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(rows) { row in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 8) {
                                            Text(verbatim: row.roleTitle)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text(LocalizedStringKey(row.statusKey))
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(row.tint)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(row.tint.opacity(0.12), in: Capsule())
                                            Text(verbatim: "\(row.tokenCount) tok")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(verbatim: row.preview)
                                            .font(.callout)
                                            .lineLimit(3)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .navigationTitle(Text("Context Plan"))
#if os(iOS) || os(visionOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
#if os(macOS)
                .frame(minWidth: 520, idealWidth: 620, minHeight: 460, idealHeight: 620)
#endif
            }
        }

        private struct ChatScratchpadSheet: View {
            @Binding var text: String
            let titleKey: String
            let placeholderKey: String
            let clearTitleKey: String
            let onCancel: () -> Void
            let onSave: () -> Void
            let onClear: () -> Void

            var body: some View {
                NavigationStack {
                    VStack(spacing: 12) {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $text)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .padding(14)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            if text.isEmpty {
                                Text(LocalizedStringKey(placeholderKey))
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 22)
                                    .padding(.leading, 20)
                                    .allowsHitTesting(false)
                            }
                        }

                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(role: .destructive, action: onClear) {
                                Label {
                                    Text(LocalizedStringKey(clearTitleKey))
                                        .industrialCTAWidth()
                                } icon: {
                                    Image(systemName: "trash")
                                }
                            }
                            .buttonStyle(.industrial(.destructive))
                        }
                    }
                    .padding()
                    .navigationTitle(Text(LocalizedStringKey(titleKey)))
#if os(iOS) || os(visionOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onCancel)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button("Done", action: onSave)
                        }
                    }
                }
#if os(macOS)
                .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 520)
#endif
            }
        }

        private struct ChatRuntimeInfoSheet: View {
            @Environment(\.dismiss) private var dismiss
            @EnvironmentObject private var vm: ChatVM
            @EnvironmentObject private var modelManager: AppModelManager
            @State private var latestResponse: LoopbackResponseDiagnostics?
            @State private var lastStartOptions: LlamaServerBridge.StartOptions?

            private var loadedModel: LocalModel? { modelManager.loadedModel }

            private var activeSettings: ModelSettings? {
                if let settings = vm.loadedModelSettings {
                    return settings
                }
                if let loadedModel {
                    return modelManager.settings(for: loadedModel)
                }
                return nil
            }

            var body: some View {
                NavigationStack {
                    ZStack {
                        RuntimeInfoSurfaceBackground()
                            .ignoresSafeArea()

                        VStack(spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 24) {
                                    Text("Runtime Information")
                                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    RuntimeInfoSection(
                                        title: "Runtime",
                                        systemImage: "cpu",
                                        isCollapsible: false,
                                        items: runtimeRows
                                    )

                                    if let settings = activeSettings {
                                        RuntimeInfoSection(
                                            title: "Sampling Parameters",
                                            systemImage: "thermometer.medium",
                                            items: samplingRows(settings)
                                        )
                                        RuntimeInfoSection(
                                            title: "Draft Information",
                                            systemImage: "square.and.pencil",
                                            items: draftRows(settings)
                                        )
                                    } else {
                                        RuntimeInfoSection(
                                            title: "Sampling Parameters",
                                            systemImage: "thermometer.medium",
                                            items: [
                                                RuntimeInfoItem("Status", value: String(localized: "No local model loaded"))
                                            ]
                                        )
                                    }

                                    RuntimeInfoSection(
                                        title: "Draft Diagnostics",
                                        systemImage: "chart.line.uptrend.xyaxis",
                                        items: diagnosticsRows
                                    )
                                    RuntimeInfoSection(
                                        title: "Server Launch",
                                        systemImage: "server.rack",
                                        items: serverRows
                                    )
                                }
                                .padding(.horizontal, runtimeHorizontalPadding)
                                .padding(.top, runtimeTopPadding)
                                .padding(.bottom, 24)
                                .frame(maxWidth: 760)
                                .frame(maxWidth: .infinity)
                            }
                            .scrollIndicators(.hidden)

                            RuntimeInfoFooter(
                                close: { dismiss() },
                                refresh: { refreshDiagnostics() }
                            )
                        }
                    }
                }
#if os(macOS)
                .frame(minWidth: 620, idealWidth: 720, maxWidth: 820, minHeight: 560, idealHeight: 760)
#endif
                .task { refreshDiagnostics() }
            }

            private var runtimeHorizontalPadding: CGFloat {
#if os(macOS)
                28
#else
                20
#endif
            }

            private var runtimeTopPadding: CGFloat {
#if os(macOS)
                28
#else
                22
#endif
            }

            private var runtimeRows: [RuntimeInfoItem] {
                if let remote = modelManager.activeRemoteSession {
                    return [
                        RuntimeInfoItem("Model", value: remote.modelName),
                        RuntimeInfoItem("Backend", value: remote.backendName),
                        RuntimeInfoItem("Format", value: String(localized: "Remote"))
                    ]
                } else if let loadedModel {
                    var rows = [
                        RuntimeInfoItem("Model", value: loadedModel.name),
                        RuntimeInfoItem("Format", value: loadedModel.format.displayName)
                    ]
                    if !loadedModel.quant.isEmpty {
                        rows.append(RuntimeInfoItem("Quantization", value: loadedModel.quant))
                    }
                    rows.append(RuntimeInfoItem("Path", value: loadedModel.url.lastPathComponent))
                    return rows
                }
                return [
                    RuntimeInfoItem("Model", value: String(localized: "None"))
                ]
            }

            private func samplingRows(_ settings: ModelSettings) -> [RuntimeInfoItem] {
                [
                    RuntimeInfoItem("Temperature", value: decimal(settings.temperature)),
                    RuntimeInfoItem("Top-p", value: decimal(settings.topP)),
                    RuntimeInfoItem("Top-k", value: "\(settings.topK)"),
                    RuntimeInfoItem("Min-p", value: decimal(settings.minP)),
                    RuntimeInfoItem("Repetition Penalty", value: decimal(Double(settings.repetitionPenalty))),
                    RuntimeInfoItem("Repeat Last N", value: "\(settings.repeatLastN)"),
                    RuntimeInfoItem("Presence Penalty", value: decimal(Double(settings.presencePenalty))),
                    RuntimeInfoItem("Frequency Penalty", value: decimal(Double(settings.frequencyPenalty))),
                    RuntimeInfoItem("Seed", value: settings.seed.map(String.init) ?? String(localized: "Default")),
                    RuntimeInfoItem("Context", value: "\(Int(settings.contextLength))"),
                    RuntimeInfoItem("CPU Threads", value: settings.cpuThreads > 0 ? "\(settings.cpuThreads)" : String(localized: "Auto")),
                    RuntimeInfoItem("GPU Layers", value: settings.gpuLayers < 0 ? String(localized: "Auto") : "\(settings.gpuLayers)"),
                    RuntimeInfoItem("Flash Attention", value: flag(settings.flashAttention)),
                    RuntimeInfoItem("KV Offload", value: flag(settings.kvCacheOffload)),
                    RuntimeInfoItem("K Cache", value: settings.kCacheQuant.rawValue),
                    RuntimeInfoItem("V Cache", value: settings.vCacheQuant.rawValue),
                    RuntimeInfoItem("Prompt Cache", value: flag(settings.promptCacheEnabled))
                ]
            }

            private func draftRows(_ settings: ModelSettings) -> [RuntimeInfoItem] {
                [
                    RuntimeInfoItem("Speculative Mode", value: speculativeSelectionTitle(settings.speculativeDecoding.selection)),
                    RuntimeInfoItem("MTP Auto-Tune", value: flag(settings.speculativeDecoding.mtpAutoTune)),
                    RuntimeInfoItem("MTP Draft Tokens", value: settings.speculativeDecoding.mtpAutoTuneActive
                        ? String.localizedStringWithFormat(String(localized: "Auto (up to %lld)"), Int64(settings.speculativeDecoding.effectiveMTPDraftNMax))
                        : "\(settings.speculativeDecoding.resolvedMTPDraftNMax)"),
                    RuntimeInfoItem("MTP Min Draft Tokens", value: "\(settings.speculativeDecoding.resolvedMTPDraftNMin)"),
                    RuntimeInfoItem("MTP Draft P-Min", value: String(format: "%.2f", settings.speculativeDecoding.resolvedMTPDraftPMin)),
                    RuntimeInfoItem("Draft Strategy", value: draftModeTitle(settings.speculativeDecoding.mode)),
                    RuntimeInfoItem("Draft Value", value: "\(settings.speculativeDecoding.value)"),
                    RuntimeInfoItem("Helper Model", value: settings.speculativeDecoding.helperModelID ?? String(localized: "None")),
                    RuntimeInfoItem("MTP Support", value: mtpSupportText),
                    RuntimeInfoItem("MTP Source", value: mtpSourceText)
                ]
            }

            private var diagnosticsRows: [RuntimeInfoItem] {
                var rows: [RuntimeInfoItem] = []
                if let timings = latestResponse?.timings {
                    rows.append(RuntimeInfoItem("Draft Generated", value: timings.draftN.map(String.init) ?? String(localized: "Unavailable")))
                    rows.append(RuntimeInfoItem("Draft Accepted", value: timings.draftNAccepted.map(String.init) ?? String(localized: "Unavailable")))
                    rows.append(RuntimeInfoItem("Acceptance", value: timings.acceptanceRate.map { percent($0) } ?? String(localized: "Unavailable")))
                    if let dynLength = timings.draftNDyn {
                        rows.append(RuntimeInfoItem("Auto Draft Length", value: dynLength > 0 ? "\(dynLength)" : String(localized: "Paused")))
                    }
                    rows.append(RuntimeInfoItem("Predicted Speed", value: timings.predictedPerSecond.map { String.localizedStringWithFormat(String(localized: "%.1f tok/s"), $0) } ?? String(localized: "Unavailable")))
                    rows.append(RuntimeInfoItem("Prompt Speed", value: timings.promptPerSecond.map { String.localizedStringWithFormat(String(localized: "%.1f tok/s"), $0) } ?? String(localized: "Unavailable")))
                    rows.append(RuntimeInfoItem("Prompt Tokens", value: timings.promptN.map(String.init) ?? String(localized: "Unavailable")))
                    rows.append(RuntimeInfoItem("Output Tokens", value: timings.predictedN.map(String.init) ?? String(localized: "Unavailable")))
                } else {
                    rows.append(RuntimeInfoItem("Status", value: String(localized: "No response diagnostics yet")))
                }
                if let latestResponse {
                    rows.append(RuntimeInfoItem("Endpoint", value: latestResponse.endpoint))
                    rows.append(RuntimeInfoItem("Request Mode", value: latestResponse.requestMode))
                    rows.append(RuntimeInfoItem("Streaming", value: flag(latestResponse.streaming)))
                    rows.append(RuntimeInfoItem("Finish Reason", value: latestResponse.finishReason ?? String(localized: "None")))
                    rows.append(RuntimeInfoItem("Output Characters", value: "\(latestResponse.outputCharacters)"))
                }
                return rows
            }

            private var serverRows: [RuntimeInfoItem] {
                if let lastStartOptions,
                   LlamaServerBridge.port() == Int32(lastStartOptions.port) {
                    return [
                        RuntimeInfoItem("Port", value: "\(lastStartOptions.port)"),
                        RuntimeInfoItem("Context", value: "\(lastStartOptions.contextSize)"),
                        RuntimeInfoItem("Threads", value: "\(lastStartOptions.threads) / \(lastStartOptions.threadsBatch)"),
                        RuntimeInfoItem("Evaluation Batch Size", value: "\(lastStartOptions.batchSize) / \(lastStartOptions.ubatchSize)"),
                        RuntimeInfoItem("Memory Map", value: flag(lastStartOptions.useMmap)),
                        RuntimeInfoItem("Keep Model In Memory", value: flag(lastStartOptions.useMlock)),
                        RuntimeInfoItem("Unified KV Cache", value: flag(lastStartOptions.unifiedKVCache)),
                        RuntimeInfoItem("Prompt Cache", value: "\(lastStartOptions.cacheRamMiB) MiB / \(lastStartOptions.ctxCheckpoints)"),
                        RuntimeInfoItem("CPU", value: "NEON \(flag(lastStartOptions.cpuNEON)) · DOT \(flag(lastStartOptions.cpuDotProduct)) · I8MM \(flag(lastStartOptions.cpuI8MM)) · repack \(flag(lastStartOptions.cpuRepack))"),
                        RuntimeInfoItem("Speculative Type", value: lastStartOptions.speculativeType.isEmpty ? String(localized: "None") : lastStartOptions.speculativeType),
                        RuntimeInfoItem("Draft Model", value: lastStartOptions.mtpPath.isEmpty ? String(localized: "Embedded MTP head or none") : URL(fileURLWithPath: lastStartOptions.mtpPath).lastPathComponent),
                        RuntimeInfoItem("MTP Draft Tokens", value: {
                            guard let nMax = lastStartOptions.specDraftNMax else { return String(localized: "None") }
                            if lastStartOptions.specDynamic == true {
                                return String.localizedStringWithFormat(String(localized: "Auto (up to %lld)"), Int64(nMax))
                            }
                            return String(nMax)
                        }()),
                        RuntimeInfoItem("Server Arguments", value: lastStartOptions.argv.joined(separator: " "))
                    ]
                }
                if let diagnostics = LlamaServerBridge.lastStartDiagnostics() {
                    return [RuntimeInfoItem("Status", value: diagnostics.message)]
                }
                return [
                    RuntimeInfoItem("Status", value: String(localized: "No server launch recorded"))
                ]
            }

            private var mtpSupportText: String {
                guard let url = vm.loadedModelURL ?? loadedModel?.url else { return String(localized: "Unavailable") }
                let sidecar = MtpLocator.mtpPath(alongside: url) != nil
                let embedded = GGUFMetadata.hasMTP(at: url)
                if sidecar && embedded { return String(localized: "MTP sidecar and embedded head") }
                if sidecar { return String(localized: "MTP sidecar") }
                if embedded { return String(localized: "Embedded MTP head") }
                return String(localized: "Unavailable")
            }

            private var mtpSourceText: String {
                guard let url = vm.loadedModelURL ?? loadedModel?.url else {
                    return String(localized: "None")
                }
                if let path = MtpLocator.mtpPath(alongside: url) {
                    return URL(fileURLWithPath: path).lastPathComponent
                }
                if GGUFMetadata.hasMTP(at: url) {
                    return String(localized: "Embedded MTP head")
                }
                return String(localized: "None")
            }

            private func refreshDiagnostics() {
                lastStartOptions = LlamaServerBridge.lastStartOptions()
                Task {
                    let snapshot = await LoopbackRuntimeDiagnostics.shared.latestResponseSnapshot()
                    await MainActor.run {
                        latestResponse = snapshot
                    }
                }
            }

            private func speculativeSelectionTitle(_ selection: ModelSettings.SpeculativeDecodingSettings.Selection) -> String {
                switch selection {
                case .off: return String(localized: "Off")
                case .helperDraftModel: return String(localized: "Helper Model")
                case .mtp: return String(localized: "Multi-Token Prediction")
                }
            }

            private func draftModeTitle(_ mode: ModelSettings.SpeculativeDecodingSettings.Mode) -> String {
                switch mode {
                case .tokens: return String(localized: "Draft Tokens")
                case .max: return String(localized: "Adaptive Draft Limit")
                }
            }

            private func flag(_ value: Bool) -> String {
                value ? String(localized: "On") : String(localized: "Off")
            }

            private func decimal(_ value: Double, digits: Int = 2) -> String {
                String(format: "%.\(digits)f", value)
            }

            private func percent(_ value: Double) -> String {
                String.localizedStringWithFormat(String(localized: "%.1f%%"), value * 100)
            }
        }

        private struct RuntimeInfoItem {
            let title: LocalizedStringKey
            let value: String

            init(_ title: LocalizedStringKey, value: String) {
                self.title = title
                self.value = value
            }
        }

        private struct RuntimeInfoSurfaceBackground: View {
            @Environment(\.colorScheme) private var colorScheme

            var body: some View {
                baseColor
                    .overlay {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.03 : 0.42),
                                Color.blue.opacity(colorScheme == .dark ? 0.04 : 0.035),
                                Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
            }

            @ViewBuilder
            private var baseColor: some View {
#if os(macOS)
                Color(nsColor: .windowBackgroundColor)
#elseif os(visionOS)
                Color.clear
#else
                Color(uiColor: .systemGroupedBackground)
#endif
            }
        }

        private struct RuntimeInfoSection: View {
            let title: LocalizedStringKey
            let systemImage: String
            let isCollapsible: Bool
            let items: [RuntimeInfoItem]
            @State private var isExpanded: Bool

            init(title: LocalizedStringKey, systemImage: String, isCollapsible: Bool = true, items: [RuntimeInfoItem]) {
                self.title = title
                self.systemImage = systemImage
                self.isCollapsible = isCollapsible
                self.items = items
                _isExpanded = State(initialValue: true)
            }

            var body: some View {
                VStack(alignment: .leading, spacing: 10) {
                    if isCollapsible {
                        Button {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            header
                        }
                        .buttonStyle(.plain)
                    } else {
                        header
                    }

                    if isExpanded {
                        VStack(spacing: 0) {
                            ForEach(items.indices, id: \.self) { index in
                                RuntimeInfoRow(title: items[index].title, value: items[index].value)
                                if index < items.count - 1 {
                                    Divider()
                                        .overlay(Color.primary.opacity(0.05))
                                        .padding(.leading, 14)
                                }
                            }
                        }
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.regularMaterial)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: Color.black.opacity(0.045), radius: 14, x: 0, y: 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            private var header: some View {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)

                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    if isCollapsible {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
        }

        private struct RuntimeInfoFooter: View {
            let close: () -> Void
            let refresh: () -> Void

            var body: some View {
                HStack(spacing: 12) {
                    Spacer()
                    Button(action: close) {
                        Text("Close")
                    }
                    .buttonStyle(.industrial(.quiet))
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)

                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.industrial(.prominent))
                    .controlSize(.large)
                    .accessibilityLabel(Text("Refresh"))
                }
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 18)
                .background(.regularMaterial)
                .overlay(alignment: .top) {
                    Divider()
                        .overlay(Color.primary.opacity(0.06))
                }
            }
        }

        private struct RuntimeInfoRow: View {
            let title: LocalizedStringKey
            let value: String

            var body: some View {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Text(value)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(.callout, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(minHeight: 34)
            }
        }

#if os(macOS)
        private struct AdvancedSettingsSidebar: View {
            @Binding var settings: ModelSettings
            let model: LocalModel?
            let models: [LocalModel]
            let hide: () -> Void
            @State private var isGreedyOnlyModel = false

            private var helperOptions: [LocalModel] {
                guard let base = model else { return [] }
                return models.filter { candidate in
                    guard candidate.id != base.id else { return false }
                    guard candidate.format == .gguf else { return false }
                    guard candidate.matchesArchitectureFamily(of: base) else { return false }
                    // A paged install cannot load resident as the draft; ChatVM
                    // rejects it at launch, so the picker must not offer it.
                    guard !OverfitPagedInstallCache.isPaged(candidate.url) else { return false }
                    let baseSize = base.sizeGB
                    let candidateSize = candidate.sizeGB
                    if baseSize > 0, candidateSize > 0, candidateSize - baseSize > 0.01 {
                        return false
                    }
                    return true
                }
            }

            private var modelHasMTPSupport: Bool {
                guard let model, model.format == .gguf else { return false }
                return MtpLocator.hasMtpFile(alongside: model.url) || GGUFMetadata.hasMTP(at: model.url)
            }

            private var format: ModelFormat? { model?.format }

            private var supportsTopP: Bool { format != .et && format != .afm }
            private var supportsTopK: Bool { format != .et }
            private var supportsMinP: Bool { format == .gguf || format == .mlx || format == .ane }
            private var supportsRepetitionPenalty: Bool { format == .gguf || format == .mlx || format == .ane }
            private var supportsRepeatLastN: Bool { format == .gguf || format == .mlx }
            private var supportsPresencePenalty: Bool { format == .gguf || format == .mlx }
            private var supportsFrequencyPenalty: Bool { format == .gguf || format == .mlx }
            private var supportsSeed: Bool { format == .gguf || format == .afm }
            private var supportsSpeculativeDecoding: Bool {
#if os(macOS)
                return format == .gguf
#elseif os(visionOS)
                return false
#else
                return format == .gguf
#endif
            }

            var body: some View {
                VStack(spacing: 0) {
                    HStack {
                        Text("Advanced Controls")
                            .font(.headline)
                        Spacer()
                        Button(action: hide) {
                            Image(systemName: "sidebar.trailing")
                                .imageScale(.medium)
                        }
                        .buttonStyle(.plain)
                        .help("Collapse controls")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            samplingSection
                            if supportsSpeculativeDecoding {
                                speculativeSection
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                    }
                }
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .leading) {
                    Color.primary.opacity(0.08)
                        .frame(width: 1)
                        .ignoresSafeArea()
                }
                .task(id: model?.url.path ?? "") {
                    guard let model else {
                        isGreedyOnlyModel = false
                        return
                    }
                    switch model.format {
                    case .ane:
                        let modelURL = model.url
                        isGreedyOnlyModel = await Task.detached(priority: .utility) {
                            ANEMLLCapabilityLookup.argmaxInModel(modelURL: modelURL)
                        }.value
                    case .coreai:
                        // ios-gpu bundles fuse argmax into the graph, so no
                        // host-side sampling control can affect their output.
                        isGreedyOnlyModel = CoreAIBundleFamily.detect(from: model.quant) == .iosGPU
                    case .gguf, .mlx, .et, .afm:
                        isGreedyOnlyModel = false
                    }
                }
            }

            private var samplingSection: some View {
                sidebarSection(title: "Sampling", systemImage: "dial.medium") {
                    if isGreedyOnlyModel {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(LocalizedStringKey("Sampling unavailable for Argmax models"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 8) {
                                sliderRow("Temperature", value: $settings.temperature, range: 0...2, step: 0.05)
                                Text("Creativity: \(settings.temperature, format: .number.precision(.fractionLength(2))). Low values focus responses; high values add variety.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if supportsTopP {
                                VStack(alignment: .leading, spacing: 8) {
                                    sliderRow("Top-p", value: $settings.topP, range: 0...1, step: 0.01)
                                    Text("Top-p: \(settings.topP, format: .number.precision(.fractionLength(2)))")
                                        .font(.footnote.monospacedDigit())
                                }
                            }

                            if supportsTopK {
                                Stepper(value: $settings.topK, in: 1...2048, step: 1) {
                                    Text("Top-k: \(settings.topK)")
                                }
                            }

                            if supportsMinP {
                                VStack(alignment: .leading, spacing: 8) {
                                    sliderRow("Min-p", value: $settings.minP, range: 0...1, step: 0.01)
                                    Text("Min-p: \(settings.minP, format: .number.precision(.fractionLength(2)))")
                                        .font(.footnote.monospacedDigit())
                                }
                            }

                            if supportsRepetitionPenalty {
                                Stepper(
                                    value: Binding(
                                        get: { Double(settings.repetitionPenalty) },
                                        set: { settings.repetitionPenalty = Float($0) }
                                    ),
                                    in: 0.8...2.0,
                                    step: 0.05
                                ) {
                                    Text("Repetition penalty: \(Double(settings.repetitionPenalty), format: .number.precision(.fractionLength(2)))")
                                }
                            }

                            if supportsRepeatLastN {
                                Stepper(value: $settings.repeatLastN, in: 0...4096, step: 16) {
                                    Text("Repeat last N tokens: \(settings.repeatLastN)")
                                }
                            }

                            if supportsPresencePenalty {
                                Stepper(
                                    value: Binding(
                                        get: { Double(settings.presencePenalty) },
                                        set: { settings.presencePenalty = Float($0) }
                                    ),
                                    in: -2.0...2.0,
                                    step: 0.1
                                ) {
                                    Text("Presence penalty: \(Double(settings.presencePenalty), format: .number.precision(.fractionLength(1)))")
                                }
                            }

                            if supportsFrequencyPenalty {
                                Stepper(
                                    value: Binding(
                                        get: { Double(settings.frequencyPenalty) },
                                        set: { settings.frequencyPenalty = Float($0) }
                                    ),
                                    in: -2.0...2.0,
                                    step: 0.1
                                ) {
                                    Text("Frequency penalty: \(Double(settings.frequencyPenalty), format: .number.precision(.fractionLength(1)))")
                                }
                            }

                            if supportsSeed {
                                TextField(
                                    "Seed",
                                    text: Binding(
                                        get: { settings.seed.map(String.init) ?? "" },
                                        set: { rawValue in
                                            let filtered = rawValue.filter(\.isNumber)
                                            settings.seed = Int(filtered)
                                        }
                                    ),
                                    prompt: Text("Default")
                                )
                                .textFieldStyle(.roundedBorder)
                            }

                            if supportsRepetitionPenalty || supportsPresencePenalty || supportsFrequencyPenalty {
                                Text("Smooth loops and phrase echo by balancing repetition controls.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .disabled(model == nil)
            }

            private var speculativeSection: some View {
                sidebarSection(title: "Speculative Decoding", systemImage: "bolt.fill") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Speed up generation with a helper model or Multi-Token Prediction.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Speculative Mode", selection: speculativeSelectionBinding) {
                            ForEach(ModelSettings.SpeculativeDecodingSettings.Selection.allCases) { selection in
                                Text(selection.title).tag(selection)
                                    .disabled(selection == .mtp && !modelHasMTPSupport)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onAppear { enforceSpeculativeSelectionAvailability() }
                        .onChange(of: modelHasMTPSupport) { _ in enforceSpeculativeSelectionAvailability() }

                        if !modelHasMTPSupport {
                            mtpUnavailableNotice
                        }

                        if settings.speculativeDecoding.selection == .mtp {
                            Stepper(value: $settings.speculativeDecoding.mtpDraftNMax, in: 1...6, step: 1) {
                                Text(String.localizedStringWithFormat(String(localized: "MTP draft tokens: %@"), "\(settings.speculativeDecoding.resolvedMTPDraftNMax)"))
                            }
                            Stepper(value: $settings.speculativeDecoding.mtpDraftNMin, in: 0...6, step: 1) {
                                Text(String.localizedStringWithFormat(String(localized: "MTP min draft tokens: %@"), "\(settings.speculativeDecoding.resolvedMTPDraftNMin)"))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String.localizedStringWithFormat(String(localized: "MTP draft probability floor: %@"), String(format: "%.2f", settings.speculativeDecoding.resolvedMTPDraftPMin)))
                                Slider(value: $settings.speculativeDecoding.mtpDraftPMin, in: 0.0...1.0, step: 0.05)
                                Text("MTP confidence is measured before top-k filtering. Set the probability floor to 0 to disable it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if settings.speculativeDecoding.selection == .helperDraftModel {
                        Picker("Helper Model", selection: Binding(
                            get: { settings.speculativeDecoding.helperModelID },
                            set: { settings.speculativeDecoding.helperModelID = $0 }
                        )) {
                            Text("None").tag(String?.none)
                            ForEach(helperOptions, id: \.id) { candidate in
                                Text(candidate.name).tag(String?.some(candidate.id))
                            }
                        }

                        if helperOptions.isEmpty {
                            Text("Install another model from the same model family with equal or smaller size to enable speculative decoding.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if settings.speculativeDecoding.helperModelID != nil {
                            Picker("Draft strategy", selection: $settings.speculativeDecoding.mode) {
                                ForEach(ModelSettings.SpeculativeDecodingSettings.Mode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            Stepper(value: $settings.speculativeDecoding.value, in: 1...2048, step: 1) {
                                switch settings.speculativeDecoding.mode {
                                case .tokens:
                                    Text("Draft tokens: \(settings.speculativeDecoding.value)")
                                case .max:
                                    Text("Draft window: \(settings.speculativeDecoding.value)")
                                }
                            }
                        }
                        }
                    }
                }
            }

            private var speculativeSelectionBinding: Binding<ModelSettings.SpeculativeDecodingSettings.Selection> {
                Binding(
                    get: {
                        if settings.speculativeDecoding.selection == .mtp, !modelHasMTPSupport {
                            return .off
                        }
                        return settings.speculativeDecoding.selection
                    },
                    set: { selection in
                        settings.speculativeDecoding.selection = (selection == .mtp && !modelHasMTPSupport) ? .off : selection
                    }
                )
            }

            @ViewBuilder
            private var mtpUnavailableNotice: some View {
                Label {
                    Text("MTP is unavailable for this model. Choose another GGUF with an MTP head or bundled MTP weights. Helper-model speculative decoding is still available.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            private func enforceSpeculativeSelectionAvailability() {
                if settings.speculativeDecoding.selection == .mtp, !modelHasMTPSupport {
                    settings.speculativeDecoding.selection = .off
                }
            }


            private func sidebarSection<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
                VStack(alignment: .leading, spacing: 16) {
                    Label(title, systemImage: systemImage)
                        .font(.subheadline.weight(.semibold))
                    content()
                }
            }

            private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                    Slider(value: value, in: range, step: step)
                        .padding(.vertical, 2)
                }
            }
        }
#endif

        private var sidebar: some View {
            return VStack(alignment: .leading) {
                HStack {
                    Text("Recent Chats").font(.headline)
                    Spacer()
                    Button(action: { vm.startNewSession() }) { Image(systemName: "plus") }
                }
                .padding()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(LocalizedStringKey("Search chats"), text: $chatRecallQuery)
                        .platformAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .font(.caption)
                    if !chatRecallQuery.isEmpty {
                        Button {
                            chatRecallQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LocalizedStringKey("Clear Chat Search"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal)
                .padding(.bottom, 4)

                List(selection: $vm.activeSessionID) {
                    if !chatRecallQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section(LocalizedStringKey("Chat Recall")) {
                            if chatRecallResults.isEmpty {
                                Text(LocalizedStringKey("No matching messages"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(chatRecallResults.prefix(8)) { result in
                                    Button {
                                        openRecallResult(result)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 5) {
                                                Image(systemName: result.message.isBookmarked ? "bookmark.fill" : "text.magnifyingglass")
                                                    .font(.caption2)
                                                    .foregroundStyle(Color.accentColor)
                                                Text(sessionDisplayTitle(for: result.session))
                                                    .font(.caption.weight(.semibold))
                                                    .lineLimit(1)
                                            }
                                            Text(bookmarkPreview(for: result.message))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(LocalizedStringKey("Chat search result"))
                                }
                            }
                        }
                    }

                    if !bookmarkedMessages.isEmpty {
                        Section(LocalizedStringKey("Bookmarks")) {
                            ForEach(bookmarkedMessages.prefix(8)) { bookmark in
                                Button {
                                    openBookmark(bookmark)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 5) {
                                            Image(systemName: "bookmark.fill")
                                                .font(.caption2)
                                                .foregroundStyle(Color.accentColor)
                                            Text(sessionDisplayTitle(for: bookmark.session))
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(1)
                                        }
                                        Text(bookmarkPreview(for: bookmark.message))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    ForEach(vm.sessions) { session in
                        HStack {
                            Image(systemName: session.isFavorite ? "star.fill" : "message")
                            Text(session.title)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.select(session)
                            withAnimation { showSidebar = false }
                        }
                        .contextMenu {
                            Button(session.isFavorite ? "Unfavorite" : "Favorite") { vm.toggleFavorite(session) }
                            Button(role: .destructive) { sessionToDelete = session } label: { Text("Delete") }
                        }
                        .swipeActions {
                            Button(role: .destructive) { sessionToDelete = session } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.plain)
                .confirmationDialog("Delete chat \(sessionToDelete?.title ?? "")?", isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } })) {
                    Button("Delete", role: .destructive) { if let s = sessionToDelete { vm.delete(s); sessionToDelete = nil } }
                    Button("Cancel", role: .cancel) { sessionToDelete = nil }
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .ignoresSafeArea(edges: .bottom)
        }


    }

    private struct SuggestionsOverlay: View {
        let suggestions: [String]
        let enabled: Bool
        let onTap: (String) -> Void
        let onDisabledTap: () -> Void

        var body: some View {
            VStack(spacing: 20) {
                Image("Noema")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .opacity(0.9)
                    .accessibilityHidden(true)

                VStack(spacing: 12) {
                    ForEach(suggestions.prefix(3), id: \.self) { s in
                        Button(action: {
                            if enabled {
                                onTap(s)
                            } else {
                                onDisabledTap()
                            }
                        }) {
                            Text(s)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 14)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: 520)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.systemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
                        .padding(.horizontal)
                        .opacity(enabled ? 1.0 : 0.6)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
    }
}
#endif
