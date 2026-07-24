#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI
import UniformTypeIdentifiers
#if canImport(CoreTransferable)
import CoreTransferable
#endif
#if os(iOS)
import UIKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if os(iOS)
import Photos
#endif
#if os(macOS)
import AppKit
#endif

/// Circular (or rounded, on visionOS) control that mirrors the chat globe button but
/// arms image attachments instead. Presents a platform-appropriate picker when the
/// active model supports vision input and honors the five-image cap.
struct VisionAttachmentButton: View {
    @EnvironmentObject private var vm: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @ObservedObject private var settings = SettingsStore.shared
#if os(macOS)
    @State private var isProcessingImport = false
    @State private var isProcessingMediaImport = false
#else
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var videoPickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showVideoPicker = false
    @State private var showMediaImporter = false
#if os(iOS)
    @State private var showAttachmentTray = false
    @State private var showMediaSourceDialog = false
    @State private var showDocumentImporter = false
    @State private var showCameraCapture = false
    @State private var recentAssets: [PHAsset] = []
    @State private var thumbnailCache: [String: UIImage] = [:]
    @State private var recentAssetAttachmentURLs: [String: URL] = [:]
    @State private var isLoadingRecents = false
    @State private var photoAccessDenied = false
    @State private var cameraUnavailableAlert = false
#endif
#endif
    @State private var showDisabledReason = false
    @State private var showWebSearchDisabledReason = false
    @State private var showPythonDisabledReason = false
    @State private var showDatasetPicker = false
    @AppStorage("hasSeenWebSearchNotice") private var hasSeenWebSearchNotice = false
    @State private var showWebSearchNotice = false
#if os(macOS) || os(visionOS)
    @State private var showActionMenu = false
#endif

#if os(macOS)
    private let size: CGFloat = 15
#else
    private let size: CGFloat = 28
#endif
#if os(iOS)
    private let controlSize: CGFloat = 48
#endif

#if os(visionOS)
    private let visionButtonSize = CGSize(width: 78, height: 48)
    private let visionCornerRadius: CGFloat = 24
#endif

    private let maxImages = 5
    private let showWebSearchOption: Bool
    private let showPythonOption: Bool
    private let showPlusIcon: Bool
    private let onModelRequiredTap: (() -> Void)?

    init(
        showWebSearchOption: Bool = false,
        showPythonOption: Bool = false,
        showPlusIcon: Bool = false,
        onModelRequiredTap: (() -> Void)? = nil
    ) {
        self.showWebSearchOption = showWebSearchOption
        self.showPythonOption = showPythonOption
        self.showPlusIcon = showPlusIcon
        self.onModelRequiredTap = onModelRequiredTap
    }

    var body: some View {
        Group {
#if os(macOS)
            Button(action: handleTap) {
                buttonContent
            }
            .popover(isPresented: $showActionMenu, arrowEdge: .bottom) {
                MacQuickActionPopover(
                    showsPhotoAction: showPlusIcon,
                    attachmentsDisabled: attachmentsDisabled,
                    attachmentsDisabledReason: disabledReason,
                    showsWebSearchAction: showWebSearchOption,
                    webSearchArmed: settings.webSearchArmed,
                    webSearchDisabled: webSearchDisabled,
                    webSearchDisabledReason: webSearchDisabledReason,
                    showsPythonAction: showPythonOption,
                    pythonArmed: settings.pythonArmed,
                    pythonDisabled: pythonDisabled,
                    pythonDisabledReason: pythonDisabledReason,
                    isRecordingAudio: vm.isRecordingAudio,
                    activeDatasetName: vm.activeSessionDataset?.name,
                    onPhotos: selectPhotosFromMacMenu,
                    onRecordAudio: selectRecordAudioFromMacMenu,
                    onAttachMedia: selectAttachMediaFromMacMenu,
                    onAttachDocument: selectAttachDocumentFromMacMenu,
                    onDataset: presentDatasetPicker,
                    onWebSearch: selectWebSearchFromMacMenu,
                    onPython: selectPythonFromMacMenu
                )
            }
#else
            Button(action: handleTap) {
                buttonContent
            }
            .photosPicker(
                isPresented: $showPicker,
                selection: $pickerItems,
                maxSelectionCount: max(0, remainingSlots),
                matching: .images
            )
            .photosPicker(
                isPresented: $showVideoPicker,
                selection: $videoPickerItems,
                maxSelectionCount: 1,
                matching: .videos
            )
            .onChangeCompat(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await loadPickedItems(items) }
            }
            .onChangeCompat(of: videoPickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await loadPickedVideos(items) }
            }
#if os(iOS)
            .sheet(isPresented: $showAttachmentTray) {
                AttachmentTray(
                    showsPhotoSection: UIConstants.showMultimodalUI,
                    photosDisabled: attachmentsDisabled,
                    photosDisabledReason: disabledReason,
                    recentAssets: recentAssets,
                    thumbnails: thumbnailCache,
                    selectedAssetIDs: Set(recentAssetAttachmentURLs.keys),
                    isLoading: isLoadingRecents,
                    remainingSlots: remainingSlots,
                    photoAccessGranted: !photoAccessDenied,
                    showsWebSearchAction: showWebSearchOption,
                    webSearchArmed: settings.webSearchArmed,
                    webSearchDisabled: webSearchDisabled,
                    webSearchDisabledReason: webSearchDisabledReason,
                    showsPythonAction: showPythonOption,
                    pythonArmed: settings.pythonArmed,
                    pythonDisabled: pythonDisabled,
                    pythonDisabledReason: pythonDisabledReason,
                    isRecordingAudio: vm.isRecordingAudio,
                    activeDatasetName: vm.activeSessionDataset?.name,
                    onCamera: {
                        showAttachmentTray = false
                        openCamera()
                    },
                    onAllPhotos: {
                        showAttachmentTray = false
                        showPicker = true
                    },
                    onRecordAudio: {
                        showAttachmentTray = false
                        Task { await vm.toggleAudioRecording() }
                    },
                    onAttachMedia: {
                        showAttachmentTray = false
                        showMediaSourceDialog = true
                    },
                    onAttachDocument: presentDocumentImporter,
                    onDataset: presentDatasetPicker,
                    onWebSearchTap: {
                        showAttachmentTray = false
                        toggleWebSearch()
                    },
                    onPythonTap: {
                        showAttachmentTray = false
                        togglePython()
                    },
                    onAssetTap: { asset in
                        Task { @MainActor in
                            await toggleRecentAssetSelection(asset)
                        }
                    }
                )
                .presentationDetents([.height(attachmentTrayHeight)])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.ultraThinMaterial)
            }
            .fullScreenCover(isPresented: $showCameraCapture) {
                CameraCaptureView(
                    onCapture: { image in
                        showCameraCapture = false
                        Task { await vm.savePendingImage(image) }
                    },
                    onCancel: { showCameraCapture = false }
                )
                .ignoresSafeArea()
            }
            .confirmationDialog("Attach Audio/Video", isPresented: $showMediaSourceDialog, titleVisibility: .visible) {
                Button("Photos") {
                    showVideoPicker = true
                }
                Button("Files") {
                    showMediaImporter = true
                }
                Button("Cancel", role: .cancel) { }
            }
