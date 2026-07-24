import SwiftUI
#if canImport(UIKit) && !os(visionOS)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(TTSKit)
import TTSKit
#endif

enum ContextOverflowStrategy: String, CaseIterable, Identifiable {
    case truncateMiddle = "truncate_middle"
    case rollingWindow = "rolling_window"
    case stopAtLimit = "stop_at_limit"

    static let defaultValue: ContextOverflowStrategy = .truncateMiddle

    var id: String { rawValue }

    static func from(_ rawValue: String) -> ContextOverflowStrategy {
        ContextOverflowStrategy(rawValue: rawValue) ?? .defaultValue
    }

    var titleKey: String {
        switch self {
        case .truncateMiddle:
            return "Truncate Middle"
        case .rollingWindow:
            return "Rolling Window"
        case .stopAtLimit:
            return "Stop at Limit"
        }
    }

    var settingsDescriptionKey: String {
        switch self {
        case .truncateMiddle:
            return "When context overflows, keep the beginning and latest turns while removing middle turns."
        case .rollingWindow:
            return "When context overflows, keep recent turns and drop the earliest conversation."
        case .stopAtLimit:
            return "When context overflows, stop generation and show an error instead of trimming."
        }
    }

    var overflowActionKey: String {
        switch self {
        case .truncateMiddle:
            return "Middle conversation turns were trimmed to fit this model's context window."
        case .rollingWindow:
            return "Earlier conversation turns were trimmed to fit this model's context window."
        case .stopAtLimit:
            return "Generation stopped at the context limit for this model."
        }
    }

    var overflowDeteriorationKey: String {
        switch self {
        case .truncateMiddle:
            return "Memory quality deteriorates in the middle of the conversation when trimming is applied."
        case .rollingWindow:
            return "Memory quality deteriorates for the beginning of the conversation when trimming is applied."
        case .stopAtLimit:
            return "Memory quality no longer improves because generation is stopped once the limit is reached."
        }
    }

    /// Short label for the in-chat status pill.
    var pillTitleKey: String {
        switch self {
        case .truncateMiddle:
            return "Context full · middle trimmed"
        case .rollingWindow:
            return "Context full · oldest trimmed"
        case .stopAtLimit:
            return "Context limit reached"
        }
    }

    var pillSymbolName: String {
        switch self {
        case .truncateMiddle:
            return "scissors"
        case .rollingWindow:
            return "arrow.triangle.2.circlepath"
        case .stopAtLimit:
            return "exclamationmark.octagon.fill"
        }
    }

    /// Trimming strategies are informational; stop-at-limit is a hard stop.
    var isHardStop: Bool { self == .stopAtLimit }
}

enum ChatAttachmentCleanupPolicy: String, CaseIterable, Identifiable {
    case immediate = "immediate"
    case daily = "daily"
    case weekly = "weekly"
    case never = "never"

    static let storageKey = "chatAttachmentCleanupPolicy"
    static let defaultValue: ChatAttachmentCleanupPolicy = .immediate

    var id: String { rawValue }

    static func from(_ rawValue: String) -> ChatAttachmentCleanupPolicy {
        ChatAttachmentCleanupPolicy(rawValue: rawValue) ?? .defaultValue
    }

    var titleKey: String {
        switch self {
        case .immediate:
            return "Immediately"
        case .daily:
            return "Daily"
        case .weekly:
            return "Weekly"
        case .never:
            return "Never"
        }
    }

    var settingsDescriptionKey: String {
        switch self {
        case .immediate:
            return "Delete chat image files as soon as a chat is deleted. Recommended for minimum storage use."
        case .daily:
            return "Keep deleted-chat image files temporarily and clean them up once per day."
        case .weekly:
            return "Keep deleted-chat image files temporarily and clean them up once per week."
        case .never:
            return "Never automatically delete chat image files after chat deletion."
        }
    }
}

final class SettingsModel: ObservableObject {
    @AppStorage("isAdvancedMode") var isAdvancedMode = false {
        didSet { objectWillChange.send() }
    }
    @AppStorage("offGrid") var offGrid = false
    @AppStorage("hapticsEnabled") var hapticsEnabled = true
    @AppStorage("compactChatModeEnabled") var compactChatModeEnabled = false
    @AppStorage("muteSoundEffects") var muteSoundEffects = false
    @AppStorage("playSoundEffectsInSilentMode") var playSoundEffectsInSilentMode = false
    @AppStorage("appearance") var appearance = "system" // light, dark, system
    @AppStorage("verboseLogging") var verboseLogging = false
    /// When on (and Advanced mode is enabled), each answer shows a generation-stats
    /// footer (tokens, tok/s, time-to-first-token, total duration) and the context
    /// gauge announces absolute token counts. Lives in the Diagnostics section.
    @AppStorage("showGenerationDiagnostics") var showGenerationDiagnostics = true {
        didSet { objectWillChange.send() }
    }
    @AppStorage("huggingFaceToken") var huggingFaceToken = ""
    @AppStorage("bypassRAMCheck") var bypassRAMCheck = false
#if os(visionOS)
    @AppStorage("visionVerticalPanelLayout") var visionVerticalPanelLayout = false
#endif
    // System preset removed; default system behavior is always used
    @AppStorage("ragMaxChunks") var ragMaxChunks = 5
    @AppStorage("attachedDocExpiryHours") var attachedDocExpiryHours = 24
    @AppStorage("ragMinScore") var ragMinScore: Double = 0.5
    @AppStorage("ragRetrievalMode") var ragRetrievalModeRaw = DatasetRetrievalMode.defaultValue.rawValue
    @AppStorage("contextOverflowStrategy") var contextOverflowStrategyRaw = ContextOverflowStrategy.defaultValue.rawValue
    @AppStorage(ChatAttachmentCleanupPolicy.storageKey) var chatAttachmentCleanupPolicyRaw = ChatAttachmentCleanupPolicy.defaultValue.rawValue
    @AppStorage(ChatSendBehavior.storageKey) var chatSendBehaviorRaw = ChatSendBehavior.defaultValue.rawValue
    @AppStorage(TranscriptionSettings.onDeviceOnlyKey) var asrOnDeviceOnly = true
    @AppStorage(TranscriptionSettings.localeIdentifierKey) var asrLocaleIdentifier = ""
    @AppStorage(TranscriptionSettings.autoTranscribeAttachmentsKey) var asrAutoTranscribeAttachments = false
    @AppStorage(TranscriptionSettings.engineIDKey) var asrEngineIDRaw = TranscriptionEngineID.appleSpeech.rawValue
    @AppStorage(TranscriptionSettings.includeTimestampsInPromptKey) var asrIncludeTimestamps = false
    @AppStorage(SystemPreset.customSystemPromptIntroKey) var customSystemPromptIntro = SystemPreset.defaultEditableIntro
#if os(iOS)
    @AppStorage(PassScannerSettings.signerBaseURLKey) var walletPassSignerBaseURL = ""
    @AppStorage(PassScannerSettings.keepScansWithDraftsKey) var walletPassKeepScansWithDrafts = false
    @AppStorage(PassScannerSettings.remoteFallbackAllowedKey) var walletPassRemoteFallbackAllowed = false
    @AppStorage(PassScannerSettings.warningSensitivityKey) var walletPassWarningSensitivity = "balanced"
    @AppStorage(PassExtractionModelCatalog.activeModelPathKey) var walletPassActiveExtractionModelPath = ""
    @AppStorage(PassExtractionModelCatalog.activeModelIDKey) var walletPassActiveExtractionModelID = ""
    @AppStorage(PassExtractionModelCatalog.activeModelQuantKey) var walletPassActiveExtractionModelQuant = ""
    @AppStorage(PassExtractionModelCatalog.activeModelFormatKey) var walletPassActiveExtractionModelFormat = ""
    @AppStorage(PassExtractionModelCatalog.activeModelNameKey) var walletPassActiveExtractionModelName = ""
    @AppStorage(PassExtractionModelCatalog.extractionThinkingEnabledKey) var walletPassExtractionThinkingEnabled = false
#endif

    // MCPs removed

    /// Clears all chat sessions. This mutates `ChatVM.sessions` which lives on
    /// the `MainActor`, so ensure we're also on the main actor when calling it.
    @MainActor
    func clearChatHistory(_ vm: ChatVM) {
        vm.clearChatHistory()
    }



    @MainActor
    func resetAppData() {
        objectWillChange.send()
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        ModelSettingsStore.clear()
        // Restore default values so UI reflects the reset immediately.
        isAdvancedMode = false
        offGrid = false
        hapticsEnabled = true
        compactChatModeEnabled = false
        muteSoundEffects = false
        playSoundEffectsInSilentMode = false
        appearance = "system"
        verboseLogging = false
        showGenerationDiagnostics = true
        huggingFaceToken = ""
        bypassRAMCheck = false
#if os(visionOS)
        visionVerticalPanelLayout = false
#endif
        ragMaxChunks = 5
        ragMinScore = 0.5
        ragRetrievalModeRaw = DatasetRetrievalMode.defaultValue.rawValue
        contextOverflowStrategyRaw = ContextOverflowStrategy.defaultValue.rawValue
        chatAttachmentCleanupPolicyRaw = ChatAttachmentCleanupPolicy.defaultValue.rawValue
        chatSendBehaviorRaw = ChatSendBehavior.defaultValue.rawValue
        customSystemPromptIntro = SystemPreset.defaultEditableIntro
        attachedDocExpiryHours = 24
        asrOnDeviceOnly = true
        asrLocaleIdentifier = ""
        asrAutoTranscribeAttachments = false
        asrEngineIDRaw = TranscriptionEngineID.appleSpeech.rawValue
        asrIncludeTimestamps = false
        UserDefaults.standard.removeObject(forKey: VoiceOutputSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: VoiceOutputSettings.voiceIDKey)
        UserDefaults.standard.removeObject(forKey: VoiceOutputSettings.systemRateKey)
#if os(iOS)
        walletPassSignerBaseURL = ""
        walletPassKeepScansWithDrafts = false
        walletPassRemoteFallbackAllowed = false
        walletPassWarningSensitivity = "balanced"
        walletPassActiveExtractionModelPath = ""
        walletPassActiveExtractionModelID = ""
        walletPassActiveExtractionModelQuant = ""
        walletPassActiveExtractionModelFormat = ""
        walletPassActiveExtractionModelName = ""
        walletPassExtractionThinkingEnabled = false
        _ = try? PassSigningCredentialStore.removeToken()
#endif
        StartupPreferencesStore.save(StartupPreferences())
    }
}

struct SettingsView: View {
    @StateObject private var settings = SettingsModel()
    @ObservedObject private var webSettings = SettingsStore.shared
    @ObservedObject private var memoryStore = MemoryStore.shared
#if os(iOS)
    @ObservedObject private var boardingPassDraftStore = BoardingPassDraftStore.shared
#endif
    @EnvironmentObject var chatVM: ChatVM
    @EnvironmentObject var tabRouter: TabRouter
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var datasetManager: DatasetManager
    @EnvironmentObject var downloadController: DownloadController
    @EnvironmentObject var walkthrough: GuidedWalkthroughManager
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Installer used to mirror onboarding's embedding model download flow
    @StateObject private var embedInstaller = EmbedModelInstaller()
#if canImport(UIKit)
    @State private var showOnboarding = false
#endif
#if os(macOS)
    @State private var showMacOnboarding = false
    @ObservedObject private var mcpManager = MCPServerManager.shared
#endif
    @State private var showLogs = false
    @State private var shareLogs = false
    @State private var showChatsCleared = false
    @State private var confirmClearChats = false
    @State private var confirmResetAppData = false
    @State private var confirmResetSystemPrompt = false
    @State private var showResetComplete = false
    @State private var isResettingAppData = false
    @State private var showMemoryInfo = false
    @State private var showPythonInfo = false
    @State private var showRAMInfo = false
    @State private var showASRLocaleInfo = false
    @State private var showOnDeviceTranscriptionInfo = false
    @State private var voiceOutputEngineRaw = VoiceOutputSettings.preferredEngineID.rawValue
    @State private var voiceOutputVoiceID = VoiceOutputSettings.selectedVoiceID ?? "ryan"
    @State private var voiceSystemRate: Double = 0.5
    @ObservedObject private var voicePreviewer = VoiceSamplePreviewer.shared
    @State private var showChunksInfo = false
    @State private var showSimilarityInfo = false
    @State private var estimateModelPath: String = ""
    @State private var embedAvailable = FileManager.default.fileExists(atPath: EmbeddingModel.modelURL.path)
    @State private var showEmbeddingModels = false
    @State private var showEmbedDeleteError = false
    @State private var embedDeleteErrorMessage = ""
    @State private var isCleaningDownloadLeftovers = false
    @State private var showDownloadCleanupResult = false
    @State private var downloadCleanupResultMessage = ""
    @State private var startupPreferences = StartupPreferencesStore.load()
    @State private var settingsDestination: SettingsDestination?
    @State private var showUpdate = false
    @State private var showWebSearchInfo = false
    @State private var autopilotConfig = AutopilotConfigStore.load()
    @State private var autopilotSetupMode: AutopilotSetupMode?
    @ObservedObject private var autopilotLedger = AutopilotLedger.shared
#if os(iOS)
    @State private var walletPassSignerToken = ""
    @State private var walletPassTokenStored = false
    @State private var confirmDeleteWalletPassDrafts = false
    @FocusState private var walletPassTokenFocused: Bool
#endif
    @State private var selectedLanguageCode: String = UserDefaults.standard.string(forKey: "appLanguageCode") ?? LocalizationManager.detectSystemLanguage()
    @FocusState private var customSearchURLFocused: Bool
    @FocusState private var systemPromptFocused: Bool
    private let llamaCppBuild = "b10018 (0.16.0, 22b208b1)"
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? NoemaUpdateView.releaseVersion
    }
    @ObservedObject private var enterpriseManager = EnterprisePolicyManager.shared
    private enum ScrollTarget: Hashable {
        case offGrid
    }

    private enum SettingsDestination: String, Hashable, Identifiable {
        case startupPreferences
        case manageMemories
        case appPreferences
        case autopilot
        case embeddingModel
        case privacy
        case privacyFlight
        case toolStore
        case datasetHealth
        case modelDoctor
        case storageAdvisor
        case diagnosticsHub
        case modelInternals
        case speculativeDecoding
        case speechASR
#if os(macOS)
        case mcp
#endif
#if os(iOS)
        case walletPasses
        case passExtractionModel
#endif
        case retrievalSettings
        case hiddenModels
        case remoteAudioEndpoint
        case notesIssues
        case whisperModelCatalog
        case voiceModelCatalog
        case enterprise

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .startupPreferences: return "Startup Preferences"
            case .manageMemories: return "Manage Memories"
            case .appPreferences: return "App Preferences"
            case .autopilot: return "Autopilot"
            case .embeddingModel: return "Embedding Models"
            case .privacy: return "Privacy"
            case .privacyFlight: return "Privacy Flight Recorder"
            case .toolStore: return "Tool Store"
            case .datasetHealth: return "Dataset Health"
            case .modelDoctor: return "Model Doctor"
            case .storageAdvisor: return "Storage Advisor"
            case .diagnosticsHub: return "Diagnostics & Tools"
            case .modelInternals: return "Model Internals"
            case .speculativeDecoding: return "Speculative Decoding"
            case .speechASR: return "Speech & ASR"
#if os(macOS)
            case .mcp: return "Model Context Protocol"
#endif
#if os(iOS)
            case .walletPasses: return "Wallet Passes"
            case .passExtractionModel: return "Pass Extraction Model"
#endif
            case .retrievalSettings: return "Retrieval Settings"
            case .hiddenModels: return "Hidden Models"
            case .remoteAudioEndpoint: return "Remote Audio Endpoint"
            case .notesIssues: return "Notes & Issues"
            case .whisperModelCatalog: return "Whisper Model"
            case .voiceModelCatalog: return "Voice Model"
            case .enterprise: return "Enterprise"
            }
        }
    }

    private var currentWhisperEngineID: TranscriptionEngineID {
        let selected = TranscriptionSettings.selectedEngineID
        return selected.isLocalWhisper
            ? selected
            : TranscriptionBackendFactory.preferredLocalWhisperEngineID()
    }

    var body: some View {
        NavigationStack {
            settingsContent
                .navigationTitle(LocalizedStringKey("Settings"))
                .onAppear {
                    refreshEmbeddingAvailability()
                    refreshStartupPreferences()
                    autopilotConfig = AutopilotConfigStore.load()
#if os(iOS)
                    loadWalletPassTokenState()
#endif
                }
#if canImport(UIKit)
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingView(showOnboarding: $showOnboarding)
                }
#endif
#if os(macOS)
                .sheet(isPresented: $showMacOnboarding) {
                    MacOnboardingView(showOnboarding: $showMacOnboarding) {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    }
                    .environmentObject(tabRouter)
                    .environmentObject(chatVM)
                    .environmentObject(modelManager)
                    .environmentObject(datasetManager)
                    .environmentObject(downloadController)
                    .environmentObject(walkthrough)
                }
#endif
                .onReceive(modelManager.$downloadedModels) { _ in
                    refreshStartupPreferences()
                }
                .onReceive(modelManager.$remoteBackends) { _ in
                    refreshStartupPreferences()
                }
                .onReceive(NotificationCenter.default.publisher(for: .embeddingModelAvailabilityChanged)) { notification in
                    if let available = notification.userInfo?["available"] as? Bool {
                        embedAvailable = available
                    } else {
                        refreshEmbeddingAvailability()
                    }
                }
                .onChange(of: embedInstaller.state) { _, newValue in
                    // When installation completes, warm up the backend for snappier first use
                    if newValue == .ready {
                        Task { await EmbeddingModel.shared.warmUp() }
                    }
                }
                .onChange(of: localizationManager.locale) { _, _ in
                    selectedLanguageCode = currentLanguageCode
                }
#if os(macOS)
                .sheet(isPresented: $showLogs) {
                    macSettingsSheet(title: "Logs", onClose: { showLogs = false }) {
                        LogViewerView(url: Logger.shared.logFileURL)
                    }
                }
                .sheet(isPresented: $showEmbeddingModels) {
                    EmbeddingModelsView()
                        .environmentObject(downloadController)
                        .environmentObject(datasetManager)
                }
                .sheet(item: $settingsDestination) { destination in
                    if destination == .embeddingModel || destination == .whisperModelCatalog || destination == .remoteAudioEndpoint {
                        settingsDestinationView(destination)
                            .environmentObject(downloadController)
                            .environmentObject(datasetManager)
                    } else {
                        let isMCP = destination == .mcp
                        macSettingsSheet(
                            title: destination.titleKey,
                            onClose: { settingsDestination = nil },
                            minWidth: isMCP ? 900 : 560,
                            idealWidth: isMCP ? 980 : 560,
                            minHeight: isMCP ? 620 : 520,
                            idealHeight: isMCP ? 700 : 520
                        ) {
                            settingsDestinationView(destination)
                                .environmentObject(downloadController)
                                .environmentObject(datasetManager)
                        }
                    }
                }
#else
                .navigationDestination(isPresented: $showLogs) {
                    LogViewerView(url: Logger.shared.logFileURL)
                }
                .navigationDestination(isPresented: $showEmbeddingModels) {
                    EmbeddingModelsView()
                }
                .navigationDestination(item: $settingsDestination) { destination in
                    settingsDestinationView(destination)
                }
#endif
                .sheet(isPresented: $shareLogs) {
                    ShareLink(item: Logger.shared.logFileURL) {
                        Text(LocalizedStringKey("Share Logs"))
                    }
                }
                .sheet(isPresented: $showUpdate) {
                    NoemaUpdateView {
                        showUpdate = false
                    }
                }
                .sheet(item: $autopilotSetupMode, onDismiss: {
                    autopilotConfig = AutopilotConfigStore.load()
                }) { mode in
                    AutopilotSetupView(mode: mode)
                        .environmentObject(modelManager)
                }
                .alert(LocalizedStringKey("Chat History Deleted"), isPresented: $showChatsCleared) {
                    Button(LocalizedStringKey("OK"), role: .cancel) {}
                }
                .alert(LocalizedStringKey("App Data Reset"), isPresented: $showResetComplete) {
                    Button(LocalizedStringKey("OK"), role: .cancel) {}
                } message: {
                    Text(LocalizedStringKey("Noema has been reset. The embedding model remains installed."))
                }
                .alert(LocalizedStringKey("Persistent Memory"), isPresented: $showMemoryInfo) {
                    Button(LocalizedStringKey("OK"), role: .cancel) { }
                } message: {
                    Text(LocalizedStringKey("When enabled, models can save durable facts like stable preferences or recurring project constraints to on-device memory that persists across conversations."))
                }
                .alert(LocalizedStringKey("Python Code Execution"), isPresented: $showPythonInfo) {
                    Button(LocalizedStringKey("OK"), role: .cancel) { }
                } message: {
                    Text(LocalizedStringKey("When enabled and armed via the + menu in chat, the model can write and run Python code to help answer your questions. Code runs in a sandboxed environment: no network access, no file access outside a temporary directory, and a 30-second timeout."))
                }
                .confirmationDialog(LocalizedStringKey("Delete All Chats"), isPresented: $confirmClearChats, titleVisibility: .visible) {
                    Button(LocalizedStringKey("Delete All Chats"), role: .destructive) {
                        settings.clearChatHistory(chatVM)
                        showChatsCleared = true
                        confirmClearChats = false
                    }
                    Button(LocalizedStringKey("Cancel"), role: .cancel) { confirmClearChats = false }
                } message: {
                    Text(LocalizedStringKey("This permanently removes every chat conversation. This action cannot be undone."))
                }
                .confirmationDialog(LocalizedStringKey("Reset App Data"), isPresented: $confirmResetAppData, titleVisibility: .visible) {
                    Button(LocalizedStringKey("Reset App Data"), role: .destructive) {
                        Task { await performResetAppData() }
                    }
                    Button(LocalizedStringKey("Cancel"), role: .cancel) { confirmResetAppData = false }
                } message: {
                    Text(LocalizedStringKey("Deletes all chats, downloaded models, and datasets, and restores settings to defaults. The embedding model stays installed."))
                }
                .confirmationDialog(LocalizedStringKey("Reset System Prompt"), isPresented: $confirmResetSystemPrompt, titleVisibility: .visible) {
                    Button(LocalizedStringKey("Reset to Default"), role: .destructive) {
                        settings.customSystemPromptIntro = SystemPreset.defaultEditableIntro
                        systemPromptFocused = false
                        confirmResetSystemPrompt = false
                    }
                    Button(LocalizedStringKey("Cancel"), role: .cancel) { confirmResetSystemPrompt = false }
                } message: {
                    Text(LocalizedStringKey("Restore Noema's default system prompt? Your custom text will be replaced."))
                }
                .alert(LocalizedStringKey("About RAM Usage"), isPresented: $showRAMInfo) {
                    Button(LocalizedStringKey("OK"), role: .cancel) { }
                } message: {
                    Text(LocalizedStringKey("The memory budget uses the app's live allocation limit when the operating system exposes it. The limit is calculated from Noema's current memory footprint and remaining allocation headroom, and it may change with system conditions. If live data is unavailable, Noema shows a conservative device estimate."))
                }
                .alert(LocalizedStringKey("Max Chunks"), isPresented: $showChunksInfo) {
                    Button(LocalizedStringKey("OK"), role: .cancel) {}
                } message: {
                    Text(LocalizedStringKey("A “chunk” is a short passage pulled from your dataset. This sets the maximum number that can be added to the prompt — the retriever returns up to this many, using fewer only when little matches your question. Higher values improve recall but use more of the context window and can slow responses. Typical range 3–6."))
                }
                .alert(LocalizedStringKey("Similarity Threshold"), isPresented: $showSimilarityInfo) {
                    Button(LocalizedStringKey("OK"), role: .cancel) {}
                } message: {
                    Text(LocalizedStringKey("How closely a passage must match your question (by cosine similarity) to be preferred. Lower = more passages (higher recall, more noise). Higher = fewer, more precise passages. The Retrieval Mode nudges this floor automatically — Broad loosens it, Focused keeps it strict. Try 0.2–0.4 for broad questions; 0.5–0.7 for precise lookups."))
                }
                .alert(LocalizedStringKey("Failed to Delete Embedding Model"), isPresented: $showEmbedDeleteError) {
                    Button(LocalizedStringKey("OK"), role: .cancel) {}
                } message: {
                    Text(embedDeleteErrorMessage)
                }
                .alert(LocalizedStringKey("Download Cleanup Complete"), isPresented: $showDownloadCleanupResult) {
                    Button(LocalizedStringKey("OK"), role: .cancel) {}
                } message: {
                    Text(downloadCleanupResultMessage)
                }
#if os(macOS)
                .frame(minWidth: 640, minHeight: 560)
#endif
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
#if os(macOS)
        macSettingsView
#else
        // iOS and visionOS share the card/navigation settings layout.
        settingsiPhoneView
#endif
    }

