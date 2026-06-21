#if os(visionOS)
import SwiftUI
import UIKit

/// Chat experience tailored for visionOS builds. Mirrors the core behaviour of
/// the iOS chat screen while adopting spatial-friendly controls.
struct ChatView: View {
    @EnvironmentObject private var vm: ChatVM
    @EnvironmentObject private var tabRouter: TabRouter
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @AppStorage("isAdvancedMode") private var isAdvancedMode = false

    @State private var scrollProxy: ScrollViewProxy?
    @State private var showSessionTray = false
    @State private var suggestionTriplet: [String] = ChatSuggestions.nextThree()
    @State private var suggestionsSessionID: UUID?
    @State private var showModelRequiredAlert = false
    @State private var measuredHeight: CGFloat = 0

    private struct InputHeightPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat { 0 }
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private let composerCollapsedHeight: CGFloat = 52
    private let composerExpandedHeight: CGFloat = 132
    private let composerHorizontalPadding: CGFloat = 18
    private let composerTopPadding: CGFloat = 14
    private let composerBottomPadding: CGFloat = 16

    private var composerMeasurementText: String {
        vm.prompt.isEmpty ? "Message" : vm.prompt + " "
    }

    private var composerResolvedHeight: CGFloat {
        let explicitLineCount = max(1, vm.prompt.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).count)
        let estimatedFromLines = CGFloat(explicitLineCount) * 22 + composerTopPadding + composerBottomPadding
        let measuredOrEstimated = max(measuredHeight, estimatedFromLines)
        return min(max(measuredOrEstimated, composerCollapsedHeight), composerExpandedHeight)
    }

    private var composerCornerRadius: CGFloat {
        UIConstants.adaptiveComposerCornerRadius(
            currentHeight: composerResolvedHeight,
            collapsedHeight: composerCollapsedHeight,
            expandedHeight: composerExpandedHeight,
            expandedRadius: 20
        )
    }

    private var bindingForPrompt: Binding<String> {
        Binding(get: { vm.prompt }, set: { vm.prompt = $0 })
    }

    private var hasActiveChatModel: Bool { vm.canAcceptChatInput }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.4)

            messageList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground).opacity(0.6))

            Divider()
                .opacity(0.4)

            inputBar
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .glassBackgroundEffect()
        }
        .task(id: vm.msgs.count) {
            await scrollToBottom(animated: true)
        }
        .onChangeCompat(of: vm.spotlightMessageID) { _, newValue in
            guard let id = newValue else { return }
            Task { await scrollTo(messageID: id, animated: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if vm.spotlightMessageID == id {
                    vm.spotlightMessageID = nil
                }
            }
        }
        .onChangeCompat(of: tabRouter.selection) { _, newValue in
            guard newValue == .chat else { return }
            Task { await scrollToBottom(animated: false) }
        }
        .sheet(isPresented: $showSessionTray) {
            VisionChatSessionTray(isPresented: $showSessionTray)
                .environmentObject(vm)
        }
        .ornament(
            visibility: .visible,
            attachmentAnchor: .scene(.top)
        ) {
            ChatAdvancedOrnament(showRAMUsage: isAdvancedMode)
                .padding(.top, 12)
                .environmentObject(vm)
                .environmentObject(modelManager)
        }
        .alert(LocalizedStringKey("Load a model to chat"), isPresented: $showModelRequiredAlert) {
            Button(LocalizedStringKey("Open Stored")) {
                tabRouter.selection = .stored
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) { }
        } message: {
            Text(LocalizedStringKey("Open Stored to choose a model to run locally or connect to a remote endpoint."))
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button {
                showSessionTray = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 22, weight: .semibold))
                    .padding(10)
                    .background(
                        Circle()
                            .fill(Color(.secondarySystemBackground))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show chat tray")

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Chat"))
                    .font(.system(size: 28, weight: .semibold))
                if let loadError = vm.loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if vm.loading || vm.stillLoading {
                    Text(LocalizedStringKey("Loading model…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if vm.isStreaming {
                    Text(LocalizedStringKey("Streaming response…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if vm.prompt.isEmpty {
                    Text(LocalizedStringKey("Ask Noema anything"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                vm.startNewSession()
            } label: {
                Label(LocalizedStringKey("New Chat"), systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 28)
        .padding(.horizontal, 32)
        .padding(.bottom, 16)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messagesForDisplay) { msg in
                        StreamingAwareMessageView(msg: msg, store: vm.streamingStore)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
            .overlay(alignment: .center) {
                let isEmptyChat = vm.msgs.first(where: { $0.role.lowercased() != "system" }) == nil
                if isEmptyChat && !vm.isStreaming && !vm.loading {
                    VisionSuggestionsOverlay(
                        suggestions: suggestionTriplet,
                        enabled: hasActiveChatModel,
                        onTap: { text in
                            guard hasActiveChatModel else {
                                showModelRequiredAlert = true
                                return
                            }
                            guard !vm.isStreamingInAnotherSession else {
                                vm.crossSessionSendBlocked = true
                                return
                            }
                            suggestionTriplet = []
                            Task { await vm.sendMessage(text) }
                        },
                        onDisabledTap: {
                            showModelRequiredAlert = true
                        }
                    )
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .onAppear { scrollProxy = proxy }
            .onAppear {
                let isEmpty = vm.msgs.first(where: { $0.role.lowercased() != "system" }) == nil
                if isEmpty && suggestionTriplet.isEmpty {
                    suggestionTriplet = ChatSuggestions.nextThree()
                    suggestionsSessionID = vm.activeSessionID
                }
            }
            .onChangeCompat(of: vm.activeSessionID) { _, newID in
                let isEmpty = vm.msgs.first(where: { $0.role.lowercased() != "system" }) == nil
                if isEmpty && newID != suggestionsSessionID {
                    suggestionTriplet = ChatSuggestions.nextThree()
                    suggestionsSessionID = newID
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 12) {
            if UIConstants.showMultimodalUI && vm.supportsImageInput && !vm.pendingImageURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(vm.pendingImageURLs.prefix(5).enumerated()), id: \.offset) { idx, url in
                            let thumb = vm.pendingThumbnail(for: url)
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let ui = thumb {
                                        Image(platformImage: ui)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Rectangle().fill(Color.secondary.opacity(0.15))
                                            .overlay(ProgressView().scaleEffect(0.6))
                                    }
                                }
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                                Button { vm.removePendingImage(at: idx) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 2)
                                }
                                .offset(x: 8, y: -8)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .glassBackgroundEffect()
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }

            HStack(alignment: .top, spacing: 12) {
                VisionAttachmentButton(
                    showWebSearchOption: true,
                    showPythonOption: true,
                    showPlusIcon: true,
                    onModelRequiredTap: { showModelRequiredAlert = true }
                )

                ZStack(alignment: .topLeading) {
                    MobileBottomAnchoredTextEditor(
                        text: bindingForPrompt,
                        isDisabled: vm.isStreaming || vm.loading || vm.stillLoading || !hasActiveChatModel,
                        topInset: composerTopPadding,
                        bottomInset: composerBottomPadding,
                        font: .preferredFont(forTextStyle: .body)
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: composerResolvedHeight, alignment: .topLeading)
                        .padding(.horizontal, composerHorizontalPadding)

                    if vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(LocalizedStringKey("Message"))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, composerHorizontalPadding)
                            .padding(.top, composerTopPadding)
                            .padding(.bottom, composerBottomPadding)
                            .frame(maxWidth: .infinity, maxHeight: composerResolvedHeight, alignment: .topLeading)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    Text(composerMeasurementText)
                        .lineLimit(nil)
                        .padding(.horizontal, composerHorizontalPadding)
                        .padding(.top, composerTopPadding)
                        .padding(.bottom, composerBottomPadding)
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
                    .frame(minHeight: composerCollapsedHeight, maxHeight: composerExpandedHeight, alignment: .topLeading)
                    .frame(height: composerResolvedHeight, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
                    .glassPill(cornerRadius: composerCornerRadius)
                    .opacity(hasActiveChatModel ? 1.0 : 0.55)
                    .disabled(vm.isStreaming || vm.loading || vm.stillLoading || !hasActiveChatModel)
                    .overlay {
                        if !hasActiveChatModel {
                            RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                                .fill(Color.clear)
                                .contentShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
                                .onTapGesture {
                                    showModelRequiredAlert = true
                                }
                        }
                    }

                Button {
                    if vm.isStreaming {
                        vm.stop()
                    } else {
                        guard hasActiveChatModel else {
                            showModelRequiredAlert = true
                            return
                        }
                        let text = vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        Task { await vm.send() }
                    }
                } label: {
                    Label(vm.isStreaming ? LocalizedStringKey("Stop") : LocalizedStringKey("Send"), systemImage: vm.isStreaming ? "stop.fill" : "paperplane.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.isStreaming ? .red : .accentColor)
                .disabled((vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.isStreaming) || (!vm.isStreaming && (vm.loading || vm.stillLoading)))
            }

            if vm.crossSessionSendBlocked {
                Text(LocalizedStringKey("Complete the streaming response in the active chat before sending again."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var messagesForDisplay: [ChatVM.Msg] {
        vm.msgs.filter { $0.role.lowercased() != "system" }
    }

    private func scrollToBottom(animated: Bool) async {
        guard let id = vm.msgs.last?.id else { return }
        await MainActor.run {
            if animated {
                withAnimation { scrollProxy?.scrollTo(id, anchor: .bottom) }
            } else {
                scrollProxy?.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func scrollTo(messageID: UUID, animated: Bool) async {
        await MainActor.run {
            if animated {
                withAnimation { scrollProxy?.scrollTo(messageID, anchor: .center) }
            } else {
                scrollProxy?.scrollTo(messageID, anchor: .center)
            }
        }
    }
}

private struct ChatAdvancedOrnament: View {
    @EnvironmentObject private var vm: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @Environment(\.colorScheme) private var colorScheme

    let showRAMUsage: Bool

    private let ramInfo = DeviceRAMInfo.current()
    private var ornamentFillColor: Color {
        // Keep the ornament a little darker than the surrounding surface
        // without using a strong gradient.
        let base = Color(.secondarySystemBackground)
        if colorScheme == .dark {
            return base.opacity(0.76)
        }
        return base.opacity(0.90)
    }

    var body: some View {
        HStack(spacing: 16) {
            if showRAMUsage {
                ChatRAMUsageGauge(info: ramInfo)

                Divider()
                    .frame(height: 80)
                    .opacity(0.22)
            }

            modelDetails
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(ornamentFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.9)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 6)
        .frame(maxWidth: 700)
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private var modelDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey("Active Model"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let ejectAction = ornamentEjectAction {
                    OrnamentEjectButton(
                        isDisabled: vm.loading || vm.stillLoading || vm.isStreaming,
                        action: ejectAction
                    )
                }
            }

            if let remote = modelManager.activeRemoteSession {
                remoteSessionRow(for: remote)
            } else if let loaded = modelManager.loadedModel {
                ModelRow(
                    model: loaded,
                    isLoading: false,
                    isLoaded: true,
                    loadAction: {}
                )
                .environmentObject(vm)
                .allowsHitTesting(false)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(LocalizedStringKey("No model loaded"), systemImage: "exclamationmark.triangle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                    Text(LocalizedStringKey("Open Stored to choose a model to run locally or connect to a remote endpoint."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func remoteSessionRow(for session: ActiveRemoteSession) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.modelName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(session.backendName) • \(session.transport.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(session.endpointType.displayName + (session.streamingEnabled ? " · Streaming" : ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
            }

            Spacer(minLength: 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Remote model \(session.modelName) connected via \(session.transport.label)")
    }

    private var ornamentEjectAction: (() -> Void)? {
        if modelManager.activeRemoteSession != nil {
            return { vm.deactivateRemoteSession() }
        } else if modelManager.loadedModel != nil {
            return { Task { await vm.unload() } }
        }
        return nil
    }
}

private struct OrnamentEjectButton: View {
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "eject")
                .font(.system(size: 13, weight: .semibold))
                .padding(6)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Color.accentColor)
        .contentShape(Rectangle())
        .accessibilityLabel("Eject active model")
        .disabled(isDisabled)
    }
}

private struct ChatRAMUsageGauge: View {
    let info: DeviceRAMInfo

    @State private var usageBytes: Int64 = 0
    @State private var monitorTask: Task<Void, Never>? = nil

    private var budgetBytes: Int64? { info.conservativeLimitBytes() }

    private var progress: Double {
        guard let cap = budgetBytes, cap > 0 else { return 0 }
        return min(1.0, Double(usageBytes) / Double(cap))
    }

    private var gaugeColor: Color {
        switch progress {
        case 0..<0.7: return .green
        case 0.7..<0.9: return .orange
        default: return .red
        }
    }

    private var usageText: String {
        ByteCountFormatter.string(fromByteCount: usageBytes, countStyle: .memory)
    }

    private var budgetText: String {
        if let cap = budgetBytes {
            return ByteCountFormatter.string(fromByteCount: cap, countStyle: .memory)
        }
        return info.limit
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(gaugeColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(info.ram) • \(info.modelName)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(String.localizedStringWithFormat(String(localized: "Using %@ of %@ budget"), usageText, budgetText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey("Updates every second"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .onAppear {
            monitorTask?.cancel()
            monitorTask = Task {
                await refreshUsage()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await refreshUsage()
                }
            }
        }
        .onDisappear {
            monitorTask?.cancel()
            monitorTask = nil
        }
    }

    private func refreshUsage() async {
        let bytes = Int64(chat_app_memory_footprint())
        await MainActor.run {
            usageBytes = max(0, bytes)
        }
    }
}

@_silgen_name("app_memory_footprint")
private func chat_app_memory_footprint() -> UInt

private struct VisionChatSessionTray: View {
    @EnvironmentObject private var vm: ChatVM
    @Binding var isPresented: Bool

    @State private var sessionToDelete: ChatVM.Session?

    var body: some View {
        NavigationStack {
            List(selection: $vm.activeSessionID) {
                ForEach(vm.sessions) { session in
                    Button {
                        vm.select(session)
                        isPresented = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: session.isFavorite ? "star.fill" : "message")
                                .foregroundStyle(session.isFavorite ? .yellow : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title)
                                    .font(.body.weight(session.id == vm.activeSessionID ? .semibold : .regular))
                                Text(session.date, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            sessionToDelete = session
                        } label: {
                            Label(LocalizedStringKey("Delete"), systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(session.isFavorite ? LocalizedStringKey("Unfavorite") : LocalizedStringKey("Favorite")) {
                            vm.toggleFavorite(session)
                        }
                        Button(role: .destructive) {
                            sessionToDelete = session
                        } label: {
                            Label(LocalizedStringKey("Delete"), systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(LocalizedStringKey("Chats"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("Close")) { isPresented = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        vm.startNewSession()
                        isPresented = false
                    } label: {
                        Label(LocalizedStringKey("New Chat"), systemImage: "plus")
                    }
                }
            }
            .confirmationDialog(
                String.localizedStringWithFormat(String(localized: "Delete chat %@?"), sessionToDelete?.title ?? ""),
                isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } })
            ) {
                Button(LocalizedStringKey("Delete"), role: .destructive) {
                    if let session = sessionToDelete {
                        vm.delete(session)
                    }
                    sessionToDelete = nil
                }
                Button(LocalizedStringKey("Cancel"), role: .cancel) {
                    sessionToDelete = nil
                }
            }
        }
    }
}

private struct VisionSuggestionsOverlay: View {
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
                ForEach(suggestions.prefix(3), id: \.self) { suggestion in
                    Button {
                        if enabled {
                            onTap(suggestion)
                        } else {
                            onDisabledTap()
                        }
                    } label: {
                        Text(suggestion)
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
#endif