#endif
#endif
        }
#if os(visionOS)
        .confirmationDialog("Actions", isPresented: $showActionMenu, titleVisibility: .hidden) {
            if UIConstants.showMultimodalUI {
                Button("Add Photos") {
                    showPicker = true
                }
                .disabled(attachmentsDisabled)
            }
            Button {
                Task { await vm.toggleAudioRecording() }
            } label: {
                Text(LocalizedStringKey(vm.isRecordingAudio ? "Stop Recording" : "Record Audio"))
            }
            Button {
                showMediaImporter = true
            } label: {
                Text(LocalizedStringKey("Attach Audio/Video"))
            }
            Button {
                presentDatasetPicker()
            } label: {
                Text(verbatim: vm.activeSessionDataset?.name ?? String(localized: "Use Dataset"))
            }
            if showWebSearchOption {
                if settings.webSearchArmed {
                    Button("Disable Web Search") { toggleWebSearch() }
                        .disabled(webSearchDisabled)
                } else {
                    Button("Enable Web Search") { toggleWebSearch() }
                        .disabled(webSearchDisabled)
                }
            }
            if showPythonOption {
                if settings.pythonArmed {
                    Button("Disable Python") { togglePython() }
                        .disabled(pythonDisabled)
                } else {
                    Button("Enable Python") { togglePython() }
                        .disabled(pythonDisabled)
                }
            }
            Button("Cancel", role: .cancel) { }
        }
#endif
        .sheet(isPresented: $showDatasetPicker) {
            ChatDatasetPicker()
                .environmentObject(vm)
                .environmentObject(datasetManager)
                .environmentObject(modelManager)
#if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
#elseif os(visionOS)
                .frame(minWidth: 520, idealWidth: 620, minHeight: 520, idealHeight: 650)
#endif
        }
#if !os(macOS)
        .fileImporter(
            isPresented: $showMediaImporter,
            allowedContentTypes: TranscriptionMediaSupport.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            Task { await handleMediaImportResult(result) }
        }
#endif
#if os(iOS)
        .fileImporter(
            isPresented: $showDocumentImporter,
            allowedContentTypes: DatasetDocumentSupport.allowedUTTypes(),
            allowsMultipleSelection: true
        ) { result in
            handleDocumentImportResult(result)
        }
#endif
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityHint(Text(accessibilityHintText))
        .accessibilityIdentifier(accessibilityIdentifierText)
        .help(helpText)
        .alert("Vision Attachments Unavailable", isPresented: $showDisabledReason) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(disabledReason)
        }
        .alert("Web Search Unavailable", isPresented: $showWebSearchDisabledReason) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(webSearchDisabledReason)
        }
        .alert("Python Unavailable", isPresented: $showPythonDisabledReason) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(pythonDisabledReason)
        }
        .alert("Tool Calling", isPresented: $showWebSearchNotice) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Tool calling isn't perfect. Although Noema implements many methods of detecting and instructing models to use tools, not all LLMs will follow instructions and some might not call them correctly or at all. Tool calling heavily depends on model pre-training and will get better as time passes.")
        }
        .onChangeCompat(of: datasetActive) { _, active in
            if showWebSearchOption && active && settings.webSearchArmed { settings.webSearchArmed = false }
            if showPythonOption && active && settings.pythonArmed { settings.pythonArmed = false }
        }
        .onChangeCompat(of: webSearchBlockedByModelFormat) { _, blocked in
            if showWebSearchOption && blocked && settings.webSearchArmed { settings.webSearchArmed = false }
        }
        .onChangeCompat(of: isMLXModel) { _, isMLX in
            if showPythonOption && isMLX && settings.pythonArmed { settings.pythonArmed = false }
        }
        .onChangeCompat(of: hasActiveChatModel) { _, active in
            if showWebSearchOption && !active && settings.webSearchArmed { settings.webSearchArmed = false }
            if showPythonOption && !active && settings.pythonArmed { settings.pythonArmed = false }
        }
        .onAppear {
            if showWebSearchOption {
                if datasetActive && settings.webSearchArmed { settings.webSearchArmed = false }
                if webSearchBlockedByModelFormat && settings.webSearchArmed { settings.webSearchArmed = false }
                if !hasActiveChatModel && settings.webSearchArmed { settings.webSearchArmed = false }
            }
            if showPythonOption {
                if datasetActive && settings.pythonArmed { settings.pythonArmed = false }
                if isMLXModel && settings.pythonArmed { settings.pythonArmed = false }
                if !hasActiveChatModel && settings.pythonArmed { settings.pythonArmed = false }
            }
        }