#if os(macOS)
    @ViewBuilder
    private func macSettingsSheet<Content: View>(
        title: LocalizedStringKey,
        onClose: @escaping () -> Void,
        minWidth: CGFloat = 560,
        idealWidth: CGFloat = 560,
        minHeight: CGFloat = 520,
        idealHeight: CGFloat = 520,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(LocalizedStringKey("Close"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.windowBackground.ignoresSafeArea())
        .frame(
            minWidth: minWidth,
            idealWidth: idealWidth,
            minHeight: minHeight,
            idealHeight: idealHeight
        )
    }
#endif

    // One shared destination builder for macOS, iOS, and visionOS. (Previously
    // this switch was duplicated verbatim in two platform-gated copies.)
    @ViewBuilder
    private func settingsDestinationView(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .startupPreferences:
            settingsDetailForm(LocalizedStringKey("Startup Preferences")) {
                Section {
                    startupSettingsContent
                }
            }
        case .manageMemories:
            MemoryManagementView()
        case .autopilot:
            settingsDetailForm(LocalizedStringKey("Autopilot")) {
                autopilotSettingsContent
            }
        case .appPreferences:
            settingsDetailForm(LocalizedStringKey("App Preferences")) {
                Section {
                    generalContent
                }
            }
        case .embeddingModel:
            EmbeddingModelsView()
        case .privacy:
            settingsDetailForm(LocalizedStringKey("Privacy")) {
                Section {
                    privacyContent
                }
            }
        case .privacyFlight:
            PrivacyFlightRecorderView()
        // Every "Diagnostics & Tools" entry shares one definition in DiagnosticsTool;
        // each tool's screen is built from DiagnosticsTool.destination.
        case .modelDoctor, .modelInternals, .storageAdvisor,
             .speculativeDecoding, .datasetHealth, .toolStore:
            if let tool = DiagnosticsTool(rawValue: destination.rawValue) {
                tool.destination
            }
        case .diagnosticsHub:
            DiagnosticsHubView()
        case .speechASR:
            settingsDetailForm(LocalizedStringKey("Speech & ASR")) {
                Section {
                    transcriptionSettingsContent
                }
            }
#if os(macOS)
        case .mcp:
            MCPSettingsView()
#endif
#if os(iOS)
        case .walletPasses:
            settingsDetailForm(LocalizedStringKey("Wallet Passes")) {
                walletPassSection
            }
        case .passExtractionModel:
            PassExtractionModelsView()
#endif
        case .retrievalSettings:
            settingsDetailForm(LocalizedStringKey("Retrieval Settings")) {
                Section {
                    advancedRetrievalContent
                }
            }
        case .hiddenModels:
            settingsDetailForm(LocalizedStringKey("Hidden Models")) {
                Section {
                    hiddenModelsContent
                }
            }
        case .remoteAudioEndpoint:
            AudioLMRemoteEndpointView()
        case .notesIssues:
            DisclaimerView()
        case .whisperModelCatalog:
            WhisperModelsView(engineID: currentWhisperEngineID)
        case .voiceModelCatalog:
            VoiceModelCatalogView()
        case .enterprise:
            EnterpriseSettingsView()
        }
    }

    @ViewBuilder
    private func settingsDetailForm<Content: View>(_ title: LocalizedStringKey,
                                                   @ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
#if !os(macOS)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
#endif
#if os(iOS)
        .scrollDismissesKeyboard(.interactively)
#endif
    }

#if os(iOS) || os(visionOS)

    private var settingsiPhoneView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    modeSettingsHeader

                    if !DeviceGPUInfo.supportsGPUOffload {
                        iPhoneNoticeCard(
                            title: String(localized: "CPU Rendering Only", locale: localizationManager.locale),
                            message: String(localized: "This device doesn't support GPU offload; GGUF models will run on the CPU and generation speed will be significantly slower.\nFastest option on this device: ET models.", locale: localizationManager.locale)
                        )
                    }

                    iPhoneSettingsSection(title: Text("Device Overview")) {
                        deviceOverviewCard
                    }

                    iPhoneSettingsSection(title: Text("Autopilot")) {
                        autopilotCard
                    }

                    iPhoneSettingsSection(title: Text("Enterprise")) {
                        enterpriseOverviewCard
                    }

                    if settings.isAdvancedMode {
                        iPhoneSettingsSection(title: Text("Diagnostics")) {
                            diagnosticsOverviewCard
                        }
                    }

                    iPhoneSettingsSection(title: Text("Startup")) {
                        startupOverviewCard
                    }

                    iPhoneSettingsSection(title: Text("Memory")) {
                        memoryOverviewCard
                    }

                    iPhoneSettingsSection(title: Text("Tools")) {
                        toolsCard
                    }

                    iPhoneSettingsSection(title: Text("Network")) {
                        networkCard
                    }

                    iPhoneSettingsSection(title: Text("Model Sources")) {
                        modelSourcesCard
                    }

                    iPhoneSettingsSection(title: Text("Chat & Data")) {
                        chatAndDataCard
                    }

                    iPhoneSettingsSection(title: Text("About & Support")) {
                        aboutSupportCard
                    }

                    iPhoneSettingsSection(title: Text("Advanced Options")) {
                        advancedOptionsCard
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSectionLabel(title: Text("About Noema"))
                        aboutNoemaCard
                        Text("This app bundles llama.cpp; we keep this in sync with upstream b‑releases.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)
                    }

                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .guideHighlight(.settingsForm)
#if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    if customSearchURLFocused {
                        Button(LocalizedStringKey("Done")) {
                            customSearchURLFocused = false
                            hideKeyboard()
                        }
                    }
                    if walletPassTokenFocused {
                        Button(LocalizedStringKey("Done")) {
                            walletPassTokenFocused = false
                            hideKeyboard()
                        }
                    }
                }
            }