#if os(iOS)
        .onChangeCompat(of: vm.pendingImageURLs) { _, urls in
            pruneRecentAssetSelection(using: urls)
        }
#endif
#if os(iOS)
        .alert("Photo Access Needed", isPresented: $photoAccessDenied) {
            Button("Cancel", role: .cancel) { }
            Button("Open Settings") { openAppSettings() }
        } message: {
            Text("Allow photo access to show your recent pictures or use All Photos.")
        }
        .alert("Camera Unavailable", isPresented: $cameraUnavailableAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This device doesn't have a camera available. Try picking from All Photos instead.")
        }
#endif
    }

    @ViewBuilder
    private var buttonContent: some View {
        Image(systemName: iconName)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(foregroundColor)
#if os(visionOS)
            .frame(width: visionButtonSize.width, height: visionButtonSize.height)
#else
#if os(iOS)
            .frame(width: controlSize, height: controlSize)
#elseif os(macOS)
            .frame(width: 32, height: 32)
#else
            .padding(10)
#endif
#endif
            .background(buttonBackground)
            .overlay(alignment: .topTrailing) {
                if vm.pendingImageURLs.count > 0 {
                    BadgeView(count: vm.pendingImageURLs.count)
                        .offset(x: 4, y: -4)
                }
            }
            .opacity(isDisabled ? 0.5 : 1.0)
    }

    private var iconName: String {
        if showPlusIcon || showWebSearchOption || showPythonOption {
            return "plus"
        }
        if vm.pendingImageURLs.count > 0 {
            return "photo.stack.fill"
        }
        return "photo.on.rectangle"
    }

    private var remainingSlots: Int {
        max(0, maxImages - vm.pendingImageURLs.count)
    }

#if os(iOS)
    private var attachmentTrayHeight: CGFloat {
        let hasPhotos = UIConstants.showMultimodalUI && vm.supportsImageInput
        let toolRowCount = (showWebSearchOption ? 1 : 0) + (showPythonOption ? 1 : 0)
        let mediaRows = 4
        if hasPhotos {
            return 200 + CGFloat((toolRowCount + mediaRows) * 80)
        } else {
            return CGFloat(max(100, (toolRowCount + mediaRows) * 90 + 30))
        }
    }
#endif

    private var hasActiveChatModel: Bool { vm.hasActiveChatModel }

    private var functionCallingSupport: Bool? {
        UserDefaults.standard.object(forKey: "currentModelSupportsFunctionCalling") as? Bool
    }

    private var attachmentsDisabled: Bool {
        guard UIConstants.showMultimodalUI else { return true }
        if remainingSlots == 0 { return true }
        if !vm.supportsImageInput { return true }
        if !hasActiveChatModel { return true }
        return false
    }

    private var isDisabled: Bool {
        // The "+" opens a mixed actions surface. Keep it reachable for text-only
        // models; only its photo action should follow vision support.
        if showPlusIcon { return false }
        if showWebSearchOption || showPythonOption {
#if os(iOS)
            if showPlusIcon { return false }
#endif
            return attachmentsDisabled && webSearchDisabled && pythonDisabled
        }
        return attachmentsDisabled
    }

    private var foregroundColor: Color {
        if isDisabled { return .secondary }
#if os(macOS)
        return hasActiveState ? activeTintColor : .secondary
#else
        return hasActiveState ? .white : .primary
#endif
    }

    private var vividPlusMenuYellow: Color {
        Color(red: 1.0, green: 0.82, blue: 0.04)
    }

    private var activeTintColor: Color {
        if !vm.pendingImageURLs.isEmpty { return Color.visionAccent }
        if showPlusIcon { return vividPlusMenuYellow }
        return Color.accentColor
    }

    private var backgroundFill: Color {
        if isDisabled { return Color.gray.opacity(0.12) }
        if hasActiveState {
            return activeTintColor
        }
        return Color(.systemBackground).opacity(0.9)
    }

    private var borderColor: Color {
        if !hasActiveState {
            return isDisabled ? Color.gray.opacity(0.2) : Color.gray.opacity(0.25)
        }
        return .clear
    }

    private var glowColor: Color {
        if !hasActiveState { return .clear }
        let glowOpacity: Double = (showPlusIcon && vm.pendingImageURLs.isEmpty) ? 0.62 : 0.45
        return activeTintColor.opacity(glowOpacity)
    }

    private var hasActiveState: Bool {
        !vm.pendingImageURLs.isEmpty
            || !vm.pendingMediaAttachments.isEmpty
            || vm.isRecordingAudio
            || (showWebSearchOption && settings.webSearchArmed)
            || (showPythonOption && settings.pythonArmed)
    }

#if os(visionOS)
    @ViewBuilder
    private var buttonBackground: some View {
        RoundedRectangle(cornerRadius: visionCornerRadius, style: .continuous)
            .fill(backgroundFill)
            .overlay(
                RoundedRectangle(cornerRadius: visionCornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: vm.pendingImageURLs.isEmpty ? 0.75 : 0)
            )
            .shadow(color: glowColor, radius: vm.pendingImageURLs.isEmpty ? 0 : 12, y: vm.pendingImageURLs.isEmpty ? 0 : 6)
    }
#else
    @ViewBuilder
    private var buttonBackground: some View {
#if os(iOS)
        let shape = Circle()
        let emphasizePlusMenuActive = showPlusIcon && hasActiveState && vm.pendingImageURLs.isEmpty
        shape
            .fill(Color.clear)
            .glassifyIfAvailable(in: shape)
            .overlay(
                shape.fill(
                    hasActiveState
                        ? backgroundFill.opacity(emphasizePlusMenuActive ? 0.48 : 0.28)
                        : Color.white.opacity(isDisabled ? 0.04 : 0.10)
                )
            )
            .overlay(
                shape.strokeBorder(
                    emphasizePlusMenuActive
                        ? vividPlusMenuYellow.opacity(0.82)
                        : Color.white.opacity(isDisabled ? 0.14 : 0.32),
                    lineWidth: emphasizePlusMenuActive ? 0.9 : 0.75
                )
            )
            .shadow(
                color: isDisabled ? .clear : glowColor,
                radius: hasActiveState ? 10 : 6,
                y: hasActiveState ? 5 : 3
            )
#else
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        shape
            .fill(
                hasActiveState
                    ? activeTintColor.opacity(0.12)
                    : ChatTheme.quietSurface
            )
            .overlay(
                shape.strokeBorder(
                    hasActiveState
                        ? activeTintColor.opacity(0.28)
                        : Color.clear,
                    lineWidth: 0.8
                )
            )
#endif
    }
#endif

    private var disabledReason: String {
        if !UIConstants.showMultimodalUI {
            return String(localized: "Vision features are disabled by configuration.")
        }
        if !hasActiveChatModel {
            return String(localized: "Load a model before attaching images.")
        }
        if vm.loadedFormat == .gguf, vm.loadedSettings?.loadVisionProjector == false {
            return String(localized: "Vision projector loading is disabled for this model. Enable it in Model Settings and load the model again to attach images.")
        }
        if !vm.supportsImageInput {
            return String(localized: "The active model can't process images.")
        }
        if remainingSlots == 0 {
            return String.localizedStringWithFormat(String(localized: "You've already attached the maximum of %d images."), maxImages)
        }
        return String(localized: "Vision attachments are currently unavailable.")
    }

    private var accessibilityHintText: String {
        if isDisabled {
            if showWebSearchOption || showPythonOption {
                return String.localizedStringWithFormat(String(localized: "Disabled: %1$@ %2$@"), disabledReason, webSearchDisabledReason)
            }
            return String.localizedStringWithFormat(String(localized: "Disabled: %@"), disabledReason)
        }
        if showPlusIcon || showWebSearchOption || showPythonOption {
            return String(localized: "Open quick actions for tools and attachments.")
        }
        return vm.pendingImageURLs.isEmpty ? String(localized: "Add photos to your next message.") : String(localized: "Add more photos or review attached images.")
    }

    private var helpText: String {
        if isDisabled {
            if showWebSearchOption || showPythonOption {
                return String.localizedStringWithFormat(String(localized: "%@ %@"), disabledReason, webSearchDisabledReason)
            }
            return disabledReason
        }
        if showPlusIcon || showWebSearchOption || showPythonOption {
            return String(localized: "Open quick actions for tools and attachments.")
        }
        return String.localizedStringWithFormat(String(localized: "Attach up to %d images (order preserved). No resizing needed — llama.cpp preprocesses images automatically."), maxImages)
    }

    private var accessibilityLabelText: String {
        (showPlusIcon || showWebSearchOption || showPythonOption) ? String(localized: "More actions") : String(localized: "Attach Photos")
    }

    private var accessibilityIdentifierText: String {
        (showPlusIcon || showWebSearchOption || showPythonOption) ? "chat-more-actions-button" : "chat-attachment-button"
    }

    private func handleTap() {
        guard !isDisabled else {
#if os(macOS)
            if showWebSearchOption || showPythonOption {
                showActionMenu = true
                return
            }
#endif
            if (showWebSearchOption || showPythonOption) && !hasActiveChatModel {
                presentModelRequiredPopup()
            } else {
                showDisabledReason = true
            }
            return
        }
        if showWebSearchOption || showPythonOption {
#if os(macOS) || os(visionOS)
            showActionMenu = true
            return
#elseif os(iOS)
            if UIConstants.showMultimodalUI && vm.supportsImageInput {
                Task { await loadRecentsIfNeeded() }
            }
            showAttachmentTray = true
            return
#endif
        }
#if os(macOS)
        // The composer "+" opens the action popover (Add Photos / Record Audio /
        // Attach Audio·Video / Attach Document) so documents and PDFs are reachable.
        // Without this it fell straight through to presentOpenPanel(), the image-only
        // picker, making the document/PDF option unreachable. Callers without the plus
        // icon keep the direct image picker.
        if showPlusIcon {
            showActionMenu = true
        } else if !isProcessingImport {
            isProcessingImport = true
            Task { await presentOpenPanel() }
        }
#elseif os(iOS)
        if UIConstants.showMultimodalUI && vm.supportsImageInput {
            Task { await loadRecentsIfNeeded() }
        }
        showAttachmentTray = true
#else
        showPicker = true
#endif
    }

    private func presentDatasetPicker() {
#if os(iOS)
        showAttachmentTray = false
#elseif os(macOS) || os(visionOS)
        showActionMenu = false
#endif
        // Let the action sheet/popover finish dismissing before presenting the
        // chooser, avoiding competing presentations on compact devices.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            showDatasetPicker = true
        }
    }

#if os(iOS)
    private func presentDocumentImporter() {
        showAttachmentTray = false
        // Let the attachment tray dismiss before presenting Files. Presenting both
        // surfaces in the same update can cause the importer request to be dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            showDocumentImporter = true
        }
    }