#endif
            .onChange(of: walkthrough.step) { _, step in
                guard step == .settingsHighlights else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut) {
                        proxy.scrollTo(ScrollTarget.offGrid, anchor: .center)
                    }
                }
            }
            .onAppear {
                if walkthrough.step == .settingsHighlights {
                    DispatchQueue.main.async {
                        proxy.scrollTo(ScrollTarget.offGrid, anchor: .center)
                    }
                }
                if estimateModelPath.isEmpty {
                    estimateModelPath = startupPreferences.localModelPath ?? (modelManager.loadedModel?.url.path ?? "")
                }
                selectedLanguageCode = currentLanguageCode
            }
            .onChange(of: settings.isAdvancedMode) { _, isAdvanced in
                if !isAdvanced {
                    customSearchURLFocused = false
                }
            }
        }
    }

    @ViewBuilder
    private func iPhoneSettingsSection<Content: View>(title: Text,
                                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionLabel(title: title)
            content()
        }
    }

    private var modeSettingsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(LocalizedStringKey("Mode"), selection: $settings.isAdvancedMode) {
                Text(LocalizedStringKey("Simple")).tag(false)
                Text(LocalizedStringKey("Advanced")).tag(true)
            }
            .pickerStyle(.segmented)

            Text(modeExplanation)
                .font(.system(size: 15))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deviceOverviewCard: some View {
        let metrics = ramMetrics()
        return SettingsSurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                            .frame(width: 56, height: 56)
                        Image(systemName: "iphone")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.9))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: metrics.info.modelName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(verbatim: memoryBudgetSummary(
                            budgetText: metrics.budgetText,
                            isLiveProcessLimit: metrics.budgetIsLive
                        ))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        if let model = metrics.model, let estimateText = metrics.estimateText {
                            Text(verbatim: workingSetEstimateSummary(for: model, estimateText: estimateText))
                                .font(.system(size: 14))
                                .foregroundStyle(Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)

                    Button {
                        showRAMInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                if settings.isAdvancedMode {
                    SettingsDivider()
                    SettingsThermalStageRow()
                    SettingsDivider()
                    SettingsRAMUsageRow()
                }
            }
        }
    }

    private var startupOverviewCard: some View {
        SettingsSurfaceCard {
            VStack(spacing: 0) {
                Button {
                    settingsDestination = .startupPreferences
                } label: {
                    SettingsNavigationRow(
                        title: Text("Local default"),
                        trailingText: Text(verbatim: startupLocalDefaultTitle),
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                Button {
                    settingsDestination = .startupPreferences
                } label: {
                    SettingsNavigationRow(
                        title: Text(verbatim: startupRemoteActionTitle),
                        subtitle: startupRemoteActionSubtitle.map { Text(verbatim: $0) },
                        trailingText: startupRemoteActionTrailing.map { Text(verbatim: $0) },
                        leadingSystemImage: startupPreferences.remoteSelections.isEmpty ? "plus" : nil,
                        leadingTint: Color.accentColor,
                        titleColor: startupPreferences.remoteSelections.isEmpty ? Color.accentColor : Color.primary,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                SettingsToggleRow(
                    title: Text("Bypass RAM safety check (may cause crashes)"),
                    subtitle: Text("Load models even if they may exceed your device's memory budget."),
                    isOn: $settings.bypassRAMCheck
                )
            }
        }
    }

    private var diagnosticsOverviewCard: some View {
        SettingsSurfaceCard {
            VStack(alignment: .leading, spacing: 0) {
                SettingsToggleRow(
                    title: Text("Show generation diagnostics"),
                    subtitle: Text("Show tokens, speed and total time under each answer, and absolute token counts on the context gauge."),
                    isOn: $settings.showGenerationDiagnostics
                )

                SettingsDivider()

                Button {
                    settingsDestination = .diagnosticsHub
                } label: {
                    SettingsNavigationRow(
                        title: Text("Diagnostics & Tools"),
                        subtitle: Text("Runtime health, model inspection & tuning"),
                        leadingSystemImage: "stethoscope",
                        leadingTint: Color.accentColor,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var memoryOverviewCard: some View {
        SettingsSurfaceCard {
            VStack(alignment: .leading, spacing: 0) {
                SettingsToggleRow(
                    title: Text("Persistent Memory"),
                    subtitle: Text("Memories persist across conversations on this device."),
                    isOn: $webSettings.memoryEnabled,
                    infoAction: { showMemoryInfo = true }
                )

                SettingsDivider()

                Button {
                    settingsDestination = .manageMemories
                } label: {
                    SettingsNavigationRow(
                        title: Text("Manage Memories"),
                        subtitle: memoryOverviewSubtitle,
                        trailingText: Text(verbatim: memorySavedCountText),
                        leadingSystemImage: "square.stack.3d.up",
                        leadingTint: Color.accentColor,
                        titleColor: Color.accentColor,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Unified "Tools" card: the master switches for the in-chat tools (Python
    /// Code Execution and Web Search). These gate availability globally; arming a
    /// tool for a specific conversation still happens from the + menu in chat.
    private var toolsCard: some View {
        SettingsSurfaceCard {
            VStack(alignment: .leading, spacing: 0) {
                SettingsToggleRow(
                    title: Text("Python Code Execution"),
                    subtitle: pythonOverviewSubtitle,
                    isOn: pythonEnabledBinding,
                    infoAction: { showPythonInfo = true }
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: Text("Web Search button"),
                    subtitle: Text("Enable privacy-preserving web search from chat."),
                    isOn: webSearchEnabledBinding,
                    infoAction: { showWebSearchInfo = true }
                )

                if webSettings.webSearchEnabled {
                    SettingsDivider()

                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: webSearchStatusText)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if settings.isAdvancedMode {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Custom SearXNG URL")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.secondary)

                                TextField("https://search.noemaai.com", text: $webSettings.customSearXNGURL)
                                    .platformKeyboardType(.url)
                                    .autocorrectionDisabled(true)
                                    .platformAutocapitalization(.never)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 16))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                                    )
                                    .focused($customSearchURLFocused)
#if canImport(UIKit)
                                    .submitLabel(.done)
#endif
                                    .onSubmit {
                                        customSearchURLFocused = false
                                    }
                            }
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var autopilotCard: some View {
        SettingsSurfaceCard {
            Button {
                settingsDestination = .autopilot
            } label: {
                SettingsNavigationRow(
                    title: Text("Autopilot"),
                    subtitle: Text(verbatim: autopilotSummaryText),
                    leadingSystemImage: "arrow.triangle.branch",
                    leadingTint: Color.accentColor,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var autopilotSummaryText: String {
        guard autopilotConfig.isReadyToArm else {
            return String(localized: "Not Set Up")
        }
        guard modelManager.autoRoutingArmed else {
            return String(localized: "Off")
        }
        let localName = modelManager.loadedModel?.name ?? String(localized: "On-device")
        let cloudName = autopilotConfig.escalationDisplayName ?? ""
        return "\(String(localized: "On")) — \(localName) → \(cloudName)"
    }

    /// Off-grid / network kill switch, split out of the old "Code Execution"
    /// card so the Tools card stays focused on chat tools.
    private var networkCard: some View {
        SettingsSurfaceCard {
            SettingsToggleRow(
                title: Text("Off-grid Mode"),
                subtitle: Text("Block network, downloads and cloud connections."),
                isOn: $settings.offGrid,
                id: ScrollTarget.offGrid
            )
        }
    }

    private var modelSourcesCard: some View {
        SettingsSurfaceCard {
            SettingsHuggingFaceContent()
                .padding(.vertical, 4)
        }
    }

    private var chatAndDataCard: some View {
        SettingsSurfaceCard {
            VStack(spacing: 0) {
                Button {
                    triggerImpact(.medium)
                    confirmClearChats = true
                } label: {
                    SettingsActionRow(
                        title: Text("Delete All Chats"),
                        leadingSystemImage: "trash",
                        accentColor: .red
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                Button {
                    triggerImpact(.medium)
                    confirmResetAppData = true
                } label: {
                    SettingsActionRow(
                        title: Text("Reset App Data"),
                        leadingSystemImage: "arrow.clockwise",
                        accentColor: .red
                    )
                }
                .buttonStyle(.plain)
                .disabled(isResettingAppData)

                SettingsDivider()

                Button {
                    Task { await performDownloadCleanup() }
                } label: {
                    SettingsActionRow(
                        title: Text(isCleaningDownloadLeftovers ? "Cleaning Download Leftovers…" : "Clean Download Leftovers"),
                        subtitle: Text("Remove incomplete downloads, stale resume data, and temporary files without deleting installed models or datasets."),
                        leadingSystemImage: "externaldrive.badge.xmark",
                        accentColor: .accentColor
                    )
                }
                .buttonStyle(.plain)
                .disabled(isCleaningDownloadLeftovers)

                SettingsDivider()

                Button {
                    reopenOnboarding()
                } label: {
                    SettingsNavigationRow(
                        title: Text("Reopen Onboarding"),
                        leadingSystemImage: "sparkles",
                        leadingTint: .accentColor,
                        titleColor: .accentColor,
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var aboutSupportCard: some View {
        SettingsSurfaceCard {
            VStack(spacing: 0) {
                Button {
                    showUpdate = true
                } label: {
                    SettingsNavigationRow(
                        title: Text("What's New"),
                        subtitle: Text(verbatim: "Noema \(NoemaUpdateView.releaseVersion)"),
                        leadingSystemImage: "sparkles",
                        leadingTint: .accentColor,
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                Link(destination: URL(string: "https://noemaai.com/terms")!) {
                    SettingsNavigationRow(
                        title: Text("Terms of Use"),
                        leadingSystemImage: "doc.text",
                        leadingTint: .accentColor
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                Link(destination: URL(string: "https://noemaai.com/privacy")!) {
                    SettingsNavigationRow(
                        title: Text("Privacy Policy"),
                        leadingSystemImage: "shield",
                        leadingTint: .accentColor
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                Link(destination: URL(string: "mailto:clientcare@noemaai.com")!) {
                    SettingsNavigationRow(
                        title: Text("Contact Support"),
                        leadingSystemImage: "bubble.left",
                        leadingTint: .accentColor
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                Button {
                    settingsDestination = .notesIssues
                } label: {
                    SettingsNavigationRow(
                        title: Text("Notes & Issues"),
                        leadingSystemImage: "exclamationmark.circle",
                        leadingTint: Color.secondary.opacity(0.8)
                    )
                }
                .buttonStyle(.plain)

                if (Bundle.main.infoDictionary?["AppStoreID"] as? String).map({ !$0.isEmpty }) == true {
                    SettingsDivider()

                    Button {
                        ReviewPrompter.shared.openWriteReviewPageIfAvailable()
                    } label: {
                        SettingsNavigationRow(
                            title: Text("Write a Review"),
                            leadingSystemImage: "star",
                            leadingTint: .accentColor
                        )
                    }
                    .buttonStyle(.plain)
                }

                SettingsDivider()

                Link(destination: URL(string: "https://noemaai.com/early-testers")!) {
                    SettingsNavigationRow(
                        title: Text("Join Early Testers"),
                        subtitle: Text("Help shape Noema by trying upcoming features and sharing feedback."),
                        leadingSystemImage: "sparkles",
                        leadingTint: .accentColor
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var aboutNoemaCard: some View {
        SettingsSurfaceCard {
            VStack(spacing: 0) {
                SettingsNavigationRow(
                    title: Text("Llama.cpp"),
                    subtitle: Text("Latest integrated release: \(llamaCppBuild)"),
                    showsChevron: false
                )

                SettingsDivider()

                SettingsNavigationRow(
                    title: Text("Noema"),
                    subtitle: Text("Version \(appVersion)"),
                    leadingView: AnyView(
                        Image("Noema")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    ),
                    showsChevron: false
                )
            }
        }
    }

    private var advancedOptionsCard: some View {
        SettingsSurfaceCard {
            VStack(spacing: 0) {
                Button {
                    settingsDestination = .appPreferences
                } label: {
                    SettingsNavigationRow(
                        title: Text("App Preferences"),
                        subtitle: Text("Appearance, language, sound, and system prompt."),
                        leadingSystemImage: "slider.horizontal.3",
                        leadingTint: .accentColor
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                Button {
                    settingsDestination = .embeddingModel
                } label: {
                    SettingsNavigationRow(
                        title: Text("Embedding Model"),
                        subtitle: embedAvailable ? Text(verbatim: EmbeddingModelCatalog.activeRecord().displayName) : Text("Not installed"),
                        leadingSystemImage: "square.stack.3d.up",
                        leadingTint: .accentColor
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                Button {
                    settingsDestination = .privacy
                } label: {
                    SettingsNavigationRow(
                        title: Text("Privacy"),
                        subtitle: Text("Chat image cleanup and local data behavior."),
                        leadingSystemImage: "lock",
                        leadingTint: .accentColor
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                Button {
                    settingsDestination = .speechASR
                } label: {
                    SettingsNavigationRow(
                        title: Text("Speech & ASR"),
                        subtitle: Text("Transcription engine, locale, Whisper, and remote ASR."),
                        leadingSystemImage: "waveform",
                        leadingTint: .accentColor
                    )
                }
                .buttonStyle(.plain)

#if os(iOS)
	                SettingsDivider()

	                Button {
	                    settingsDestination = .walletPasses
	                } label: {
	                    SettingsNavigationRow(
	                        title: Text("Wallet Passes"),
	                        subtitle: Text("Extraction model, hosted signing, retention, and warning settings."),
	                        leadingSystemImage: "wallet.pass",
	                        leadingTint: .accentColor
	                    )
	                }
	                .buttonStyle(.plain)
#endif

                if settings.isAdvancedMode {
                    SettingsDivider()

                    Button {
                        settingsDestination = .retrievalSettings
                    } label: {
                        SettingsNavigationRow(
                            title: Text("Retrieval Settings"),
                            subtitle: Text("Max chunks and similarity threshold."),
                            leadingSystemImage: "slider.horizontal.3",
                            leadingTint: .accentColor
                        )
                    }
                    .buttonStyle(.plain)

                    if !modelManager.hiddenModels.isEmpty {
                        SettingsDivider()

                        Button {
                            settingsDestination = .hiddenModels
                        } label: {
                            SettingsNavigationRow(
                                title: Text("Hidden Models"),
                                subtitle: Text(verbatim: hiddenModelsSummaryText),
                                leadingSystemImage: "eye.slash",
                                leadingTint: .accentColor
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

#endif
    // Available on all platforms: the macOS `pythonCard` uses these too.
    private var pythonOverviewSubtitle: Text {
        let status = PythonRuntime.status()
        let description = String(localized: "Write and run Python code in a sandbox.", locale: localizationManager.locale)
        let backend: String
        switch status.backend {
        case "embedded":
            backend = String(localized: "Using embedded Python runtime.", locale: localizationManager.locale)
        case "process":
            backend = String(localized: "Using system Python 3.", locale: localizationManager.locale)
        default:
            backend = String(localized: "Python runtime unavailable.", locale: localizationManager.locale)
        }

        var lines = [description, backend]
        if webSettings.pythonEnabled, let reason = status.reason, !reason.isEmpty {
            lines.append(reason)
        }
        return Text(verbatim: lines.joined(separator: "\n"))
    }

    private var pythonEnabledBinding: Binding<Bool> {
        Binding(
            get: { webSettings.pythonEnabled },
            set: { newValue in
                webSettings.pythonEnabled = newValue
                if !newValue {
                    webSettings.pythonArmed = false
                }
            }
        )
    }

#if os(iOS) || os(visionOS)
    private var webSearchEnabledBinding: Binding<Bool> {
        Binding(
            get: { webSettings.webSearchEnabled },
            set: { newValue in
                webSettings.webSearchEnabled = newValue
                if !newValue {
                    webSettings.webSearchArmed = false
                    customSearchURLFocused = false
                }
            }
        )
    }

    private var webSearchStatusText: String {
        if webSettings.customSearXNGURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Using default: https://search.noemaai.com. Search requests are available without quotas.", locale: localizationManager.locale)
        }
        return String.localizedStringWithFormat(
            String(localized: "Using custom instance: %@", locale: localizationManager.locale),
            webSettings.customSearXNGURL
        )
    }

    private var startupLocalDefaultTitle: String {
        guard let path = startupPreferences.localModelPath,
              let model = modelManager.downloadedModels.first(where: { $0.url.path == path }) else {
            return String(localized: "None", locale: localizationManager.locale)
        }
        return model.name
    }

    private var startupRemoteActionTitle: String {
        startupPreferences.remoteSelections.isEmpty
            ? String(localized: "Add remote default", locale: localizationManager.locale)
            : String(localized: "Manage remote defaults", locale: localizationManager.locale)
    }

    private var startupRemoteActionSubtitle: String? {
        guard !startupPreferences.remoteSelections.isEmpty else { return nil }
        let count = startupPreferences.remoteSelections.count
        let format = count == 1
            ? String(localized: "%d remote default configured.", locale: localizationManager.locale)
            : String(localized: "%d remote defaults configured.", locale: localizationManager.locale)
        return String.localizedStringWithFormat(format, count)
    }

    private var startupRemoteActionTrailing: String? {
        startupPreferences.remoteSelections.isEmpty
            ? nil
            : localizedCount(startupPreferences.remoteSelections.count)
    }

    private var memorySavedCountText: String {
        String.localizedStringWithFormat(
            String(localized: "%d of %d saved", locale: localizationManager.locale),
            memoryStore.entries.count,
            MemoryStore.maximumEntries
        )
    }

    private var memoryOverviewSubtitle: Text? {
        if let notice = currentMemoryNoticeText {
            return Text(verbatim: notice)
        }
        if memoryStore.entries.count >= MemoryStore.maximumEntries {
            return Text("Memory is full. Delete an entry to add another.")
        }
        if memoryStore.entries.isEmpty {
            return Text("No memories saved yet.")
        }
        return Text(
            String.localizedStringWithFormat(
                String(localized: "Up to %d memories can be stored across conversations on this device.", locale: localizationManager.locale),
                MemoryStore.maximumEntries
            )
        )
    }

    private var currentMemoryNoticeText: String? {
        let status = chatVM.memoryPromptBudgetStatus
        guard webSettings.memoryEnabled, status.shouldDisplayNotice else { return nil }
        switch status.state {
        case .partiallyLoaded:
            return String.localizedStringWithFormat(
                String(localized: "Current model preloads %d of %d memories.", locale: localizationManager.locale),
                status.loadedCount,
                status.totalCount
            )
        case .notLoaded:
            return String(localized: "Current model cannot preload memories within its context budget.", locale: localizationManager.locale)
        case .inactive, .allLoaded:
            return nil
        }
    }

    private var hiddenModelsSummaryText: String {
        let count = modelManager.hiddenModels.count
        let format = count == 1
            ? String(localized: "%d model hidden from Stored.", locale: localizationManager.locale)
            : String(localized: "%d models hidden from Stored.", locale: localizationManager.locale)
        return String.localizedStringWithFormat(format, count)
    }

    private func workingSetEstimateSummary(for model: LocalModel, estimateText: String) -> String {
        let ctx = Int(modelManager.settings(for: model).contextLength)
        let ctxString = localizedCount(ctx)
        return String.localizedStringWithFormat(
            String(localized: "Working set estimate (%@): %@ @ %@ tokens", locale: localizationManager.locale),
            model.name,
            estimateText,
            ctxString
        )
    }

    private func localizedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = localizationManager.locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private struct SettingsSectionLabel: View {
        let title: Text

        var body: some View {
            title
                .textCase(.uppercase)
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.35)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 4)
        }
    }

    private struct SettingsSurfaceCard<Content: View>: View {
        let content: Content

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.025), radius: 8, x: 0, y: 3)
        }
    }

    private struct SettingsDivider: View {
        var body: some View {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
                .padding(.vertical, 12)
        }
    }

    private struct SettingsRowText: View {
        let title: Text
        let subtitle: Text?
        let titleColor: Color

        init(title: Text, subtitle: Text? = nil, titleColor: Color = .primary) {
            self.title = title
            self.subtitle = subtitle
            self.titleColor = titleColor
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                title
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    subtitle
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct SettingsToggleRow: View {
        let title: Text
        let subtitle: Text?
        @Binding var isOn: Bool
        let infoAction: (() -> Void)?
        let id: ScrollTarget?

        init(title: Text,
             subtitle: Text? = nil,
             isOn: Binding<Bool>,
             infoAction: (() -> Void)? = nil,
             id: ScrollTarget? = nil) {
            self.title = title
            self.subtitle = subtitle
            self._isOn = isOn
            self.infoAction = infoAction
            self.id = id
        }

        var body: some View {
            Group {
                if id == .offGrid {
                    rowContent
                        .id(ScrollTarget.offGrid)
                        .guideHighlight(.settingsOffGrid)
                } else {
                    rowContent
                }
            }
            .onChange(of: isOn) { _, newValue in
                if id == .offGrid {
                    NetworkKillSwitch.setEnabled(newValue)
                }
            }
        }

        private var rowContent: some View {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        SettingsRowText(title: title)
                        if let infoAction {
                            Button(action: infoAction) {
                                Image(systemName: "questionmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.secondary.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let subtitle {
                        subtitle
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)

                Toggle("", isOn: $isOn)
                    .labelsHidden()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private struct SettingsNavigationRow: View {
        let title: Text
        let subtitle: Text?
        let trailingText: Text?
        let leadingSystemImage: String?
        let leadingTint: Color
        let leadingView: AnyView?
        let titleColor: Color
        let showsChevron: Bool

        init(title: Text,
             subtitle: Text? = nil,
             trailingText: Text? = nil,
             leadingSystemImage: String? = nil,
             leadingTint: Color = .accentColor,
             leadingView: AnyView? = nil,
             titleColor: Color = .primary,
             showsChevron: Bool = true) {
            self.title = title
            self.subtitle = subtitle
            self.trailingText = trailingText
            self.leadingSystemImage = leadingSystemImage
            self.leadingTint = leadingTint
            self.leadingView = leadingView
            self.titleColor = titleColor
            self.showsChevron = showsChevron
        }

        var body: some View {
            HStack(alignment: .center, spacing: 14) {
                if let leadingView {
                    leadingView
                } else if let leadingSystemImage {
                    ZStack {
                        Circle()
                            .fill(leadingTint.opacity(0.10))
                            .frame(width: 44, height: 44)
                        Image(systemName: leadingSystemImage)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(leadingTint)
                    }
                }

                SettingsRowText(title: title, subtitle: subtitle, titleColor: titleColor)

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    if let trailingText {
                        trailingText
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                    }
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.secondary.opacity(0.7))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private struct SettingsActionRow: View {
        let title: Text
        let subtitle: Text?
        let leadingSystemImage: String
        let accentColor: Color

        init(title: Text,
             subtitle: Text? = nil,
             leadingSystemImage: String,
             accentColor: Color) {
            self.title = title
            self.subtitle = subtitle
            self.leadingSystemImage = leadingSystemImage
            self.accentColor = accentColor
        }

        var body: some View {
            SettingsNavigationRow(
                title: title,
                subtitle: subtitle,
                leadingSystemImage: leadingSystemImage,
                leadingTint: accentColor,
                titleColor: accentColor,
                showsChevron: true
            )
        }
    }

    private struct SettingsStatusBadge: View {
        let title: Text
        let color: Color

        var body: some View {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                title
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(color.opacity(0.10), in: Capsule())
        }
    }

    private struct SettingsUsageRing: View {
        let progress: Double
        let color: Color
        let label: Text

        var body: some View {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 10)

                Circle()
                    .trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                label
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }
            .frame(width: 68, height: 68)
        }
    }

    private struct SettingsThermalStageRow: View {
        @State private var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

        private var title: Text {
            switch thermalState {
            case .fair:
                return Text("Fair")
            case .serious:
                return Text("Serious")
            case .critical:
                return Text("Critical")
            default:
                return Text("Nominal")
            }
        }

        private var color: Color {
            switch thermalState {
            case .fair:
                return .yellow
            case .serious:
                return .orange
            case .critical:
                return .red
            default:
                return .green
            }
        }

        var body: some View {
            HStack(spacing: 12) {
                SettingsRowText(title: Text("Thermal Stage"))
                Spacer()
                SettingsStatusBadge(title: title, color: color)
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                thermalState = ProcessInfo.processInfo.thermalState
            }
        }
    }

    private struct SettingsRAMUsageRow: View {
        @State private var usageBytes: Int64 = 0
        @State private var budgetBytes: Int64? = ModelRAMAdvisor.currentMemoryBudgetSnapshot().bytes
        @State private var timer: Timer?

        private var progress: Double {
            guard let budgetBytes, budgetBytes > 0 else { return 0 }
            return min(1, Double(usageBytes) / Double(budgetBytes))
        }

        private var usageColor: Color {
            switch progress {
            case 0..<0.7:
                return .green
            case 0.7..<0.9:
                return .orange
            default:
                return .red
            }
        }

        private var usageSummary: String {
            ByteCountFormatter.string(fromByteCount: usageBytes, countStyle: .memory)
        }

        private var budgetSummary: String {
            guard let budgetBytes else { return "--" }
            return ByteCountFormatter.string(fromByteCount: budgetBytes, countStyle: .memory)
        }

        var body: some View {
            HStack(spacing: 16) {
                SettingsUsageRing(
                    progress: progress,
                    color: usageColor,
                    label: Text("\(Int(progress * 100))%")
                )

                SettingsRowText(
                    title: Text("App Memory Usage"),
                    subtitle: Text(verbatim: "\(usageSummary) of \(budgetSummary) budget")
                )

                Spacer()
            }
            .onAppear {
                refresh()
                start()
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
        }

        private func start() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    refresh()
                }
            }
        }

        private func refresh() {
            let bytes = Int64(c_app_memory_footprint())
            let budget = ModelRAMAdvisor.currentMemoryBudgetSnapshot().bytes
            withAnimation(.easeInOut(duration: 0.2)) {
                usageBytes = max(0, bytes)
                budgetBytes = budget
            }
        }
    }

    private struct iPhoneNoticeCard: View {
        let title: String
        let message: String

        var body: some View {
            SettingsSurfaceCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.orange)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Text(verbatim: message)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
#endif


    private var modeCard: some View {
        SettingsCard(title: LocalizedStringKey("Mode"), icon: "slider.horizontal.3") {
            modeSettingsContent
        }
    }

    private enum SettingsPage: String, CaseIterable, Identifiable {
        case general = "General"
        case autopilot = "Autopilot"
        case enterprise = "Enterprise"
        case models = "Models"
        case diagnostics = "Diagnostics"
        case search = "Tools"
        case speech = "Speech & ASR"
        case privacy = "Privacy"
        case advanced = "Advanced"
        case about = "About"

        var id: String { rawValue }
        var titleKey: LocalizedStringKey { LocalizedStringKey(rawValue) }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .enterprise: return "building.2"
            case .models: return "cpu"
            case .diagnostics: return "stethoscope"
            case .search: return "wrench.and.screwdriver"
            case .autopilot: return "arrow.triangle.branch"
            case .speech: return "waveform"
            case .privacy: return "hand.raised"
            case .advanced: return "slider.horizontal.3"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selectedPage: SettingsPage = .general

#if os(macOS)
    @ViewBuilder
    private var macSettingsView: some View {
        HSplitView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(SettingsPage.allCases) { page in
                            if (page == .advanced || page == .diagnostics) && !settings.isAdvancedMode {
                                EmptyView()
                            } else {
                                Button(action: { selectedPage = page }) {
                                    IndustrialHoverRow(selected: selectedPage == page) {
                                        HStack(spacing: 10) {
                                            Image(systemName: page.icon)
                                                .font(.system(size: 14))
                                                .frame(width: 20)
                                            Text(page.titleKey)
                                                .font(FontTheme.body)
                                                .fontWeight(.medium)
                                            Spacer()
                                        }
                                        .padding(.vertical, 8)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(selectedPage == page ? AppTheme.text : AppTheme.secondaryText)
                            }
                        }
                    }
                    .padding(12)
                }
            }
            .frame(minWidth: 200, maxWidth: 240)
            .background(AppTheme.sidebarBackground.ignoresSafeArea())

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text(selectedPage.titleKey)
                        .font(FontTheme.largeTitle)
                        .foregroundStyle(AppTheme.text)
                        .padding(.bottom, 8)

                    settingsContent(for: selectedPage)
                        .id(selectedPage)
                        .transition(AppMotion.pageTransition)
                }
                .padding(32)
                .frame(maxWidth: 800, alignment: .leading)
                .animation(AppMotion.resolve(AppMotion.submenu, reduceMotion: reduceMotion),
                           value: selectedPage)
            }
            .frame(minWidth: 400, maxWidth: .infinity)
            .background(AppTheme.windowBackground.ignoresSafeArea())
        }
        .onChange(of: settings.isAdvancedMode) { _, isAdvanced in
            if !isAdvanced && (selectedPage == .diagnostics || selectedPage == .advanced) {
                selectedPage = .general
            }
        }
    }

    @ViewBuilder
    private func settingsContent(for page: SettingsPage) -> some View {
        switch page {
        case .general:
            VStack(spacing: 24) {
                if !DeviceGPUInfo.supportsGPUOffload {
                    SettingsNoticeCard(
                        title: String(localized: "CPU Rendering Only"),
                        message: String(localized: "This Mac cannot offload GGUF models to the GPU. Expect slower generation speeds. ET models remain the fastest option here.")
                    )
                }
                modeCard
                startupCard
                generalCard
            }
        case .enterprise:
            VStack(spacing: 24) {
                enterpriseCard
            }
        case .models:
            VStack(spacing: 24) {
                ramCard
                ramBypassCard
                embeddingCard
                modelSourcesMacCard
                if !modelManager.hiddenModels.isEmpty {
                    hiddenModelsCard
                }
            }
        case .diagnostics:
            macDiagnosticsContent
        case .search:
            VStack(spacing: 24) {
                mcpCard
                pythonCard
                webSearchCard
                memoryCard
                offGridCard
            }
        case .autopilot:
            autopilotSettingsContent
        case .speech:
            speechASRCard
        case .privacy:
            privacyCard
        case .advanced:
            advancedCard
        case .about:
            VStack(spacing: 24) {
                aboutCard
                earlyTestersCard
                buildInfoCard
            }
        }
    }

    private var macDiagnosticsContent: some View {
        VStack(spacing: 24) {
            SettingsCard(title: LocalizedStringKey("Generation Diagnostics"), icon: "speedometer") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: $settings.showGenerationDiagnostics) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("Show generation diagnostics"))
                                .font(.system(size: 14, weight: .semibold))
                            Text(LocalizedStringKey("Show tokens, speed and total time under each answer, and absolute token counts on the context gauge."))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { settings.showGenerationDiagnostics.toggle() }
                    }
                    .toggleStyle(IndustrialToggleStyle())
                }
            }
            // Rendered from the shared DiagnosticsTool catalog so the macOS cards
            // and the iOS DiagnosticsHubView can never drift apart.
            ForEach(DiagnosticsTool.groups) { group in
                SettingsCard(title: group.header, icon: group.icon) {
                    VStack(spacing: 0) {
                        ForEach(Array(group.tools.enumerated()), id: \.element.id) { index, tool in
                            if index > 0 { Divider() }
                            macDiagnosticsRow(tool)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func macDiagnosticsRow(_ tool: DiagnosticsTool) -> some View {
        Button {
            settingsDestination = SettingsDestination(rawValue: tool.rawValue)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: tool.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tool.tint)
                    .frame(width: 30, height: 30)
                    .background(tool.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                        .font(FontTheme.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppTheme.text)
                    Text(tool.subtitle)
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
#endif

    private var ramCard: some View {
        let metrics = ramMetrics()
        return SettingsCard(title: LocalizedStringKey("Memory Budget"), icon: "memorychip") {
            ramSettingsContent(info: metrics.info,
                               budgetText: metrics.budgetText,
                               budgetIsLive: metrics.budgetIsLive,
                               modelForEstimate: metrics.model,
                               estimateText: metrics.estimateText)
        }
    }

    private var startupCard: some View {
        SettingsCard(title: LocalizedStringKey("Startup Defaults"), icon: "play.circle") {
            startupSettingsContent
        }
    }

    private var ramBypassCard: some View {
        SettingsCard(title: LocalizedStringKey("Runtime Safety"), icon: "shield.lefthalf.filled") {
            ramBypassContent
        }
    }

    private var pythonCard: some View {
        SettingsCard(title: LocalizedStringKey("Code Execution"), icon: "terminal") {
            Toggle(isOn: $webSettings.pythonEnabled) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey("Python Code Execution"))
                        .foregroundStyle(AppTheme.text)
                    Button { showPythonInfo = true } label: {
                        Image(systemName: "questionmark.circle").foregroundStyle(AppTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LocalizedStringKey("What is Python Code Execution?"))
                }
#if os(macOS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { webSettings.pythonEnabled.toggle() }
#endif
            }
            .tint(.blue)
#if os(macOS)
            .toggleStyle(IndustrialToggleStyle())
#endif
            .onChangeCompat(of: webSettings.pythonEnabled) { _, on in
                if !on { webSettings.pythonArmed = false }
            }

            if webSettings.pythonEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey("Allows models to write and execute Python code for calculations, data processing, and analysis. Execution is sandboxed with a 30-second timeout."))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(macPythonBackendLabel)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(.top, 4)
            }
        }
        // The `showPythonInfo` alert is presented once from the shared settings body.
    }

#if os(macOS)
    private var mcpCard: some View {
        return SettingsCard(title: LocalizedStringKey("Connections"), icon: "point.3.connected.trianglepath.dotted") {
            Button { settingsDestination = .mcp } label: {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(.blue).frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey("Model Context Protocol")).font(FontTheme.body).fontWeight(.semibold).foregroundStyle(AppTheme.text)
                        Text(verbatim: mcpStatusSummary).font(FontTheme.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.secondaryText)
                }
                .contentShape(Rectangle()).padding(.vertical, 4)
            }.buttonStyle(.plain)
        }
    }

    private var mcpStatusSummary: String {
        if mcpManager.servers.isEmpty { return String(localized: "No servers configured") }
        if mcpManager.attentionCount > 0 {
            return String.localizedStringWithFormat(String(localized: "%1$d connected · %2$d need attention"), mcpManager.connectedCount, mcpManager.attentionCount)
        }
        return String.localizedStringWithFormat(String(localized: "%d connected"), mcpManager.connectedCount)
    }
#endif

    /// macOS-safe Python backend status line (the iOS `pythonOverviewSubtitle`
    /// helper lives inside the iOS/visionOS-only section).
    private var macPythonBackendLabel: LocalizedStringKey {
        switch PythonRuntime.status().backend {
        case "embedded": return "Using embedded Python runtime."
        case "process": return "Using system Python 3."
        default: return "Python runtime unavailable."
        }
    }

    private var webSearchCard: some View {
        SettingsCard(title: LocalizedStringKey("Search"), icon: "magnifyingglass.circle") {
            Toggle(isOn: $webSettings.webSearchEnabled) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey("Web Search button"))
                        .foregroundStyle(AppTheme.text)
                    Button { showWebSearchInfo = true } label: {
                        Image(systemName: "questionmark.circle").foregroundStyle(AppTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LocalizedStringKey("What is Web Search button?"))
                }
#if os(macOS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { webSettings.webSearchEnabled.toggle() }
#endif
            }
            .tint(.blue)
#if os(macOS)
            .toggleStyle(IndustrialToggleStyle())
#endif
            .onChangeCompat(of: webSettings.webSearchEnabled) { _, on in
                if !on { webSettings.webSearchArmed = false }
            }

            if webSettings.webSearchEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.isAdvancedMode {
                        Text(LocalizedStringKey("Custom SearXNG URL"))
                            .foregroundStyle(AppTheme.text)
                        TextField("https://search.noemaai.com", text: $webSettings.customSearXNGURL)
                            .autocorrectionDisabled(true)
#if os(macOS)
                            .industrialField()
#else
                            .textFieldStyle(.roundedBorder)
#endif
                        if webSettings.customSearXNGURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(LocalizedStringKey("Using default: https://search.noemaai.com. Search requests are available without quotas."))
                                .foregroundStyle(AppTheme.secondaryText)
                        } else {
                            Text("Using custom instance: \(webSettings.customSearXNGURL)")
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    } else {
                        Text(LocalizedStringKey("Using default: https://search.noemaai.com. Search requests are available without quotas."))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .padding(.top, 4)
            }
        }
        .alert(LocalizedStringKey("Web Search button"), isPresented: $showWebSearchInfo) {
            Button(LocalizedStringKey("OK"), role: .cancel) { }
        } message: {
            Text(LocalizedStringKey("Allows models to use a privacy-preserving web search API when you tap the globe in chat. Default is ON. In Offline Only mode, the button is disabled."))
        }
    }

    private var modelSourcesMacCard: some View {
        SettingsCard(title: LocalizedStringKey("Model Sources"), icon: "arrow.down.circle") {
            SettingsHuggingFaceContent()
        }
    }

    private var memoryCard: some View {
        SettingsCard(title: LocalizedStringKey("Memory"), icon: "bookmark") {
            SettingsMemorySummaryContent()
        }
    }

    private var offGridCard: some View {
        SettingsCard(title: LocalizedStringKey("Network"), icon: "antenna.radiowaves.left.and.right") {
            offGridContent
        }
    }

    private var generalCard: some View {
        SettingsCard(title: LocalizedStringKey("General"), icon: "gearshape") {
            generalContent
        }
    }

    private var embeddingCard: some View {
        SettingsCard(title: LocalizedStringKey("Embedding Model"), icon: "square.stack.3d.up") {
            embeddingContent
        }
    }

    private var hiddenModelsCard: some View {
        SettingsCard(title: LocalizedStringKey("Hidden Models"), icon: "eye.slash") {
            hiddenModelsContent
        }
    }

    private var advancedCard: some View {
        SettingsCard(title: LocalizedStringKey("Retrieval"), icon: "doc.text.magnifyingglass") {
            advancedRetrievalContent
        }
    }

    private var privacyCard: some View {
        SettingsCard(title: LocalizedStringKey("Privacy"), icon: "hand.raised") {
            privacyContent
        }
    }

    private var speechASRCard: some View {
        SettingsCard(title: LocalizedStringKey("Speech & ASR"), icon: "waveform") {
            transcriptionSettingsContent
        }
    }

    private var aboutCard: some View {
        SettingsCard(title: LocalizedStringKey("About & Support"), icon: "info.circle") {
            aboutContent
        }
    }

    private var earlyTestersCard: some View {
        SettingsCard(title: LocalizedStringKey("Early Testers"), icon: "sparkles") {
            earlyTestersContent
        }
    }

    private var buildInfoCard: some View {
        SettingsCard(title: LocalizedStringKey("Build Info"), icon: "hare") {
            llamaContent
        }
    }

    private struct SettingsCard<Content: View>: View {
        let title: LocalizedStringKey
        let icon: String?
        let content: Content
        let minHeight: CGFloat?

        init(title: LocalizedStringKey, icon: String? = nil, minHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
            self.title = title
            self.icon = icon
            self.content = content()
            self.minHeight = minHeight
        }

        var body: some View {
#if os(macOS)
            // Industrial card: mono-caps header over a hairline, flat quiet fill.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Text(title)
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .padding(.vertical, 7)
                IndustrialHairline()

                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
#else
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Text(title)
                        .font(FontTheme.heading)
                        .foregroundStyle(AppTheme.text)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 26)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: minHeight)
            .glassifyIfAvailable(in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
            .background(AppTheme.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
#endif
        }
    }

    private struct SettingsNoticeCard: View {
        let title: String
        let message: String

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(title)
                        .font(FontTheme.body)
                        .fontWeight(.medium)
                        .foregroundStyle(AppTheme.text)
                }
                Text(message)
                    .font(FontTheme.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private struct AdaptiveColumnsLayout: Layout {
        var minColumnWidth: CGFloat = 360
        var spacing: CGFloat = 24

        private func columnCount(for width: CGFloat) -> Int {
            guard width.isFinite, width > 0 else { return 1 }
            let maxColumns = Int((width + spacing) / (minColumnWidth + spacing))
            return max(1, maxColumns)
        }

        private func measure(width: CGFloat, subviews: Subviews) -> (columns: Int, columnWidth: CGFloat, rowHeights: [CGFloat]) {
            let columns = columnCount(for: width)
            let totalSpacing = spacing * CGFloat(max(0, columns - 1))
            let columnWidth = max(0, (width - totalSpacing) / CGFloat(columns))

            var heights: [CGFloat] = []
            var currentMax: CGFloat = 0
            var col = 0
            for subview in subviews {
                let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
                currentMax = max(currentMax, size.height)
                col += 1
                if col == columns {
                    heights.append(currentMax)
                    currentMax = 0
                    col = 0
                }
            }
            if col != 0 { heights.append(currentMax) }
            return (columns, columnWidth, heights)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let availableWidth = proposal.width ?? minColumnWidth
            let metrics = measure(width: availableWidth, subviews: subviews)
            let rows = metrics.rowHeights
            let totalHeight = rows.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
            return CGSize(width: availableWidth, height: totalHeight)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let metrics = measure(width: bounds.width, subviews: subviews)
            let columns = metrics.columns
            let columnWidth = metrics.columnWidth
            let rowHeights = metrics.rowHeights

            var x = bounds.minX
            var y = bounds.minY
            var columnIndex = 0
            var rowIndex = 0

            for (idx, subview) in subviews.enumerated() {
                if columnIndex == columns {
                    columnIndex = 0
                    rowIndex += 1
                    x = bounds.minX
                    y += rowHeights[rowIndex - 1] + spacing
                }

                let proposedHeight = rowHeights[rowIndex]
                let proposed = ProposedViewSize(width: columnWidth, height: proposedHeight)
                let size = subview.sizeThatFits(proposed)
                // Place at top-left of the row area
                subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: columnWidth, height: proposedHeight)
                )

                columnIndex += 1
                x += columnWidth + spacing
                _ = size // keep for potential debug
                _ = idx
            }
        }
    }

    private struct LiveRAMUsageView: View {
        @State private var usageBytes: Int64 = 0
        @State private var budgetBytes: Int64? = ModelRAMAdvisor.currentMemoryBudgetSnapshot().bytes
        @State private var timer: Timer?

        private var progress: Double {
            guard let cap = budgetBytes, cap > 0 else { return 0 }
            return min(1.0, Double(usageBytes) / Double(cap))
        }

        private var color: Color {
            switch progress {
            case 0..<0.7: return .green
            case 0.7..<0.9: return .orange
            default: return .red
            }
        }

        private var usageText: String {
            ByteCountFormatter.string(fromByteCount: usageBytes, countStyle: .memory)
        }

        private var capText: String {
            if let cap = budgetBytes { return ByteCountFormatter.string(fromByteCount: cap, countStyle: .memory) }
            return "--"
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.2), lineWidth: 10)
                            .frame(width: 64, height: 64)
                        Circle()
                            .trim(from: 0, to: CGFloat(progress))
                            .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 64, height: 64)
                        Text("\(Int(progress * 100))%")
                            .font(FontTheme.caption)
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.text)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey("App Memory Usage"))
                            .font(FontTheme.body)
                            .foregroundStyle(AppTheme.text)
                        Text(String.localizedStringWithFormat(String(localized: "%@ of %@ budget"), usageText, capText))
                            .font(FontTheme.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Spacer()
                }
            }
            .onAppear { start() }
            .onDisappear { stop() }
#if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                Task { @MainActor in refresh() }
            }
#endif
            .accessibilityElement(children: .contain)
        }

        private func start() {
            Task { @MainActor in refresh() }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }

        private func stop() { timer?.invalidate(); timer = nil }

        private func refresh() {
            let bytes = Int64(c_app_memory_footprint())
            let budget = ModelRAMAdvisor.currentMemoryBudgetSnapshot().bytes
            withAnimation(.easeInOut(duration: 0.2)) {
                usageBytes = max(0, bytes)
                budgetBytes = budget
            }
        }
    }

#if os(iOS)
    private struct ThermalStateStageView: View {
        @State private var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

        private struct Stage: Identifiable {
            let state: ProcessInfo.ThermalState
            let title: LocalizedStringKey
            let color: Color

            var id: Int { state.rawValue }
        }

        private let stages: [Stage] = [
            Stage(state: .nominal, title: LocalizedStringKey("Nominal"), color: .green),
            Stage(state: .fair, title: LocalizedStringKey("Fair"), color: .yellow),
            Stage(state: .serious, title: LocalizedStringKey("Serious"), color: .orange),
            Stage(state: .critical, title: LocalizedStringKey("Critical"), color: .red)
        ]

        private var currentStage: Stage {
            stages.first(where: { $0.state == thermalState }) ?? stages[0]
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey("Thermal Stage"))
                    .font(FontTheme.body)
                    .fontWeight(.medium)
                    .foregroundStyle(AppTheme.text)

                HStack(spacing: 6) {
                    Circle()
                        .fill(currentStage.color)
                        .frame(width: 8, height: 8)
                    Text(currentStage.title)
                        .font(FontTheme.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(currentStage.color.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(currentStage.color.opacity(0.75), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .onAppear {
                thermalState = ProcessInfo.processInfo.thermalState
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                thermalState = ProcessInfo.processInfo.thermalState
            }
        }
    }
#endif

    private var modeSection: some View {
        Section { modeSettingsContent }
    }

    @ViewBuilder
    private var modeSettingsContent: some View {
        Picker(LocalizedStringKey("Mode"), selection: $settings.isAdvancedMode) {
            Text(LocalizedStringKey("Simple")).tag(false)
            Text(LocalizedStringKey("Advanced")).tag(true)
        }
#if os(macOS)
        .pickerStyle(.menu)
        .fixedSize()
#else
        .pickerStyle(.segmented)
#endif
        Text(modeExplanation)
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
    }

    private func memoryBudgetSummary(budgetText: String, isLiveProcessLimit: Bool) -> String {
        let key = isLiveProcessLimit
            ? "Current app memory budget: %@"
            : "App memory usage budget: %@ (conservative)"
        return String.localizedStringWithFormat(
            String(localized: String.LocalizationValue(key), locale: localizationManager.locale),
            budgetText
        )
    }

    private func ramMetrics() -> (info: DeviceRAMInfo, budgetText: String, budgetIsLive: Bool, model: LocalModel?, estimateText: String?) {
        let info = DeviceRAMInfo.current()
        let budgetSnapshot = ModelRAMAdvisor.currentMemoryBudgetSnapshot()
        let byteFormatter: ByteCountFormatter = {
            let f = ByteCountFormatter()
            f.allowedUnits = [.useGB, .useMB]
            f.countStyle = .memory
            return f
        }()
        let budgetText: String = {
            if let b = budgetSnapshot.bytes {
                return byteFormatter.string(fromByteCount: b)
            }
            let limitClean = info.limit.replacingOccurrences(of: "~", with: "").trimmingCharacters(in: .whitespaces)
            return limitClean
        }()
        // Choose model for estimate: explicit picker selection if set; else loaded; else default; else first
        let selectedPath = !estimateModelPath.isEmpty ? estimateModelPath : (modelManager.loadedModel?.url.path ?? (startupPreferences.localModelPath ?? ""))
        let modelForEstimate: LocalModel? = modelManager.downloadedModels.first(where: { $0.url.path == selectedPath }) ?? modelManager.loadedModel ?? modelManager.downloadedModels.first
        let estimateText: String? = {
            guard let m = modelForEstimate else { return nil }
            // Use saved settings for this model to pick context length
            let settings = modelManager.settings(for: m)
            let sizeBytes = Int64(m.sizeGB * 1_073_741_824.0)
            let ctx = Int(settings.contextLength)
            let layerHint: Int? = m.totalLayers > 0 ? m.totalLayers : nil
            let kvCacheEstimate = ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings)
            let (estimate, _) = ModelRAMAdvisor.estimateAndBudget(
                format: m.format,
                sizeBytes: sizeBytes,
                contextLength: ctx,
                layerCount: layerHint,
                moeInfo: m.moeInfo,
                kvCacheEstimate: kvCacheEstimate,
                runtimeConfiguration: .resolved(from: settings, modelURL: m.url)
            )
            return byteFormatter.string(fromByteCount: estimate)
        }()
        return (info, budgetText, budgetSnapshot.isLiveProcessLimit, modelForEstimate, estimateText)
    }

    private var ramSection: some View {
        let metrics = ramMetrics()
        return Section { ramSettingsContent(info: metrics.info,
                                            budgetText: metrics.budgetText,
                                            budgetIsLive: metrics.budgetIsLive,
                                            modelForEstimate: metrics.model,
                                            estimateText: metrics.estimateText) }
    }

    @ViewBuilder
    private func ramSettingsContent(info: DeviceRAMInfo,
                                    budgetText: String,
                                    budgetIsLive: Bool,
                                    modelForEstimate: LocalModel?,
                                    estimateText: String?) -> some View {
        GroupBox {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: info.modelName)
                        .font(FontTheme.body)
                        .fontWeight(.medium)
                        .foregroundStyle(AppTheme.text)
                    Text(verbatim: memoryBudgetSummary(
                        budgetText: budgetText,
                        isLiveProcessLimit: budgetIsLive
                    ))
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    if let m = modelForEstimate, let est = estimateText {
                        // Clarify which model and context length the estimate refers to
                        let ctx = Int(modelManager.settings(for: m).contextLength)
                        let ctxFormatter: NumberFormatter = {
                            let nf = NumberFormatter()
                            nf.locale = localizationManager.locale
                            nf.numberStyle = .decimal
                            return nf
                        }()
                        let ctxString = ctxFormatter.string(from: NSNumber(value: ctx)) ?? "\(ctx)"
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "Working set estimate (%@): %@ @ %@ tokens", locale: localizationManager.locale),
                                    m.name,
                                    est,
                                    ctxString
                            )
                        )
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    }
                    if info.limit == "--" {
                        Text(LocalizedStringKey("RAM information for this device will be added in a future update."))
                            .font(FontTheme.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                Spacer()
                Button(action: { showRAMInfo = true }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                        .font(.system(size: 20))
                }
            }
            .padding(4)
        }
        if settings.isAdvancedMode {
#if os(iOS)
            ThermalStateStageView()
#endif
            // Quick estimator: choose a model to preview its working set without changing defaults
            if !modelManager.downloadedModels.isEmpty {
                Picker(LocalizedStringKey("Estimate for"), selection: $estimateModelPath) {
                    ForEach(modelManager.downloadedModels, id: \.url) { m in
                        Text(m.name).tag(m.url.path)
                    }
                }
                .onAppear {
                    if estimateModelPath.isEmpty {
                        estimateModelPath = modelForEstimate?.url.path ?? (startupPreferences.localModelPath ?? "")
                    }
                }
            }
            LiveRAMUsageView()
        }
    }

    private var startupSection: some View {
        Section(LocalizedStringKey("Startup")) { startupSettingsContent }
    }

    private var hiddenModelsSection: some View {
        Section(LocalizedStringKey("Hidden Models")) { hiddenModelsContent }
    }

    @ViewBuilder
    private var hiddenModelsContent: some View {
        ForEach(modelManager.hiddenModels, id: \.id) { model in
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .foregroundStyle(AppTheme.text)
                    Text(model.format.displayName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(model.format.tagGradient)
                        .clipShape(Capsule())
                        .foregroundColor(.white)
                }
                Spacer()
                Button(LocalizedStringKey("Show in Stored")) {
                    modelManager.unhide(modelID: model.modelID, quantLabel: model.quant)
                    refreshStartupPreferences()
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var startupSettingsContent: some View {
        startupRoutingAdviceRow
        localStartupPicker
        remoteStartupConfigurator
        priorityControls
    }

    private var startupRoutingAdviceRow: some View {
        let advice = LocalRemoteRoutingAdvisor.advice(
            for: LocalRemoteRoutingAdvisor.Context(
                preferences: startupPreferences,
                selectedLocalModel: startupSelectedLocalModel.map(LocalRemoteRoutingAdvisor.LocalModelSummary.init(model:)),
                remoteSelectionCount: startupPreferences.remoteSelections.count,
                offGrid: settings.offGrid
            )
        )
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: startupRoutingIcon(for: advice))
                .font(.headline.weight(.semibold))
                .foregroundStyle(startupRoutingTint(for: advice))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(startupRoutingTitle(for: advice))
                    .font(FontTheme.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.text)
                Text(startupRoutingDetail(for: advice))
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var startupSelectedLocalModel: LocalModel? {
        guard let path = startupPreferences.localModelPath else { return nil }
        return modelManager.downloadedModels.first { $0.url.path == path }
    }

    private func startupRoutingIcon(for advice: LocalRemoteRoutingAdvice) -> String {
        switch advice.route {
        case .unconfigured:
            return "questionmark.circle"
        case .localOnly:
            return "iphone"
        case .remoteOnly:
            return "network"
        case .localThenRemote:
            return "iphone.and.arrow.forward"
        case .remoteThenLocal:
            return "network.badge.shield.half.filled"
        case .blocked:
            return "wifi.slash"
        }
    }

    private func startupRoutingTint(for advice: LocalRemoteRoutingAdvice) -> Color {
        switch advice.route {
        case .unconfigured:
            return .secondary
        case .localOnly, .localThenRemote:
            return .green
        case .remoteOnly, .remoteThenLocal:
            return .blue
        case .blocked:
            return .orange
        }
    }

    private func startupRoutingTitle(for advice: LocalRemoteRoutingAdvice) -> LocalizedStringKey {
        switch advice.route {
        case .unconfigured:
            return "No startup route"
        case .localOnly:
            return "Local route"
        case .remoteOnly:
            return "Remote route"
        case .localThenRemote:
            return "Local, then remote"
        case .remoteThenLocal:
            return "Remote, then local"
        case .blocked:
            return "Route blocked"
        }
    }

    private func startupRoutingDetail(for advice: LocalRemoteRoutingAdvice) -> LocalizedStringKey {
        switch advice.detail {
        case .noDefaults:
            return "Pick a local or remote default so Noema knows where to start."
        case .offGridLocal:
            return "Off-Grid is on, so remote defaults are skipped and the local model stays first."
        case .offGridNoLocal:
            return "Off-Grid is on and no local default is selected, so startup will not use remote compute."
        case .localOnly:
            return "Startup stays on device unless you manually choose a remote backend."
        case .remoteOnly:
            return "Startup uses the selected remote backend and needs network access."
        case .localPriority:
            return "Your local default is tried first; remote is a fallback if local loading fails."
        case .remotePriority:
            return "Your remote default is tried first; local is a fallback if the network or backend fails."
        case .largeLocalRemoteFallback:
            return "The local GGUF is large, so remote fallback is useful when memory or battery is tight."
        case .lowPowerLocalEfficient:
            return "Low Power Mode favors the efficient local model before remote networking."
        }
    }

    // MARK: - Autopilot

    private var autopilotStatusText: String {
        guard autopilotConfig.isReadyToArm else {
            return String(localized: "Not Set Up")
        }
        return modelManager.autoRoutingArmed ? String(localized: "On") : String(localized: "Off")
    }

    private var autopilotStatusTint: Color {
        guard autopilotConfig.isReadyToArm else { return .orange }
        return modelManager.autoRoutingArmed ? .green : .secondary
    }

    private var autopilotRouterDetailText: String {
        if autopilotConfig.routerKind == .appleFoundationModel {
            return String(localized: "Apple Intelligence (on-device)")
        }
        if autopilotConfig.routerKind == .privateCloudCompute {
            return AppleFoundationModelKind.privateCloudCompute.modelName
        }
        guard let selection = autopilotConfig.routerSelection else { return String(localized: "Not Set Up") }
        return "\(selection.backendName) · \(selection.modelName)"
    }

    private var autopilotCloudDetailText: String {
        if autopilotConfig.escalationTarget == .localModel {
            guard let local = autopilotConfig.localEscalation else { return String(localized: "Not Set Up") }
            return String(localized: "On this Mac · \(local.name)")
        }
        if autopilotConfig.escalationTarget == .privateCloudCompute {
            return AppleFoundationModelKind.privateCloudCompute.modelName
        }
        guard let selection = autopilotConfig.escalationSelection else { return String(localized: "Not Set Up") }
        return "\(selection.backendName) · \(selection.modelName)"
    }

    private var autopilotEnergySavedText: String {
        String(format: "%.1f Wh", autopilotLedger.totals.whSaved)
    }

    private var autopilotUSDSavedText: String {
        String(format: "$%.2f", autopilotLedger.totals.usdSaved)
    }

    private func updateAutopilotConfig(_ mutate: (inout AutopilotConfig) -> Void) {
        var config = AutopilotConfigStore.load()
        mutate(&config)
        AutopilotConfigStore.save(config)
        autopilotConfig = config
        AutopilotAFMBrain.syncWarmState(armed: modelManager.autoRoutingArmed)
    }

    private var autopilotAggressivenessBinding: Binding<RouterAggressiveness> {
        Binding(
            get: { autopilotConfig.aggressiveness },
            set: { newValue in updateAutopilotConfig { $0.aggressiveness = newValue } }
        )
    }

    private var autopilotPauseBinding: Binding<Bool> {
        Binding(
            get: { autopilotConfig.pauseCloudEscalation },
            set: { newValue in updateAutopilotConfig { $0.pauseCloudEscalation = newValue } }
        )
    }

    private var autopilotRAGBinding: Binding<Bool> {
        Binding(
            get: { autopilotConfig.allowCloudForRAGTurns },
            set: { newValue in updateAutopilotConfig { $0.allowCloudForRAGTurns = newValue } }
        )
    }

    private var autopilotSystemBinding: Binding<AutopilotSystem> {
        Binding(
            get: { autopilotConfig.system },
            set: { newValue in
                updateAutopilotConfig { $0.system = newValue }
                // The two systems have different readiness requirements; a
                // half-configured switch must not leave Autopilot armed.
                if modelManager.autoRoutingArmed && !autopilotConfig.isReadyToArm {
                    modelManager.autoRoutingArmed = false
                }
            }
        )
    }

    private func turnOffAutopilot() {
        modelManager.autoRoutingArmed = false
        autopilotConfig = AutopilotConfigStore.load()
    }

    @ViewBuilder
    private var autopilotSettingsContent: some View {
#if os(macOS)
        macAutopilotSettingsContent
#else
        touchAutopilotSettingsContent
#endif
    }

#if !os(macOS)
    @ViewBuilder
    private var touchAutopilotSettingsContent: some View {
        // Shared with the Stored list's Autopilot row (AutopilotSettingsSheet).
        AutopilotSettingsPanel(setupMode: $autopilotSetupMode)
    }
#else
    private var macAutopilotSettingsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            MacSettingsCard(LocalizedStringKey("Autopilot")) {
                MacSettingsStatusRow(title: LocalizedStringKey("Autopilot"),
                                     value: autopilotStatusText,
                                     systemImage: "arrow.triangle.branch",
                                     tint: autopilotStatusTint,
                                     divider: false)
                MacSettingsControlRow(LocalizedStringKey("System")) {
                    Picker("", selection: autopilotSystemBinding) {
                        Text(LocalizedStringKey("Smart Router")).tag(AutopilotSystem.router)
                        Text(LocalizedStringKey("Phone a Friend")).tag(AutopilotSystem.phoneAFriend)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }
                MacSettingsNoteRow(autopilotConfig.system == .router
                                   ? (autopilotConfig.routerKind == .appleFoundationModel
                                      ? LocalizedStringKey("Routes on-device. Nothing is sent anywhere to decide.")
                                      : (autopilotConfig.routerKind == .privateCloudCompute
                                         ? LocalizedStringKey("Apple Private Cloud Compute privately decides where each message runs.")
                                         : LocalizedStringKey("A small cloud router reads each message and decides where it runs.")))
                                   : LocalizedStringKey("Your on-device model answers everything and calls for the stronger model only when a request is beyond it. Needs a tool-capable local model."),
                                   divider: false)
                if autopilotConfig.system == .router {
                    MacSettingsControlRow(LocalizedStringKey("Router")) {
                        HStack(spacing: 10) {
                            Text(verbatim: autopilotRouterDetailText)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.8))
                                .lineLimit(1)
                            Button {
                                autopilotSetupMode = .router
                            } label: {
                                Text(LocalizedStringKey("Change…"))
                            }
                            .buttonStyle(.industrial(.quiet))
                        }
                    }
                }
                MacSettingsControlRow(LocalizedStringKey("Stronger Model")) {
                    HStack(spacing: 10) {
                        Text(verbatim: autopilotCloudDetailText)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .lineLimit(1)
                        Button {
                            autopilotSetupMode = .strongerModel
                        } label: {
                            Text(LocalizedStringKey("Change…"))
                        }
                        .buttonStyle(.industrial(.quiet))
                    }
                }
            }

            MacSettingsCard(LocalizedStringKey("Escalation")) {
                if autopilotConfig.system == .router {
                    MacSettingsControlRow(LocalizedStringKey("Escalation"), divider: false) {
                        Picker("", selection: autopilotAggressivenessBinding) {
                            Text(LocalizedStringKey("Conserve")).tag(RouterAggressiveness.conserve)
                            Text(LocalizedStringKey("Balanced")).tag(RouterAggressiveness.balanced)
                            Text(LocalizedStringKey("Frontier")).tag(RouterAggressiveness.frontier)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 280)
                    }
                    MacSettingsNoteRow(LocalizedStringKey("Conserve keeps almost everything on-device. Frontier escalates whenever quality would clearly benefit."), divider: false)
                }
                MacSettingsControlRow(LocalizedStringKey("Pause cloud escalation")) {
                    Toggle("", isOn: autopilotPauseBinding)
                        .labelsHidden()
                        .toggleStyle(IndustrialToggleStyle())
                }
                MacSettingsNoteRow(autopilotConfig.system == .router
                                   ? LocalizedStringKey("The router still runs; every answer stays on-device.")
                                   : LocalizedStringKey("The hand-off tool is withheld; every answer stays on-device."),
                                   divider: false)
                MacSettingsControlRow(LocalizedStringKey("Allow escalation for knowledge-base chats")) {
                    Toggle("", isOn: autopilotRAGBinding)
                        .labelsHidden()
                        .toggleStyle(IndustrialToggleStyle())
                }
                MacSettingsNoteRow(LocalizedStringKey("Escalated answers include retrieved document excerpts."), divider: false)
            }

            MacSettingsCard(LocalizedStringKey("Statistics")) {
                MacSettingsKeyValueRow(title: LocalizedStringKey("answers routed"),
                                       value: "\(autopilotLedger.totals.totalTurns)",
                                       divider: false)
                MacSettingsKeyValueRow(title: LocalizedStringKey("on-device answers"),
                                       value: "\(autopilotLedger.totals.localTurns)")
                MacSettingsKeyValueRow(title: LocalizedStringKey("cloud answers"),
                                       value: "\(autopilotLedger.totals.cloudTurns)")
                MacSettingsKeyValueRow(title: LocalizedStringKey("overrides"),
                                       value: "\(autopilotLedger.totals.overrides)")
                MacSettingsKeyValueRow(title: LocalizedStringKey("≈ energy saved"),
                                       value: autopilotEnergySavedText)
                if autopilotLedger.totals.usdSaved > 0 {
                    MacSettingsKeyValueRow(title: LocalizedStringKey("≈ saved"),
                                           value: autopilotUSDSavedText)
                }
                MacSettingsNoteRow(LocalizedStringKey("Energy savings are an estimate (≈) based on typical per-token energy for your cloud model versus this device. Not a measurement."))
            }

            if modelManager.autoRoutingArmed {
                Button {
                    turnOffAutopilot()
                } label: {
                    Text(LocalizedStringKey("Turn Off Autopilot"))
                }
                .buttonStyle(.industrial(.destructive))
            }
        }
    }
#endif

    private var ramBypassSection: some View {
        Section { ramBypassContent }
    }

    @ViewBuilder
    private var ramBypassContent: some View {
        Toggle(LocalizedStringKey("Bypass RAM safety check (may cause crashes)"), isOn: $settings.bypassRAMCheck)
        Text(LocalizedStringKey("If enabled, the app will attempt to load models even when they likely exceed your device's memory budget. This can cause the app to terminate."))
            .foregroundStyle(AppTheme.secondaryText)
    }

    private var offGridSection: some View {
        Section { offGridContent }
    }

    private var enterpriseSection: some View {
        Section(LocalizedStringKey("Enterprise")) { enterpriseRow }
    }

    private var enterpriseCard: some View {
        SettingsCard(title: LocalizedStringKey("Enterprise"), icon: "building.2") {
            enterpriseRow
        }
    }

    private var enterpriseRow: some View {
        Button {
            settingsDestination = .enterprise
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "building.2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(enterpriseStatusTint)
                    .frame(width: 30, height: 30)
                    .background(enterpriseStatusTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    if case .connected = enterpriseManager.state, let policy = enterpriseManager.policy {
                        Text(verbatim: policy.tenantName)
                            .font(FontTheme.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(AppTheme.text)
                    } else {
                        Text(LocalizedStringKey("Enterprise"))
                            .font(FontTheme.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(AppTheme.text)
                    }
                    enterpriseStatusSubtitle
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// iPhone settings card (the iPhone layout uses SettingsSurfaceCard rows).
    /// Shared by iOS and visionOS, which now use the same card/navigation layout.
#if os(iOS) || os(visionOS)
    private var enterpriseOverviewCard: some View {
        SettingsSurfaceCard {
            Button {
                settingsDestination = .enterprise
            } label: {
                SettingsNavigationRow(
                    title: enterpriseRowTitle,
                    subtitle: enterpriseRowSubtitle,
                    leadingSystemImage: "building.2",
                    leadingTint: enterpriseStatusTint
                )
            }
            .buttonStyle(.plain)
        }
    }
#endif

    private var enterpriseRowTitle: Text {
        if enterpriseManager.state.isEnrolledOnDevice, let policy = enterpriseManager.policy {
            return Text(verbatim: policy.tenantName)
        }
        return Text("Connect to company")
    }

    private var enterpriseRowSubtitle: Text? {
        switch enterpriseManager.state {
        case .none, .disconnected:
            return nil
        case .connecting:
            return Text("Connecting…")
        case .awaitingEmailVerification:
            return Text("Awaiting email verification")
        case .pendingApproval:
            return Text("Pending admin approval")
        case .connected:
            return Text("Connected — policy active")
        case .policyExpired:
            return Text("Connected — policy expired")
        case .deviceRevoked:
            return Text("Device access revoked")
        case .policyInvalid:
            return Text("Policy could not be verified")
        }
    }

    private var enterpriseStatusTint: Color {
        switch enterpriseManager.state {
        case .connected: return .green
        case .policyExpired, .pendingApproval, .awaitingEmailVerification, .connecting: return .orange
        case .deviceRevoked, .policyInvalid: return .red
        case .none, .disconnected: return .secondary
        }
    }

    @ViewBuilder
    private var enterpriseStatusSubtitle: some View {
        switch enterpriseManager.state {
        case .none, .disconnected:
            Text(LocalizedStringKey("Connect to company"))
        case .connecting:
            Text(LocalizedStringKey("Connecting…"))
        case .awaitingEmailVerification:
            Text(LocalizedStringKey("Awaiting email verification"))
        case .pendingApproval:
            Text(LocalizedStringKey("Pending admin approval"))
        case .connected:
            Text(LocalizedStringKey("Connected — policy active"))
        case .policyExpired:
            Text(LocalizedStringKey("Connected — policy expired"))
        case .deviceRevoked:
            Text(LocalizedStringKey("Device access revoked"))
        case .policyInvalid:
            Text(LocalizedStringKey("Policy could not be verified"))
        }
    }

#if os(iOS)
    private var walletPassSection: some View {
        Section(LocalizedStringKey("Wallet Passes")) { walletPassContent }
            .confirmationDialog(LocalizedStringKey("Delete All Saved Passes"), isPresented: $confirmDeleteWalletPassDrafts, titleVisibility: .visible) {
                Button(LocalizedStringKey("Delete All Saved Passes"), role: .destructive) {
                    boardingPassDraftStore.deleteAll()
                    confirmDeleteWalletPassDrafts = false
                }
                Button(LocalizedStringKey("Cancel"), role: .cancel) {
                    confirmDeleteWalletPassDrafts = false
                }
            } message: {
                Text(LocalizedStringKey("This permanently removes every saved Wallet pass draft and any stored scan images. This action cannot be undone."))
            }
    }

    @ViewBuilder
    private var walletPassContent: some View {
        Button {
            settingsDestination = .passExtractionModel
        } label: {
            SettingsNavigationRow(
                title: Text("Pass Extraction Model"),
                subtitle: Text("Choose the local vision model used to read tickets."),
                trailingText: Text(activePassExtractionModelName),
                leadingSystemImage: "viewfinder",
                leadingTint: .accentColor,
                titleColor: .accentColor
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.accentColor.opacity(0.08))

        Label(LocalizedStringKey("Wallet signing requires internet access and uses Noema’s hosted signer automatically."), systemImage: "network")
            .foregroundStyle(AppTheme.text)

        Toggle(LocalizedStringKey("Keep scans with drafts"), isOn: $settings.walletPassKeepScansWithDrafts)

        if boardingPassDraftStore.drafts.isEmpty {
            Text(LocalizedStringKey("No saved Wallet passes"))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.secondaryText)
        } else {
            Button(role: .destructive) {
                confirmDeleteWalletPassDrafts = true
            } label: {
                SettingsNavigationRow(
                    title: Text("Delete All Saved Passes"),
                    subtitle: Text(String.localizedStringWithFormat(String(localized: "%d saved Wallet passes"), boardingPassDraftStore.drafts.count)),
                    leadingSystemImage: "trash",
                    leadingTint: .red,
                    titleColor: .red,
                    showsChevron: false
                )
            }
            .buttonStyle(.plain)
        }

        Picker(LocalizedStringKey("Warning Sensitivity"), selection: $settings.walletPassWarningSensitivity) {
            Text(LocalizedStringKey("Relaxed")).tag("relaxed")
            Text(LocalizedStringKey("Balanced")).tag("balanced")
            Text(LocalizedStringKey("Strict")).tag("strict")
        }

        Text(LocalizedStringKey("Pass extraction runs on device with the selected local vision model. Adding the pass to Wallet requires internet access for Noema’s signer and sends only the confirmed draft JSON, not the scan image."))
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
    }

    private var activePassExtractionModelName: String {
        let hasSelection = !settings.walletPassActiveExtractionModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !settings.walletPassActiveExtractionModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasSelection else { return String(localized: "Required") }
        if let model = PassExtractionModelCatalog.activeModel(from: modelManager.downloadedModels) {
            return model.name
        }
        let fallbackName = settings.walletPassActiveExtractionModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackName.isEmpty ? String(localized: "Missing") : fallbackName
    }
#endif

    @ViewBuilder
    private var offGridContent: some View {
        Toggle(LocalizedStringKey("Off-grid Mode"), isOn: $settings.offGrid)
            .id(ScrollTarget.offGrid)
            .guideHighlight(.settingsOffGrid)
            .disabled(EnterprisePolicyGate.requiresOffGrid)
            .onChange(of: settings.offGrid) { on in
                NetworkKillSwitch.setEnabled(on)
            }
        Text(LocalizedStringKey("Blocks all network traffic, model downloads, and cloud connections so everything stays on‑device."))
            .foregroundStyle(AppTheme.secondaryText)
        if EnterprisePolicyGate.requiresOffGrid {
            Text(LocalizedStringKey("Required by your organization's policy. Only your workspace's policy server can be reached."))
                .foregroundStyle(.orange)
        }
    }

    private var localStartupPicker: some View {
        Group {
            if modelManager.downloadedModels.isEmpty {
                Text(LocalizedStringKey("Install a local model to make it available at launch."))
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                Picker(LocalizedStringKey("Local default"), selection: Binding(
                    get: { startupPreferences.localModelPath ?? "" },
                    set: { newValue in
                        updateStartupPreferences { prefs in
                            prefs.localModelPath = newValue.isEmpty ? nil : newValue
                        }
                    }
                )) {
                    Text(LocalizedStringKey("None")).tag("")
                    ForEach(modelManager.downloadedModels, id: \.url) { model in
                        Text(model.name).tag(model.url.path)
                    }
                }
            }
        }
    }

    private var remoteStartupConfigurator: some View {
        Group {
            if modelManager.remoteBackends.isEmpty {
                Text(LocalizedStringKey("Add a remote backend to configure remote startup fallbacks."))
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(startupPreferences.remoteSelections.enumerated()), id: \.element.id) { index, selection in
                        StartupRemoteRow(
                            selection: Binding(
                                get: { startupPreferences.remoteSelections[index] },
                                set: { updated in
                                    updateStartupPreferences { prefs in
                                        prefs.remoteSelections[index] = updated
                                    }
                                }
                            ),
                            backend: modelManager.remoteBackends.first(where: { $0.id == selection.backendID }),
                            canMoveUp: index > 0,
                            canMoveDown: index < startupPreferences.remoteSelections.count - 1,
                            moveUp: { moveRemoteSelection(from: index, to: index - 1) },
                            moveDown: { moveRemoteSelection(from: index, to: index + 1) },
                            remove: { removeRemoteSelection(at: index) }
                        )
                    }
                    if let available = availableRemoteBackends, !available.isEmpty {
                        Menu {
                            ForEach(available, id: \.id) { backend in
                                Button(backend.name) {
                                    addRemoteSelection(for: backend)
                                }
                            }
                        } label: {
                            Label(LocalizedStringKey("Add remote default"), systemImage: "plus")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var priorityControls: some View {
        // Only render this block when there is at least one
        // remote selection; otherwise an empty container would
        // create a blank row with a divider in the Section.
        if startupPreferences.hasRemoteSelection {
            VStack(alignment: .leading, spacing: 12) {
                if startupPreferences.hasLocalSelection {
                    Picker(LocalizedStringKey("When both are available"), selection: Binding(
                        get: { startupPreferences.priority },
                        set: { newValue in updateStartupPreferences { $0.priority = newValue } }
                    )) {
                        ForEach(StartupPreferences.Priority.allCases) { priority in
                            Text(priority.title).tag(priority)
                        }
                    }
#if os(macOS)
                    .pickerStyle(.menu)
                    .fixedSize()
#else
                    .pickerStyle(.segmented)
#endif
                }

                Stepper(value: Binding(
                    get: { startupPreferences.remoteTimeout },
                    set: { newValue in updateStartupPreferences { $0.remoteTimeout = newValue } }
                ), in: StartupPreferences.minTimeout...StartupPreferences.maxTimeout, step: 1) {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Remote timeout: %ds"),
                            Int(startupPreferences.remoteTimeout)
                        )
                    )
                }
                Text(LocalizedStringKey("We'll try remote models in priority order for this long before moving to the next option."))
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private var availableRemoteBackends: [RemoteBackend]? {
        let used = Set(startupPreferences.remoteSelections.map { $0.backendID })
        let filtered = modelManager.remoteBackends.filter { !used.contains($0.id) }
        return filtered.isEmpty ? nil : filtered
    }

    private func addRemoteSelection(for backend: RemoteBackend) {
        let initialModel = backend.cachedModels.first
        let selection = StartupPreferences.RemoteSelection(
            backendID: backend.id,
            backendName: backend.name,
            modelID: initialModel?.id ?? "",
            modelName: initialModel?.name ?? "",
            relayRecordName: initialModel?.relayRecordName
        )
        updateStartupPreferences { prefs in
            prefs.remoteSelections.append(selection)
        }
    }

    private func moveRemoteSelection(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < startupPreferences.remoteSelections.count,
              destination >= 0, destination < startupPreferences.remoteSelections.count else { return }
        updateStartupPreferences { prefs in
            let item = prefs.remoteSelections.remove(at: source)
            prefs.remoteSelections.insert(item, at: destination)
        }
    }

    private func removeRemoteSelection(at index: Int) {
        guard index >= 0, index < startupPreferences.remoteSelections.count else { return }
        updateStartupPreferences { prefs in
            prefs.remoteSelections.remove(at: index)
        }
    }

    private func updateStartupPreferences(_ mutate: (inout StartupPreferences) -> Void) {
        var updated = startupPreferences
        mutate(&updated)
        updated.normalize()
        startupPreferences = updated
        StartupPreferencesStore.save(updated)
    }

    private func refreshStartupPreferences() {
        let latest = StartupPreferencesStore.load()
        let sanitized = StartupPreferencesStore.sanitize(preferences: latest,
                                                         models: modelManager.downloadedModels,
                                                         backends: modelManager.remoteBackends)
        if sanitized != startupPreferences {
            startupPreferences = sanitized
        } else if latest != startupPreferences {
            startupPreferences = sanitized
        }
    }

    private var embeddingSection: some View {
        Section(LocalizedStringKey("Embedding Model")) { embeddingContent }
    }

    @ViewBuilder
    private var embeddingContent: some View {
        let activeRecord = EmbeddingModelCatalog.activeRecord()
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(activeRecord.displayName)
                    .font(FontTheme.body)
                    .foregroundStyle(AppTheme.text)
                Text(LocalizedStringKey("Dataset search quality and indexing"))
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
            Image(systemName: embedAvailable ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(embedAvailable ? .green : AppTheme.secondaryText)
                .imageScale(.large)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showEmbeddingModels = true
        }
        // Expose the whole row as one labelled button. The checkmark.circle.fill
        // accessory otherwise let VoiceOver read the row as a selected table cell;
        // status now rides in the accessibility value instead.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: activeRecord.displayName))
        .accessibilityValue(Text(embedAvailable ? LocalizedStringKey("Embedding model downloaded") : LocalizedStringKey("Embedding model missing")))
        // Keep swipe-to-delete on iOS, but provide explicit button on macOS where swiping is awkward
        .modifier(EmbeddingSwipeModifier(embedAvailable: embedAvailable, onDelete: deleteEmbeddingModel))

        Button {
            showEmbeddingModels = true
        } label: {
            Label(LocalizedStringKey("Change Embedding Model"), systemImage: "square.stack.3d.up")
        }
#if os(macOS)
        .buttonStyle(.industrial(.tinted))
#else
        .buttonStyle(GlassButtonStyle())
#endif

        Group {
            if embedAvailable {
#if os(macOS)
                // macOS: explicit destructive button instead of swipe
                Button(role: .destructive) {
                    deleteEmbeddingModel()
                } label: {
                    Label(LocalizedStringKey("Delete Embedding Model"), systemImage: "trash")
                }
                .buttonStyle(.industrial(.destructive))
                .padding(.top, 6)
                Text(LocalizedStringKey("The embedding model is installed. Delete it to free ~640 MB."))
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.top, 2)
#else
                Text(LocalizedStringKey("Swipe left to remove the embedding model from this device."))
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.top, 4)
#endif
            } else {
                // Not installed: mirror onboarding's installer flow
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        startEmbeddingDownloadFromSettings()
                    } label: {
                        if case .downloading = embedInstaller.state {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(LocalizedStringKey("Downloading…"))
                            }
                        } else if case .verifying = embedInstaller.state {
                            Label(LocalizedStringKey("Verifying…"), systemImage: "checkmark.shield")
                        } else if case .installing = embedInstaller.state {
                            Label(LocalizedStringKey("Installing…"), systemImage: "square.and.arrow.down.on.square")
                        } else {
                            Label(LocalizedStringKey("Download Embedding Model"), systemImage: "arrow.down.circle.fill")
                        }
                    }
#if os(macOS)
                    .buttonStyle(.industrial(.prominent))
#else
                    .buttonStyle(GlassButtonStyle())
#endif
                    .disabled(embedInstaller.state == .downloading || embedInstaller.state == .verifying || embedInstaller.state == .installing)

                    if embedInstaller.progress > 0 && embedInstaller.progress < 1 {
                        DownloadProgressCluster(progress: embedInstaller.progress)
                            .frame(maxWidth: 280)
                    }
                    Text(LocalizedStringKey("640 MB • One‑time download used for local dataset search"))
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(.top, 6)
            }
        }
    }

    private var generalSection: some View {
        Section(LocalizedStringKey("General")) { generalContent }
    }

    @ViewBuilder
    private var generalContent: some View {
#if os(visionOS)
        Toggle(LocalizedStringKey("Show vertical workspace"), isOn: $settings.visionVerticalPanelLayout)
        Text(LocalizedStringKey("Swap between the new stacked chat panel and the classic tab bar layout."))
            .foregroundStyle(AppTheme.secondaryText)
#endif

        Picker(LocalizedStringKey("Appearance"), selection: $settings.appearance) {
            Text(LocalizedStringKey("System")).tag("system")
            Text(LocalizedStringKey("Light")).tag("light")
            Text(LocalizedStringKey("Dark")).tag("dark")
        }

        if settings.isAdvancedMode {
            Picker(
                LocalizedStringKey("Context Overflow"),
                selection: Binding(
                    get: { ContextOverflowStrategy.from(settings.contextOverflowStrategyRaw) },
                    set: { settings.contextOverflowStrategyRaw = $0.rawValue }
                )
            ) {
                ForEach(ContextOverflowStrategy.allCases) { strategy in
                    Text(LocalizedStringKey(strategy.titleKey)).tag(strategy)
                }
            }
            Text(LocalizedStringKey(ContextOverflowStrategy.from(settings.contextOverflowStrategyRaw).settingsDescriptionKey))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }

#if os(iOS)
        Toggle(LocalizedStringKey("Haptics"), isOn: $settings.hapticsEnabled)
        Toggle(LocalizedStringKey("Compact Chat Mode"), isOn: $settings.compactChatModeEnabled)

        Picker(
            LocalizedStringKey("Return Key Behavior"),
            selection: Binding(
                get: { ChatSendBehavior.from(settings.chatSendBehaviorRaw) },
                set: { settings.chatSendBehaviorRaw = $0.rawValue }
            )
        ) {
            ForEach(ChatSendBehavior.allCases) { behavior in
                Text(LocalizedStringKey(behavior.titleKey)).tag(behavior)
            }
        }
        Text(LocalizedStringKey(ChatSendBehavior.from(settings.chatSendBehaviorRaw).settingsDescriptionKey))
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
#endif

        Toggle(LocalizedStringKey("Mute Sound Effects"), isOn: $settings.muteSoundEffects)

#if os(iOS)
        Toggle(LocalizedStringKey("Play Sound Effects in Silent Mode"), isOn: $settings.playSoundEffectsInSilentMode)
#endif

        Picker(LocalizedStringKey("Language"), selection: $selectedLanguageCode) {
            ForEach(languageOptions, id: \.code) { option in
                Text(option.name).tag(option.code)
            }
        }
        .onChange(of: selectedLanguageCode) { newValue in
            localizationManager.updateLanguage(code: newValue)
        }

        systemPromptIntroEditor

#if canImport(UIKit)
        Button(LocalizedStringKey("Reopen Onboarding")) {
            reopenOnboarding()
        }
#elseif os(macOS)
        Button(LocalizedStringKey("Reopen Onboarding")) {
            reopenOnboarding()
        }
#endif
    }

    private func reopenOnboarding() {
        triggerImpact(.medium)
#if canImport(UIKit)
        showOnboarding = true
#elseif os(macOS)
        showMacOnboarding = true
#endif
    }

    private var earlyTestersSection: some View {
        Section(LocalizedStringKey("Early Testers")) { earlyTestersContent }
    }

    @ViewBuilder
    private var earlyTestersContent: some View {
        Link(LocalizedStringKey("Join Early Testers"), destination: URL(string: "https://noemaai.com/early-testers")!)
        Text(LocalizedStringKey("Help shape Noema by trying upcoming features and sharing feedback."))
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
    }

    // Provides iOS-only swipe actions while doing nothing on macOS
    private struct EmbeddingSwipeModifier: ViewModifier {
        let embedAvailable: Bool
        let onDelete: () -> Void

        func body(content: Content) -> some View {
#if os(iOS)
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if embedAvailable {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
#else
            content
#endif
        }
    }

    @ViewBuilder
    private var systemPromptIntroEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey("System Prompt"))
                .font(FontTheme.body)
                .fontWeight(.medium)
                .foregroundStyle(AppTheme.text)

            TextEditor(text: $settings.customSystemPromptIntro)
                .font(FontTheme.body)
                .focused($systemPromptFocused)
                .frame(minHeight: 150)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.cardStroke, lineWidth: 1)
                )
#if os(iOS)
                .scrollContentBackground(.hidden)
#endif

            Button(LocalizedStringKey("Reset to Default")) {
                triggerImpact(.medium)
                confirmResetSystemPrompt = true
            }
            .tint(.red)
        }
#if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(LocalizedStringKey("Done")) {
                    systemPromptFocused = false
                    hideKeyboard()
                }
            }
        }
#endif
    }

    private var privacySection: some View {
        Section(LocalizedStringKey("Privacy")) { privacyContent }
    }

    private var privacyFlightSection: some View {
        Section(LocalizedStringKey("Privacy")) {
            Button {
                settingsDestination = .privacyFlight
            } label: {
                Label(LocalizedStringKey("Privacy Flight Recorder"), systemImage: "lock.shield")
            }
            Text(LocalizedStringKey("Review local, remote, network, and tool-state privacy receipts."))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private var speechASRSection: some View {
        Section(LocalizedStringKey("Speech & ASR")) { transcriptionSettingsContent }
    }

    @ViewBuilder
    private var chatCleanupContent: some View {
        Picker(
            LocalizedStringKey("Chat Image Cleanup"),
            selection: Binding(
                get: { ChatAttachmentCleanupPolicy.from(settings.chatAttachmentCleanupPolicyRaw) },
                set: { newPolicy in
                    settings.chatAttachmentCleanupPolicyRaw = newPolicy.rawValue
                    if newPolicy != .never {
                        chatVM.runAttachmentGarbageCollectionNow()
                    }
                }
            )
        ) {
            ForEach(ChatAttachmentCleanupPolicy.allCases) { policy in
                Text(LocalizedStringKey(policy.titleKey)).tag(policy)
            }
        }
        Text(LocalizedStringKey(ChatAttachmentCleanupPolicy.from(settings.chatAttachmentCleanupPolicyRaw).settingsDescriptionKey))
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
    }

    @ViewBuilder
    private var privacyContent: some View {
        privacyLabelsContent
        privacyFlightRecorderRow
        chatCleanupContent
        Button(LocalizedStringKey("Delete All Chats")) {
            triggerImpact(.medium)
            confirmClearChats = true
        }
        .tint(.red)
        Button(LocalizedStringKey("Reset App Data")) {
            triggerImpact(.medium)
            confirmResetAppData = true
        }
        .tint(.red)
        .disabled(isResettingAppData)

        Button {
            Task { await performDownloadCleanup() }
        } label: {
            if isCleaningDownloadLeftovers {
                Label(LocalizedStringKey("Cleaning Download Leftovers…"), systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label(LocalizedStringKey("Clean Download Leftovers"), systemImage: "externaldrive.badge.xmark")
            }
        }
        .disabled(isCleaningDownloadLeftovers)
        Text(LocalizedStringKey("Remove incomplete downloads, stale resume data, and temporary download files without deleting installed models or datasets."))
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
    }

    /// Entry point to the Privacy Flight Recorder, nested inside the Privacy
    /// screen. On iOS/visionOS it pushes onto the surrounding Privacy navigation
    /// stack; on macOS it opens via the shared settings-sheet route so it matches
    /// the rest of the Mac settings drill-ins.
    @ViewBuilder
    private var privacyFlightRecorderRow: some View {
#if os(macOS)
        Button {
            settingsDestination = .privacyFlight
        } label: {
            Label(LocalizedStringKey("Privacy Flight Recorder"), systemImage: "lock.shield")
        }
        Text(LocalizedStringKey("Review local, remote, network, and tool-state privacy receipts."))
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
#else
        NavigationLink {
            PrivacyFlightRecorderView()
        } label: {
            Label(LocalizedStringKey("Privacy Flight Recorder"), systemImage: "lock.shield")
        }
        Text(LocalizedStringKey("Review local, remote, network, and tool-state privacy receipts."))
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
#endif
    }

    private var privacyFeatureLabels: [PrivacyFeatureLabel] {
        PrivacyFeatureLabelAdvisor.labels(
            for: PrivacyFeatureLabelProfile(
                offGrid: settings.offGrid,
                webSearchEnabled: webSettings.webSearchEnabled,
                pythonEnabled: webSettings.pythonEnabled,
                memoryEnabled: webSettings.memoryEnabled,
                remoteRedactionEnabled: false
            )
        )
    }

    @ViewBuilder
    private var privacyLabelsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist.checked")
                    .foregroundStyle(Color.accentColor)
                Text(LocalizedStringKey("Feature Privacy Labels"))
                    .font(.system(size: 15, weight: .semibold))
            }

            ForEach(privacyFeatureLabels) { label in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: label.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(privacyLabelTint(label.state))
                        .frame(width: 22, height: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(LocalizedStringKey(label.titleKey))
                                .font(.system(size: 14, weight: .medium))
                            Spacer(minLength: 4)
                            Text(LocalizedStringKey(label.state.titleKey))
                                .font(FontTheme.caption)
                                .foregroundStyle(privacyLabelTint(label.state))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Text(LocalizedStringKey(label.detailKey))
                            .font(FontTheme.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func privacyLabelTint(_ state: PrivacyFeatureLabel.State) -> Color {
        switch state {
        case .local, .localSandbox:
            return .green
        case .optionalNetwork:
            return .orange
        case .remote:
            return .purple
        case .blocked:
            return .green
        case .off:
            return .secondary
        }
    }

    @ViewBuilder
    private var transcriptionSettingsContent: some View {
        Group {
            let availability = TranscriptionBackendFactory.primaryEngineChoices()
            let selectedEngineID = TranscriptionSettings.selectedEngineID
            let whisperEngineID = selectedEngineID.isLocalWhisper
                ? selectedEngineID
                : TranscriptionBackendFactory.preferredLocalWhisperEngineID()
            let selectedPickerValue = selectedEngineID.isLocalWhisper
                ? TranscriptionBackendFactory.preferredLocalWhisperEngineID().rawValue
                : TranscriptionEngineID.appleSpeech.rawValue

            Button {
                settingsDestination = .whisperModelCatalog
            } label: {
#if os(iOS)
                SettingsNavigationRow(
                    title: Text("Whisper Model Catalog"),
                    subtitle: Text("Choose the local speech model used for on-device transcription."),
                    trailingText: Text(activeWhisperModelName(for: whisperEngineID)),
                    leadingSystemImage: "waveform.badge.magnifyingglass",
                    leadingTint: .accentColor,
                    titleColor: .accentColor
                )
#elseif os(macOS)
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Whisper Model Catalog")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.text)
                        Text("Choose the local speech model used for on-device transcription.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.3))
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
#else
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.10))
                            .frame(width: 44, height: 44)
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Whisper Model Catalog")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("Choose the local speech model used for on-device transcription.")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
#endif
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.accentColor.opacity(0.08))

            Picker(LocalizedStringKey("Transcription Engine"), selection: Binding(
                get: { selectedPickerValue },
                set: { newValue in
                    let selected = TranscriptionEngineID(rawValue: newValue) ?? .appleSpeech
                    settings.asrEngineIDRaw = selected.isLocalWhisper
                        ? TranscriptionBackendFactory.preferredLocalWhisperEngineID().rawValue
                        : TranscriptionEngineID.appleSpeech.rawValue
                }
            )) {
                ForEach(availability) { entry in
                    Text(primaryEngineRowLabel(for: entry))
                        .tag(entry.id.rawValue)
                }
            }

            if let entry = availability.first(where: { $0.id.rawValue == selectedPickerValue }),
               !entry.isAvailable,
               let reason = entry.unavailableReason {
                Text(reason)
                    .font(FontTheme.caption)
                    .foregroundStyle(.orange)
            }

            Button(LocalizedStringKey("Remote Audio Endpoint")) {
                settingsDestination = .remoteAudioEndpoint
            }

            HStack(spacing: 8) {
                Text(LocalizedStringKey("ASR Locale"))
                Button { showASRLocaleInfo = true } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("What is ASR Locale?"))
            }
            TextField(
                "",
                text: Binding(
                    get: { settings.asrLocaleIdentifier },
                    set: { settings.asrLocaleIdentifier = $0 }
                ),
                prompt: Text(Locale.current.identifier)
            )

            HStack(spacing: 8) {
                Toggle(
                    LocalizedStringKey("On-device transcription only"),
                    isOn: Binding(
                        get: { settings.offGrid ? true : settings.asrOnDeviceOnly },
                        set: { settings.asrOnDeviceOnly = $0 }
                    )
                )
                .disabled(settings.offGrid)
                Button { showOnDeviceTranscriptionInfo = true } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("What is on-device transcription only?"))
            }

            Toggle(LocalizedStringKey("Auto-transcribe attachments"), isOn: $settings.asrAutoTranscribeAttachments)

            Toggle(LocalizedStringKey("Include timestamps in chat transcript"), isOn: $settings.asrIncludeTimestamps)

            voiceOutputSettingsContent
        }
        .alert(LocalizedStringKey("ASR Locale"), isPresented: $showASRLocaleInfo) {
            Button(LocalizedStringKey("OK"), role: .cancel) { }
        } message: {
            Text(LocalizedStringKey("Leave blank to use the current system language. Use \"auto\" to pick the best supported locale for your language."))
        }
        .alert(LocalizedStringKey("On-device transcription only"), isPresented: $showOnDeviceTranscriptionInfo) {
            Button(LocalizedStringKey("OK"), role: .cancel) { }
        } message: {
            Text(settings.offGrid
                 ? LocalizedStringKey("Off-grid Mode requires on-device transcription.")
                 : LocalizedStringKey("When enabled, Noema blocks Apple Speech from using network recognition."))
        }
    }

    @ViewBuilder
    private var voiceOutputSettingsContent: some View {
        Picker(LocalizedStringKey("Voice Output"), selection: Binding(
            get: { voiceOutputEngineRaw },
            set: { newValue in
                voiceOutputEngineRaw = newValue
                UserDefaults.standard.set(newValue, forKey: VoiceOutputSettings.engineKey)
            }
        )) {
            Text(LocalizedStringKey("Neural Voice")).tag(VoiceOutputEngineID.neural.rawValue)
            Text(LocalizedStringKey("System Voice")).tag(VoiceOutputEngineID.system.rawValue)
        }

        if voiceOutputEngineRaw == VoiceOutputEngineID.neural.rawValue,
           !VoiceOutputEngineFactory.neuralHardwareSupported {
            Text(LocalizedStringKey("Neural voice needs Apple silicon and at least 4 GB of memory; the system voice is used on this device."))
                .font(FontTheme.caption)
                .foregroundStyle(.orange)
        }

        if neuralVoiceNeedsDownload {
            Text(LocalizedStringKey("The neural voice model isn't downloaded yet. Download it below to preview and use the neural voice."))
                .font(FontTheme.caption)
                .foregroundStyle(.orange)
        }

        Button {
            settingsDestination = .voiceModelCatalog
        } label: {
            HStack {
                Label(LocalizedStringKey("Voice Model"), systemImage: "waveform.circle")
                Spacer()
                Text(voiceModelStateLabel)
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

#if canImport(TTSKit) && !arch(x86_64)
        Picker(LocalizedStringKey("Voice"), selection: Binding(
            get: { voiceOutputVoiceID },
            set: { newValue in
                voiceOutputVoiceID = newValue
                UserDefaults.standard.set(newValue, forKey: VoiceOutputSettings.voiceIDKey)
            }
        )) {
            ForEach(Qwen3Speaker.allCases, id: \.rawValue) { speaker in
                Text(verbatim: "\(speaker.displayName) · \(speaker.nativeLanguage)")
                    .tag(speaker.rawValue)
            }
        }
#endif

        HStack {
            Button {
                Task { await voicePreviewer.preview() }
            } label: {
                Label(LocalizedStringKey("Preview Voice"), systemImage: "play.circle")
            }
            .disabled(voicePreviewer.isBusy || neuralVoiceNeedsDownload)
            if voicePreviewer.isBusy {
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        }

#if canImport(AVFoundation)
        if voiceOutputEngineRaw == VoiceOutputEngineID.system.rawValue {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey("Speaking Rate"))
                Slider(
                    value: Binding(
                        get: { voiceSystemRate },
                        set: { newValue in
                            voiceSystemRate = newValue
                            UserDefaults.standard.set(newValue, forKey: VoiceOutputSettings.systemRateKey)
                        }
                    ),
                    in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)
                )
            }
            .onAppear { voiceSystemRate = Double(VoiceOutputSettings.systemRate) }
        }
#endif
    }

    private var voiceModelStateLabel: String {
        switch VoiceModelCatalog.installState() {
        case .ready: return String(localized: "Ready")
        case .incomplete: return String(localized: "Incomplete Download")
        case .missing: return String(localized: "Not Downloaded")
        }
    }

    /// Neural is selected on a device that can run it, but the weights aren't
    /// installed yet — so previewing would only produce the system voice.
    private var neuralVoiceNeedsDownload: Bool {
        voiceOutputEngineRaw == VoiceOutputEngineID.neural.rawValue
            && VoiceOutputEngineFactory.neuralHardwareSupported
            && VoiceModelCatalog.installState() != .ready
    }

    private func primaryEngineRowLabel(for entry: EngineAvailability) -> String {
        let displayName = entry.id.isLocalWhisper ? TranscriptionBackendFactory.localWhisperDisplayName : entry.id.displayName
        if entry.isAvailable {
            return displayName
        }
        return String.localizedStringWithFormat(
            String(localized: "%@ (unavailable)"),
            displayName
        )
    }

    private func activeWhisperModelName(for engineID: TranscriptionEngineID) -> String {
        WhisperModelCatalog.activeRecord(for: engineID)?.displayName ?? String(localized: "Required")
    }

    private var aboutSection: some View {
        Section(LocalizedStringKey("About & Support")) { aboutContent }
    }

    @ViewBuilder
    private var aboutContent: some View {
        Button(LocalizedStringKey("What's New")) {
            showUpdate = true
        }
        Link(LocalizedStringKey("Terms of Use"), destination: URL(string: "https://noemaai.com/terms")!)
        Link(LocalizedStringKey("Privacy Policy"), destination: URL(string: "https://noemaai.com/privacy")!)
        Link(LocalizedStringKey("Contact Support"), destination: URL(string: "mailto:clientcare@noemaai.com")!)
        if (Bundle.main.infoDictionary?["AppStoreID"] as? String).map({ !$0.isEmpty }) == true {
            Button(LocalizedStringKey("Write a Review")) {
                ReviewPrompter.shared.openWriteReviewPageIfAvailable()
            }
        }
        Button(LocalizedStringKey("Notes & Issues")) {
            settingsDestination = .notesIssues
        }
    }

    private var llamaCppSection: some View {
        Section { llamaContent } footer: {
            Text(LocalizedStringKey("This app bundles llama.cpp; we keep this in sync with upstream b‑releases."))
        }
    }

    @ViewBuilder
    private var llamaContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Llama.cpp")
                .font(FontTheme.body)
                .fontWeight(.medium)
                .foregroundStyle(AppTheme.text)
            Text(LocalizedStringKey("Latest integrated release: \(llamaCppBuild)"))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        HStack(spacing: 12) {
            Image("Noema")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Noema")
                    .font(FontTheme.body)
                    .fontWeight(.medium)
                    .foregroundStyle(AppTheme.text)
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "Version %@"),
                        appVersion
                    )
                )
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
        }
    }

    private var advancedSection: some View {
        Group {
            Section(LocalizedStringKey("Retrieval")) { advancedRetrievalContent }
            // MCPs section removed
        }
    }

    @ViewBuilder
    private var advancedRetrievalContent: some View {
        // Retrieval Mode — picker with an always-visible description
        // that updates to explain the currently selected mode.
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey("Retrieval Mode"))
            Picker(LocalizedStringKey("Retrieval Mode"), selection: $settings.ragRetrievalModeRaw) {
                ForEach(DatasetRetrievalMode.allCases) { mode in
                    Text(retrievalModeTitle(mode))
                        .tag(mode.rawValue)
                }
            }
#if os(macOS)
            .pickerStyle(.menu)
            .fixedSize()
#else
            .pickerStyle(.segmented)
#endif
            .labelsHidden()

            Text(retrievalModeDescription(DatasetRetrievalMode.from(settings.ragRetrievalModeRaw)))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Max Chunks — stepper with an always-visible caption explaining it.
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: $settings.ragMaxChunks, in: 1...8) {
                HStack(spacing: 8) {
                    let chunksFormatter: NumberFormatter = {
                        let nf = NumberFormatter()
                        nf.locale = localizationManager.locale
                        nf.numberStyle = .decimal
                        return nf
                    }()
                    let chunkString = chunksFormatter.string(from: NSNumber(value: settings.ragMaxChunks)) ?? "\(settings.ragMaxChunks)"
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Max Chunks: %@", locale: localizationManager.locale),
                            chunkString
                        )
                    )
                    Spacer()
                    Button { showChunksInfo = true } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LocalizedStringKey("What is Max Chunks?"))
                }
            }

            Text(LocalizedStringKey("The most passages from your dataset that can be added to the prompt. Fewer may be used when only a little matches your question."))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Similarity Threshold — slider with live value and an explanatory caption.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey("Similarity Threshold"))
                Button { showSimilarityInfo = true } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("What is Similarity Threshold?"))
                Spacer()
                Text(String(format: "%.2f", settings.ragMinScore))
                    .frame(width: 44, alignment: .trailing)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Slider(value: $settings.ragMinScore, in: 0...1)
            Text(LocalizedStringKey("How closely a passage must match to be preferred. Lower = more passages (more noise); higher = fewer, stricter matches."))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            // Ties the two controls together: shows the actual floor in use,
            // i.e. the slider value after the selected Retrieval Mode adjusts it.
            Label {
                Text(retrievalThresholdRelationship(
                    mode: DatasetRetrievalMode.from(settings.ragRetrievalModeRaw),
                    base: settings.ragMinScore
                ))
            } icon: {
                Image(systemName: "slider.horizontal.3")
            }
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }

        // Attached-document expiry — how long an on-the-spot embedded document is kept
        // before its vectors are deleted.
        VStack(alignment: .leading, spacing: 6) {
            Picker(LocalizedStringKey("Keep attached documents for"), selection: $settings.attachedDocExpiryHours) {
                Text(LocalizedStringKey("2 hours")).tag(2)
                Text(LocalizedStringKey("6 hours")).tag(6)
                Text(LocalizedStringKey("12 hours")).tag(12)
                Text(LocalizedStringKey("1 day")).tag(24)
                Text(LocalizedStringKey("3 days")).tag(72)
                Text(LocalizedStringKey("7 days")).tag(168)
            }
            Text(LocalizedStringKey("Documents you attach in chat are embedded on the spot. Their vectors are deleted automatically after this time."))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func retrievalModeTitle(_ mode: DatasetRetrievalMode) -> LocalizedStringKey {
        switch mode {
        case .focused:
            return "Focused"
        case .balanced:
            return "Balanced"
        case .broad:
            return "Broad"
        }
    }

    /// Plain-language explanation of what the selected retrieval mode does,
    /// shown directly under the picker so the trade-off is obvious at a glance.
    private func retrievalModeDescription(_ mode: DatasetRetrievalMode) -> LocalizedStringKey {
        switch mode {
        case .focused:
            return "Returns only the closest-matching passages. Best for precise, fact-based questions."
        case .balanced:
            return "Balances precision and coverage. A good default for most questions."
        case .broad:
            return "Casts a wider net across more of your sources. Best for open-ended or exploratory questions."
        }
    }

    /// Spells out how the Retrieval Mode and Similarity Threshold combine: the
    /// slider sets a base floor, and the mode shifts it. Shows the resulting
    /// "effective" value live so the relationship is concrete, not abstract.
    private func retrievalThresholdRelationship(mode: DatasetRetrievalMode, base: Double) -> String {
        let baseStr = String(format: "%.2f", base)
        let effStr = String(format: "%.2f", Double(mode.effectiveThreshold(base: Float(base))))
        switch mode {
        case .focused:
            return String.localizedStringWithFormat(
                String(localized: "Focused keeps your full threshold — passages must score at least %@.", locale: localizationManager.locale),
                baseStr
            )
        case .balanced:
            return String.localizedStringWithFormat(
                String(localized: "Balanced eases your %@ threshold down to %@, so more passages qualify.", locale: localizationManager.locale),
                baseStr, effStr
            )
        case .broad:
            return String.localizedStringWithFormat(
                String(localized: "Broad eases your %@ threshold down to %@ for the widest net.", locale: localizationManager.locale),
                baseStr, effStr
            )
        }
    }


    // Auto-title explanation removed

    private var modeExplanation: LocalizedStringKey {
        settings.isAdvancedMode
            ? LocalizedStringKey("Advanced mode shows developer options and diagnostics.")
            : LocalizedStringKey("Simple mode hides advanced settings for a cleaner interface.")
    }
}

private extension SettingsView {
#if os(iOS)
    func loadWalletPassTokenState() {
        walletPassTokenStored = ((try? PassSigningCredentialStore.token()) ?? nil) != nil
        walletPassSignerToken = ""
    }

    func saveWalletPassToken() {
        let trimmed = walletPassSignerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try PassSigningCredentialStore.setToken(trimmed)
            walletPassTokenStored = true
            walletPassSignerToken = ""
            walletPassTokenFocused = false
        } catch {
            Task { await logger.log("[Settings][WalletPass] Failed to save signer token: \(error.localizedDescription)") }
        }
    }
#endif

    var languageOptions: [(code: String, name: String)] {
        let displayLocale = Locale(identifier: localizationManager.locale.identifier)
        return LocalizationManager.supportedLanguages.map { code in
            let name = displayLocale.localizedString(forIdentifier: code)
                ?? displayLocale.localizedString(forLanguageCode: code)
                ?? Locale(identifier: code).localizedString(forLanguageCode: code)
                ?? code
            return (code, name.capitalized)
        }
    }

    var currentLanguageCode: String {
        let id = localizationManager.locale.identifier.lowercased()
        return LocalizationManager.supportedLanguages.first(where: { id.hasPrefix($0.lowercased()) }) ?? "en"
    }


    // Start embedding model download from Settings using the same installer as onboarding
    func startEmbeddingDownloadFromSettings() {
        Task { @MainActor in
            await embedInstaller.installIfNeeded()
            if embedInstaller.state == .ready {
                await EmbeddingModel.shared.warmUp()
            }
        }
    }

    @MainActor
    func performResetAppData() async {
        guard !isResettingAppData else { return }
        isResettingAppData = true
        defer { isResettingAppData = false }

        confirmResetAppData = false
        showChatsCleared = false

        triggerImpact(.heavy)

        await chatVM.unload()
        modelManager.loadedModel = nil
        modelManager.lastUsedModel = nil
        modelManager.activeDataset = nil
        modelManager.modelSettings.removeAll()

        let jobs = await DownloadEngine.shared.snapshots()
        for job in jobs {
            var urlsToDelete: [URL] = []
            for artifact in job.artifacts {
                BackgroundDownloadManager.shared.cancel(destination: artifact.destinationURL)
                urlsToDelete.append(artifact.stagingURL)
                urlsToDelete.append(artifact.finalURL)
            }
            _ = ModelStorageCleanup.deleteURLs(urlsToDelete)
            await DownloadEngine.shared.removeJob(externalID: job.externalID)
        }

        let models = modelManager.downloadedModels
        for model in models {
            modelManager.delete(model)
        }
        _ = ModelStorageCleanup.removeAllSupportModelStorage()
        _ = ModelStorageCleanup.pruneOrphanedModelDirectories(installedModels: [], activeDownloadURLs: [])

        let datasets = datasetManager.datasets
        for dataset in datasets {
            try? datasetManager.delete(dataset)
        }
        datasetManager.select(nil)
        modelManager.setActiveDataset(nil)

        settings.clearChatHistory(chatVM)
        chatVM.runAttachmentGarbageCollectionNow()
        estimateModelPath = ""

        await settings.resetAppData()
        if EnterprisePolicyGate.requiresOffGrid {
            EnterprisePolicyManager.shared.reapplyOffGridMapping()
        } else {
            NetworkKillSwitch.setEnabled(false)
        }
        refreshStartupPreferences()

        modelManager.refresh()
        datasetManager.reloadFromDisk()

        showResetComplete = true
    }

    func refreshEmbeddingAvailability() {
        embedAvailable = FileManager.default.fileExists(atPath: EmbeddingModel.modelURL.path)
    }

    func deleteEmbeddingModel() {
        Task {
            await logger.log("[Settings] User requested embedding model deletion")
            await EmbeddingModel.shared.unload()
            let url = EmbeddingModel.modelURL
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                let directory = EmbeddingModelCatalog.directoryURL(for: EmbeddingModelCatalog.activeRecord().id)
                if FileManager.default.fileExists(atPath: directory.path) {
                    try? FileManager.default.removeItem(at: directory)
                }
                UserDefaults.standard.removeObject(forKey: "hasInstalledEmbedModel:\(url.path)")
                await MainActor.run {
                    refreshEmbeddingAvailability()
                    NotificationCenter.default.post(name: .embeddingModelAvailabilityChanged, object: nil, userInfo: ["available": false])
                }
                await logger.log("[Settings] ✅ Embedding model deleted")
            } catch {
                await logger.log("[Settings] ❌ Failed to delete embedding model: \(error.localizedDescription)")
                let message = error.localizedDescription
                await MainActor.run {
                    embedDeleteErrorMessage = message
                    showEmbedDeleteError = true
                    refreshEmbeddingAvailability()
                }
            }
        }
    }

    @MainActor
    func performDownloadCleanup() async {
        guard !isCleaningDownloadLeftovers else { return }
        isCleaningDownloadLeftovers = true
        defer { isCleaningDownloadLeftovers = false }

        let result = await downloadController.runDownloadMaintenance(manual: true, force: true)
        let format = String(
            localized: "Removed %1$d temporary file(s), %2$d resume item(s), and %3$d stale download record(s). Repaired %4$d download artifact(s).",
            locale: localizationManager.locale
        )
        downloadCleanupResultMessage = String.localizedStringWithFormat(
            format,
            result.removedOrphanFiles,
            result.removedResumeData,
            result.removedJobs,
            result.repairedArtifacts
        )
        showDownloadCleanupResult = true
    }
}

private struct StartupRemoteRow: View {
    @Binding var selection: StartupPreferences.RemoteSelection
    let backend: RemoteBackend?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                Text(selection.backendName)
                    .font(.headline)
                Text(backendDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if canMoveUp { Button(LocalizedStringKey("Move Up"), action: moveUp) }
                if canMoveDown { Button(LocalizedStringKey("Move Down"), action: moveDown) }
                Button(role: .destructive, action: remove) {
                    Label(LocalizedStringKey("Remove"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(LocalizedStringKey("Startup remote options"))
            }
        }
        if let backend {
            if backend.cachedModels.isEmpty {
                Text(LocalizedStringKey("No models cached yet. Open the backend to refresh its catalog."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker(LocalizedStringKey("Model"), selection: $selection.modelID) {
                    ForEach(backend.cachedModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                if backend.cachedModels.first(where: { $0.id == selection.modelID }) == nil && !selection.modelID.isEmpty {
                    Text(LocalizedStringKey("We'll try this saved identifier even though it's not in the latest catalog."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(LocalizedStringKey("This backend is unavailable. Remove it or pick another option."))
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
    .padding(.vertical, 4)
        .onChange(of: backend?.name ?? "") { newName in
            guard !newName.isEmpty, selection.backendName != newName else { return }
            selection.backendName = newName
        }
        .onChange(of: selection.modelID) { newValue in
            guard !newValue.isEmpty else { return }
            if let backend, let model = backend.cachedModels.first(where: { $0.id == newValue }) {
                selection.modelName = model.name
                selection.relayRecordName = model.relayRecordName
            } else if selection.modelName.isEmpty {
                selection.modelName = newValue
            }
        }
    }

    private var backendDescription: String {
        if let backend {
            return backend.endpointType.displayName
        }
        return String(localized: "Backend removed")
    }
}

private enum ImpactStyle {
    case medium
    case heavy
}

@MainActor
private func triggerImpact(_ style: ImpactStyle) {
#if canImport(UIKit) && !os(visionOS)
    let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
    switch style {
    case .medium:
        feedbackStyle = .medium
    case .heavy:
        feedbackStyle = .heavy
    }
    Haptics.impact(feedbackStyle)
#endif
}

@_silgen_name("app_memory_footprint")
fileprivate func c_app_memory_footprint() -> UInt

#Preview {
    SettingsView()
        .environmentObject(ChatVM())
        .environmentObject(TabRouter())
        .environmentObject(AppModelManager())
        .environmentObject(DatasetManager())
        .environmentObject(DownloadController())
        .environmentObject(GuidedWalkthroughManager())
        .environmentObject(LocalizationManager())
}