#endif

    private var datasetActive: Bool {
        if modelManager.activeDataset != nil { return true }
        if datasetManager.indexingDatasetID != nil { return true }
        return false
    }

    private var isRemoteSession: Bool {
        modelManager.activeRemoteSession != nil
    }

    private var isMLXModel: Bool {
        vm.currentModelFormat == .some(.mlx) && !isRemoteSession
    }

    private var isAFMModel: Bool {
        vm.currentModelFormat == .some(.afm) && !isRemoteSession
    }

    private var webSearchBlockedByModelFormat: Bool {
        // PCC-backed AFM runs the native FoundationModels web tool, so only the
        // on-device AFM variant stays blocked.
        isMLXModel || (isAFMModel && vm.afmChatToolsUnavailable)
    }

    private var webSearchDisabled: Bool {
        guard showWebSearchOption else { return true }
        let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
        if webSearchBlockedByModelFormat { return true }
        return !hasActiveChatModel || offGrid || !settings.webSearchEnabled || datasetActive || functionCallingSupport == false
    }

    private var webSearchDisabledReason: String {
        if !hasActiveChatModel {
            return String(localized: "Open Stored to choose a model to run locally or connect to a remote endpoint.")
        }
        if isMLXModel {
            return String(localized: "Web Search is currently unreliable with MLX models due to MLX limitations.")
        }
        if isAFMModel && vm.afmChatToolsUnavailable {
            return String(localized: "Web search is disabled for Apple Foundation Models because their context budget cannot reliably accommodate tool input.")
        }
        if functionCallingSupport == false {
            return String(localized: "This model does not support function calling; web search requires it.")
        }
        if datasetActive {
            return String(localized: "Web search can't be used while a dataset is active or indexing.")
        }
        let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
        if offGrid {
            return String(localized: "Off‑Grid mode is on. Network features like web search are disabled.")
        }
        if !settings.webSearchEnabled {
            return String(localized: "Web Search is turned off in Settings.")
        }
        return String(localized: "Web Search is currently unavailable.")
    }

    private var pythonDisabled: Bool {
        guard showPythonOption else { return true }
        if isMLXModel { return true }
        return !hasActiveChatModel
            || !settings.pythonEnabled
            || datasetActive
            || functionCallingSupport == false
            || !PythonRuntime.status().isAvailable
    }

    private var pythonDisabledReason: String {
        let runtimeStatus = PythonRuntime.status()
        if !hasActiveChatModel {
            return String(localized: "Open Stored to choose a model to run locally or connect to a remote endpoint.")
        }
        if isMLXModel {
            return String(localized: "Python is currently unreliable with MLX models due to MLX limitations.")
        }
        if functionCallingSupport == false {
            return String(localized: "This model does not support function calling; Python requires it.")
        }
        if datasetActive {
            return String(localized: "Python can't be used while a dataset is active or indexing.")
        }
        if !settings.pythonEnabled {
            return String(localized: "Python Code Execution is turned off in Settings.")
        }
        if runtimeStatus.isAvailable == false, let reason = runtimeStatus.reason, !reason.isEmpty {
            return reason
        }
        return String(localized: "Python is currently unavailable.")
    }

    private func toggleWebSearch() {
        guard hasActiveChatModel else {
            presentModelRequiredPopup()
            return
        }
        guard !webSearchDisabled else {
            showWebSearchDisabledReason = true
            return
        }

        let newValue = !settings.webSearchArmed
        settings.webSearchArmed = newValue
#if os(iOS)
        Haptics.impact(.light)
#endif
        if newValue && !hasSeenWebSearchNotice {
            hasSeenWebSearchNotice = true
            showWebSearchNotice = true
        }
    }

    private func togglePython() {
        guard hasActiveChatModel else {
            presentModelRequiredPopup()
            return
        }
        guard !pythonDisabled else {
            showPythonDisabledReason = true
            return
        }

        let newValue = !settings.pythonArmed
        settings.pythonArmed = newValue
#if os(iOS)
        Haptics.impact(.light)
#endif
        if newValue && !hasSeenWebSearchNotice {
            hasSeenWebSearchNotice = true
            showWebSearchNotice = true
        }
    }

    private func presentModelRequiredPopup() {
        if let onModelRequiredTap {
            onModelRequiredTap()
        } else {
            showDisabledReason = true
        }
    }

#if os(macOS)
    private func selectPhotosFromMacMenu() {
        showActionMenu = false
        guard !attachmentsDisabled else {
            showDisabledReason = true
            return
        }
        guard !isProcessingImport else { return }
        isProcessingImport = true
        Task { await presentOpenPanel() }
    }

    private func selectRecordAudioFromMacMenu() {
        showActionMenu = false
        Task { await vm.toggleAudioRecording() }
    }

    private func selectAttachMediaFromMacMenu() {
        showActionMenu = false
        guard !isProcessingMediaImport else { return }
        isProcessingMediaImport = true
        Task { await presentMediaOpenPanel() }
    }

    private func selectWebSearchFromMacMenu() {
        showActionMenu = false
        toggleWebSearch()
    }

    private func selectPythonFromMacMenu() {
        showActionMenu = false
        togglePython()
    }

    @MainActor
    private func presentOpenPanel() async {
        defer { isProcessingImport = false }
        let remaining = remainingSlots
        guard remaining > 0 else { return }

        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "heic", "heif", "webp"]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = remaining > 1 ? "Choose Images" : "Choose Image"

        let response = panel.runModal()
        guard response == .OK else { return }
        let picks = panel.urls.prefix(remaining)
        for url in picks {
            if let image = UIImage(contentsOfFile: url.path) {
                await vm.savePendingImage(image)
            }
        }
    }

    @MainActor
    private func presentMediaOpenPanel() async {
        defer { isProcessingMediaImport = false }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = TranscriptionMediaSupport.allowedContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Attach")

        let response = panel.runModal()
        guard response == .OK else { return }
        for url in panel.urls where TranscriptionMediaSupport.isSupported(url) {
            await vm.savePendingMediaFile(from: url)
        }
    }

    private func selectAttachDocumentFromMacMenu() {
        showActionMenu = false
        Task { await presentDocumentOpenPanel() }
    }

    @MainActor
    private func presentDocumentOpenPanel() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DatasetDocumentSupport.allowedUTTypes()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Attach")

        let response = panel.runModal()
        guard response == .OK else { return }
        let urls = panel.urls.filter { ChatVM.attachedDocumentExtensions.contains($0.pathExtension.lowercased()) }
        guard !urls.isEmpty else { return }
        vm.attachDocument(urls: urls)
    }
#else
#if os(iOS)
    @MainActor
    private func loadRecentsIfNeeded() async {
        guard recentAssets.isEmpty else { return }
        let authorized = await requestPhotoAuthorization()
        if !authorized {
            photoAccessDenied = true
            return
        }
        photoAccessDenied = false
        await fetchRecentAssets()
    }

    private func requestPhotoAuthorization() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                    continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        default:
            return false
        }
    }

    @MainActor
    private func fetchRecentAssets() async {
        guard !isLoadingRecents else { return }
        isLoadingRecents = true
        thumbnailCache.removeAll()

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 10

        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        recentAssets = assets

        let manager = PHCachingImageManager()
        let requestOptions = PHImageRequestOptions()
        requestOptions.deliveryMode = .opportunistic
        requestOptions.isSynchronous = false
        let targetSize = CGSize(width: 220, height: 220)

        for asset in assets {
            manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: requestOptions) { image, _ in
                guard let image else { return }
                Task { @MainActor in
                    thumbnailCache[asset.localIdentifier] = image
                }
            }
        }

        isLoadingRecents = false
    }

    private func toggleRecentAssetSelection(_ asset: PHAsset) async {
        let id = asset.localIdentifier
        if let attachedURL = recentAssetAttachmentURLs[id] {
            if let index = vm.pendingImageURLs.firstIndex(of: attachedURL) {
                vm.removePendingImage(at: index)
            }
            recentAssetAttachmentURLs.removeValue(forKey: id)
            return
        }

        guard remainingSlots > 0 else { return }
        let previousURLs = Set(vm.pendingImageURLs)
        if let cached = thumbnailCache[id] {
            await vm.savePendingImage(cached)
            if let addedURL = vm.pendingImageURLs.last(where: { !previousURLs.contains($0) }) {
                recentAssetAttachmentURLs[id] = addedURL
            }
            return
        }

        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        // Async, not isSynchronous=true: a synchronous request blocks the main actor while the
        // full-resolution image is fetched/decoded, freezing the tray on tap.
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        let targetSize = CGSize(width: 1600, height: 1600)

        let selected: UIImage? = await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
        if let selected {
            await vm.savePendingImage(selected)
            if let addedURL = vm.pendingImageURLs.last(where: { !previousURLs.contains($0) }) {
                recentAssetAttachmentURLs[id] = addedURL
            }
        }
    }

    private func pruneRecentAssetSelection(using pendingURLs: [URL]) {
        let active = Set(pendingURLs)
        recentAssetAttachmentURLs = recentAssetAttachmentURLs.filter { active.contains($0.value) }
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraUnavailableAlert = true
            return
        }
        showCameraCapture = true
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
#endif
    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        let allowance = remainingSlots
        guard allowance > 0 else {
            await MainActor.run { pickerItems.removeAll() }
            return
        }
        for item in items.prefix(allowance) {
            if let data = try? await item.loadTransferable(type: Data.self) {
                await vm.savePendingImageData(data)
            }
        }
        await MainActor.run { pickerItems.removeAll() }
    }

    private func loadPickedVideos(_ items: [PhotosPickerItem]) async {
        for item in items.prefix(1) {
            guard let video = try? await item.loadTransferable(type: PickedVideoFile.self) else { continue }
            await vm.savePendingMediaFile(from: video.url, originalFilename: video.originalFilename)
            try? FileManager.default.removeItem(at: video.url)
        }
        await MainActor.run { videoPickerItems.removeAll() }
    }

    private func handleMediaImportResult(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else { return }
        for url in urls where TranscriptionMediaSupport.isSupported(url) {
            await vm.savePendingMediaFile(from: url)
        }
    }

#if os(iOS)
    private func handleDocumentImportResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let documents = urls.filter {
            ChatVM.attachedDocumentExtensions.contains($0.pathExtension.lowercased())
        }
        guard !documents.isEmpty else { return }
        vm.attachDocument(urls: documents)
    }
#endif

#endif
}

#if canImport(PhotosUI) && canImport(CoreTransferable) && !os(macOS)
private struct PickedVideoFile: Transferable {
    let url: URL
    let originalFilename: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let sourceURL = received.file
            let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("noema-photo-video-\(UUID().uuidString).\(ext)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return PickedVideoFile(url: destination, originalFilename: sourceURL.lastPathComponent)
        }
    }
}
#endif

private struct BadgeView: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2)
            .bold()
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.75))
            )
            .foregroundStyle(Color.white)
    }
}

#if os(macOS)
private struct MacQuickActionPopover: View {
    let showsPhotoAction: Bool
    let attachmentsDisabled: Bool
    let attachmentsDisabledReason: String
    let showsWebSearchAction: Bool
    let webSearchArmed: Bool
    let webSearchDisabled: Bool
    let webSearchDisabledReason: String
    let showsPythonAction: Bool
    let pythonArmed: Bool
    let pythonDisabled: Bool
    let pythonDisabledReason: String
    let isRecordingAudio: Bool
    let activeDatasetName: String?
    let onPhotos: () -> Void
    let onRecordAudio: () -> Void
    let onAttachMedia: () -> Void
    let onAttachDocument: () -> Void
    let onDataset: () -> Void
    let onWebSearch: () -> Void
    let onPython: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            if showsPhotoAction {
                MacQuickActionRow(
                    icon: "photo.on.rectangle",
                    title: String(localized: "Add Photos"),
                    stateText: attachmentsDisabled ? String(localized: "Unavailable") : nil,
                    isArmed: false,
                    isUnavailable: attachmentsDisabled,
                    unavailableReason: attachmentsDisabledReason,
                    action: onPhotos
                )
            }

            MacQuickActionRow(
                icon: isRecordingAudio ? "stop.circle.fill" : "mic",
                title: isRecordingAudio ? String(localized: "Stop Recording") : String(localized: "Record Audio"),
                stateText: isRecordingAudio ? String(localized: "Recording") : nil,
                isArmed: isRecordingAudio,
                isUnavailable: false,
                unavailableReason: "",
                action: onRecordAudio
            )

            MacQuickActionRow(
                icon: "waveform.badge.plus",
                title: String(localized: "Attach Audio/Video"),
                stateText: nil,
                isArmed: false,
                isUnavailable: false,
                unavailableReason: "",
                action: onAttachMedia
            )

            MacQuickActionRow(
                icon: "doc.text",
                title: String(localized: "Attach Document"),
                stateText: nil,
                isArmed: false,
                isUnavailable: false,
                unavailableReason: "",
                action: onAttachDocument
            )

            MacQuickActionRow(
                icon: "books.vertical",
                title: activeDatasetName ?? String(localized: "Use Dataset"),
                stateText: activeDatasetName == nil ? nil : String(localized: "Active"),
                isArmed: activeDatasetName != nil,
                isUnavailable: false,
                unavailableReason: "",
                action: onDataset
            )

            if showsWebSearchAction {
                MacQuickActionRow(
                    icon: "globe",
                    title: String(localized: "Web Search"),
                    stateText: webSearchDisabled ? String(localized: "Unavailable") : webSearchArmed ? String(localized: "Enabled") : String(localized: "Disabled"),
                    isArmed: webSearchArmed,
                    isUnavailable: webSearchDisabled,
                    unavailableReason: webSearchDisabledReason,
                    action: onWebSearch
                )
            }

            if showsPythonAction {
                MacQuickActionRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: String(localized: "Python"),
                    stateText: pythonDisabled ? String(localized: "Unavailable") : pythonArmed ? String(localized: "Enabled") : String(localized: "Disabled"),
                    isArmed: pythonArmed,
                    isUnavailable: pythonDisabled,
                    unavailableReason: pythonDisabledReason,
                    action: onPython
                )
            }
        }
        .padding(6)
        .frame(width: 224)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .padding(2)
    }
}

private struct MacQuickActionRow: View {
    let icon: String
    let title: String
    let stateText: String?
    let isArmed: Bool
    let isUnavailable: Bool
    let unavailableReason: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(iconStyle)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let stateText {
                    Text(stateText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isUnavailable ? .secondary : .primary)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isUnavailable ? 0.56 : 1)
        .help(isUnavailable ? unavailableReason : title)
        .onHover { isHovering = $0 }
        .accessibilityHint(isUnavailable ? Text(unavailableReason) : Text(""))
    }

    private var iconStyle: Color {
        if isUnavailable { return .secondary }
        if isArmed { return .accentColor }
        return .primary
    }
}
#endif

#if os(iOS)
private struct AttachmentTray: View {
    let showsPhotoSection: Bool
    let photosDisabled: Bool
    let photosDisabledReason: String
    let recentAssets: [PHAsset]
    let thumbnails: [String: UIImage]
    let selectedAssetIDs: Set<String>
    let isLoading: Bool
    let remainingSlots: Int
    let photoAccessGranted: Bool
    let showsWebSearchAction: Bool
    let webSearchArmed: Bool
    let webSearchDisabled: Bool
    let webSearchDisabledReason: String
    let showsPythonAction: Bool
    let pythonArmed: Bool
    let pythonDisabled: Bool
    let pythonDisabledReason: String
    let isRecordingAudio: Bool
    let activeDatasetName: String?
    let onCamera: () -> Void
    let onAllPhotos: () -> Void
    let onRecordAudio: () -> Void
    let onAttachMedia: () -> Void
    let onAttachDocument: () -> Void
    let onDataset: () -> Void
    let onWebSearchTap: () -> Void
    let onPythonTap: () -> Void
    let onAssetTap: (PHAsset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsPhotoSection {
                VStack(alignment: .leading, spacing: 10) {
                    if photosDisabled {
                        Label(photosDisabledReason, systemImage: "photo.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Spacer()
                        Button(action: onAllPhotos) {
                            Text("All Photos")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(remainingSlots == 0 || photosDisabled)
                        .accessibilityIdentifier("chat-attachments-all-photos")
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            cameraTile

                            if isLoading {
                                ForEach(0..<6, id: \.self) { _ in placeholderTile() }
                            } else if photoAccessGranted {
                                if recentAssets.isEmpty {
                                    emptyTile
                                } else {
                                    ForEach(Array(recentAssets.enumerated()), id: \.element.localIdentifier) { index, asset in
                                        let isSelected = selectedAssetIDs.contains(asset.localIdentifier)
                                        if let image = thumbnails[asset.localIdentifier] {
                                            thumbnailTile(
                                                image: image,
                                                index: index,
                                                isSelected: isSelected
                                            ) {
                                                onAssetTap(asset)
                                            }
                                        } else {
                                            thumbnailPlaceholderTile(
                                                index: index,
                                                isSelected: isSelected
                                            ) {
                                                onAssetTap(asset)
                                            }
                                        }
                                    }
                                }
                            } else {
                                permissionTile
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                }
                .disabled(photosDisabled)
                .opacity(photosDisabled ? 0.55 : 1)
            }

            if showsPhotoSection { Divider().padding(.top, 2) }

            toolRow(
                icon: "books.vertical",
                title: activeDatasetName ?? String(localized: "Datasets"),
                subtitle: activeDatasetName == nil
                    ? String(localized: "Choose Dataset")
                    : String(localized: "Dataset retrieval is active"),
                isArmed: activeDatasetName != nil,
                isDisabled: false,
                identifier: "chat-tool-dataset",
                action: onDataset
            )

            toolRow(
                icon: isRecordingAudio ? "stop.circle.fill" : "mic",
                title: isRecordingAudio ? String(localized: "Stop Recording") : String(localized: "Record Audio"),
                subtitle: isRecordingAudio ? String(localized: "Recording") : String(localized: "Record a voice note for transcription."),
                isArmed: isRecordingAudio,
                isDisabled: false,
                identifier: "chat-tool-record-audio",
                action: onRecordAudio
            )

            toolRow(
                icon: "waveform.badge.plus",
                title: String(localized: "Attach Audio/Video"),
                subtitle: String(localized: "Import media and transcribe it locally when available."),
                isArmed: false,
                isDisabled: false,
                identifier: "chat-tool-attach-media",
                action: onAttachMedia
            )

            toolRow(
                icon: "doc.text",
                title: String(localized: "Attach Document"),
                subtitle: String(localized: "Import PDFs, EPUBs, or text files to build local knowledge bases."),
                isArmed: false,
                isDisabled: false,
                identifier: "chat-tool-attach-document",
                action: onAttachDocument
            )

            if showsWebSearchAction {
                Divider().padding(.top, 2)

                toolRow(
                    icon: "globe",
                    title: String(localized: "Web Search"),
                    subtitle: webSearchDisabled ? webSearchDisabledReason : (webSearchArmed ? String(localized: "Enabled") : String(localized: "Disabled")),
                    isArmed: webSearchArmed,
                    isDisabled: webSearchDisabled,
                    identifier: "chat-tool-web-search",
                    action: onWebSearchTap
                )
            }

            if showsPythonAction {
                if showsPhotoSection || showsWebSearchAction { Divider().padding(.top, 2) }

                toolRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: String(localized: "Python"),
                    subtitle: pythonDisabled ? pythonDisabledReason : (pythonArmed ? String(localized: "Enabled") : String(localized: "Disabled")),
                    isArmed: pythonArmed,
                    isDisabled: pythonDisabled,
                    identifier: "chat-tool-python",
                    action: onPythonTap
                )
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-attachment-tray")
    }

    private func toolRow(icon: String, title: String, subtitle: String, isArmed: Bool, isDisabled: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isDisabled ? .secondary : .primary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isDisabled ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if isArmed && !isDisabled {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.7))
            )
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.75 : 1)
        .accessibilityIdentifier(identifier)
    }

    private var cameraTile: some View {
        Button(action: onCamera) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
                    )
                Image(systemName: "camera.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 96, height: 96)
        }
        .buttonStyle(.plain)
        .disabled(remainingSlots == 0)
        .accessibilityLabel(Text("Take Photo"))
        .accessibilityHint(Text("Opens the camera to attach a photo to your next message."))
        .accessibilityIdentifier("chat-attachments-camera")
    }

    private func thumbnailTile(image: UIImage, index: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.white.opacity(0.12),
                                lineWidth: isSelected ? 2 : 0.8
                            )
                    )
                if isSelected {
                    selectionBadge
                        .padding(6)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String.localizedStringWithFormat(String(localized: "Recent photo %d"), index + 1)))
        .accessibilityValue(isSelected ? Text("Selected") : Text(""))
        .accessibilityHint(Text(isSelected ? "Removes this photo from your next message." : "Adds this photo to your next message."))
        .accessibilityIdentifier("chat-attachment-recent-\(index + 1)")
    }

    private func placeholderTile(isSelected: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.secondary.opacity(0.14))
            .frame(width: 96, height: 96)
            .overlay(
                ZStack(alignment: .topTrailing) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    if isSelected {
                        selectionBadge
                            .padding(6)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            )
            .accessibilityHidden(true)
    }

    private func thumbnailPlaceholderTile(index: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 96, height: 96)
                .overlay(
                    ZStack(alignment: .topTrailing) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        if isSelected {
                            selectionBadge
                                .padding(6)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String.localizedStringWithFormat(String(localized: "Recent photo %d"), index + 1)))
        .accessibilityValue(isSelected ? Text("Selected") : Text(""))
        .accessibilityHint(Text(isSelected ? "Removes this photo from your next message." : "Adds this photo to your next message."))
        .accessibilityIdentifier("chat-attachment-recent-\(index + 1)")
    }

    private var selectionBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white, Color.accentColor)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }

    private var emptyTile: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: 190, height: 96)
            .overlay(alignment: .leading) {
                Text("No recent photos yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var permissionTile: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: 180, height: 86)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allow photo access to see recents.")
                        .font(.footnote)
                        .foregroundStyle(.primary)
                    Text("Tap All Photos to choose manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
            .accessibilityElement(children: .combine)
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraCaptureView

        init(parent: CameraCaptureView) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            } else {
                parent.onCancel()
            }
        }
    }
}
#endif

#else
import SwiftUI

struct VisionAttachmentButton: View {
    var body: some View { EmptyView() }
}
#endif
