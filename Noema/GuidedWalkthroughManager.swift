// GuidedWalkthroughManager.swift
import SwiftUI
import Combine

@MainActor
final class GuidedWalkthroughManager: ObservableObject {
    enum Step: Int, CaseIterable {
        case idle
        case chatIntro
        case chatSidebar
        case chatNewChat
        case chatInput
        case chatWebSearch
        case storedIntro
        case storedRecommend
        case storedFormats
        case modelSettingsIntro
        case modelSettingsContext
        case modelSettingsDefault
        case storedDatasets
        case exploreIntro
        case exploreDatasets
        case exploreImport
        case exploreSwitchToModels
        case exploreModelTypes
        case exploreMLX
        case exploreSLM
        case settingsIntro
        case settingsHighlights
        case completed
    }

    enum HighlightID: Hashable {
        case chatCanvas
        case chatSidebar
        case chatSidebarButton
        case chatNewChatButton
        case chatInput
        case chatWebSearch
        case storedList
        case storedDatasets
        case exploreDatasetList
        case exploreImportButton
        case exploreSwitchBar
        case exploreModelToggle
        case settingsForm
        case settingsOffGrid
        case modelSettingsContext
        case modelSettingsDefault
    }

    @Published private(set) var step: Step = .idle
    @Published var isActive = false
    @Published var anchors: [HighlightID: Anchor<CGRect>] = [:]
    @Published var pendingModelSettingsID: String?
    @Published var shouldDismissModelSettings = false

    // Recommended starter model state
    @Published var recommendedDetail: ModelDetails?
    @Published var recommendedQuant: QuantInfo?
    @Published var recommendedLoading = false
    @Published var recommendedLoadFailed = false
    @Published var recommendedDownloading = false
    @Published var recommendedProgress: Double = 0
    @Published var recommendedSpeed: Double = 0

    private var cancellables = Set<AnyCancellable>()

    // Dependencies
    private weak var tabRouter: TabRouter?
    private weak var chatVM: ChatVM?
    private weak var modelManager: AppModelManager?
    private weak var datasetManager: DatasetManager?
    private weak var downloadController: DownloadController?

    private let recommendedModelID = "unsloth/Qwen3.5-2B-GGUF"
    private var skippedRecommendedDownload = false
    private var shouldShowModelSettings = false
    private var recommendedAnchorsLoaded = false

    func configure(tabRouter: TabRouter,
                   chatVM: ChatVM,
                   modelManager: AppModelManager,
                   datasetManager: DatasetManager,
                   downloadController: DownloadController) {
        guard self.tabRouter == nil else { return }
        self.tabRouter = tabRouter
        self.chatVM = chatVM
        self.modelManager = modelManager
        self.datasetManager = datasetManager
        self.downloadController = downloadController

        modelManager.$downloadedModels
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleDownloadedModelsChanged() }
            .store(in: &cancellables)

        downloadController.itemsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                self?.updateRecommendedDownloadProgress(with: items)
            }
            .store(in: &cancellables)
    }

    func begin() {
        guard !isActive else { return }
        isActive = true
        skippedRecommendedDownload = false
        shouldShowModelSettings = recommendedModelInstalled
        pendingModelSettingsID = nil
        shouldDismissModelSettings = false
        advance(to: .chatIntro)
    }

    func advanceFromOverlay() {
        guard isActive else { return }
        switch step {
        case .chatIntro:
            advance(to: .chatSidebar)
        case .chatSidebar:
            advance(to: .chatNewChat)
        case .chatNewChat:
            advance(to: .chatInput)
        case .chatInput:
            advance(to: .chatWebSearch)
        case .chatWebSearch:
            tabRouter?.selection = .stored
            advance(to: .storedIntro)
        case .storedIntro:
            ensureRecommendedDetailLoaded()
            advance(to: .storedRecommend)
        case .storedRecommend:
            if recommendedModelInstalled || skippedRecommendedDownload {
                advance(to: .storedFormats)
            }
        case .storedFormats:
            if shouldShowModelSettings {
                advance(to: .modelSettingsIntro)
            } else {
                advance(to: .storedDatasets)
            }
        case .modelSettingsIntro:
            advance(to: .modelSettingsContext)
        case .modelSettingsContext:
            shouldDismissModelSettings = true
            advance(to: .storedDatasets)
        case .modelSettingsDefault:
            shouldDismissModelSettings = true
            advance(to: .storedDatasets)
        case .storedDatasets:
            tabRouter?.selection = .explore
            advance(to: .exploreIntro)
        case .exploreIntro:
            advance(to: .exploreDatasets)
        case .exploreDatasets:
            advance(to: .exploreImport)
        case .exploreImport:
            advance(to: .exploreSwitchToModels)
        case .exploreSwitchToModels:
            advance(to: .exploreModelTypes)
        case .exploreModelTypes:
            if DeviceGPUInfo.supportsGPUOffload {
                advance(to: .exploreMLX)
            } else {
                advance(to: .exploreSLM)
            }
        case .exploreMLX:
            advance(to: .exploreSLM)
        case .exploreSLM:
            tabRouter?.selection = .settings
            advance(to: .settingsIntro)
        case .settingsIntro:
            advance(to: .settingsHighlights)
        case .settingsHighlights:
            advance(to: .completed)
        case .completed, .idle:
            finish()
        }
    }

    func skipRecommendedDownload() {
        guard step == .storedRecommend else { return }
        skippedRecommendedDownload = true
        advanceFromOverlay()
    }

    func finish() {
        isActive = false
        shouldDismissModelSettings = false
        advance(to: .idle)
    }

    func updateAnchors(_ newAnchors: [HighlightID: Anchor<CGRect>]) {
        anchors = newAnchors
    }

    func highlightID(for step: Step) -> HighlightID? {
        switch step {
        case .chatIntro: return .chatCanvas
        case .chatSidebar: return .chatSidebarButton
        case .chatNewChat: return .chatNewChatButton
        case .chatInput: return .chatInput
        case .chatWebSearch: return .chatWebSearch
        case .storedIntro: return .storedList
        case .storedRecommend: return .storedList
        case .storedFormats: return .storedList
        case .modelSettingsContext: return .modelSettingsContext
        case .modelSettingsDefault: return nil
        case .storedDatasets: return .storedDatasets
        case .exploreIntro: return .exploreSwitchBar
        case .exploreDatasets: return .exploreDatasetList
        case .exploreImport: return .exploreImportButton
        case .exploreSwitchToModels: return .exploreSwitchBar
        case .exploreModelTypes: return .exploreModelToggle
        case .exploreMLX: return .exploreModelToggle
        case .exploreSLM: return .exploreModelToggle
        case .settingsIntro: return .settingsForm
        case .settingsHighlights: return .settingsOffGrid
        default: return nil
        }
    }

    func instruction(for step: Step) -> (title: String, message: String, primary: String, secondary: String?) {
        switch step {
        case .chatIntro:
            return ("Welcome to Noema", "This is your chat space. Once you download a model, everything runs offline—no cloud required.", "Next", nil)
        case .chatSidebar:
            return ("Previous Chats", "Tap here anytime to open your sidebar and revisit earlier conversations.", "Next", nil)
        case .chatNewChat:
            return ("Start Fresh", "Use the plus button to create a brand-new chat without clearing your history.", "Next", nil)
        case .chatInput:
            return ("Ask Anything", "Type your questions here. Noema will respond locally once a model is loaded.", "Next", nil)
        case .chatWebSearch:
            return ("Optional Web Search", "Arm the globe button to let the model pull limited web results. Most questions work great without it.", "Next", nil)
        case .storedIntro:
            return ("Stored Library", "Everything you download lives here—models and datasets alike.", "Next", nil)
        case .storedRecommend:
            if recommendedModelInstalled {
                return ("Starter Model Ready", "Great! You already have our recommended GGUF model installed.", "Continue", nil)
            } else {
                return ("Download the Starter Model", "Grab the Qwen 3.5 2B GGUF build first. It's a reliable starting point and stays fully offline.", "Download", "Skip")
            }
        case .storedFormats:
            return ("Model Formats", "Noema supports GGUF, MLX, and ET formats. GGUF is the most compatible; MLX and ET focus on speed.", "Next", nil)
        case .modelSettingsIntro:
            return ("Model Settings", "We opened settings for the starter model so you can review the basics.", "Next", nil)
        case .modelSettingsContext:
            return ("Context Length", "Higher context lets the model remember more of the conversation, but it uses more memory.", "Next", nil)
        case .modelSettingsDefault:
            return ("Startup Defaults", "Configure automatic loading from the new Startup section in Settings. Favorites still pin models for quick access.", "Finish Settings", nil)
        case .storedDatasets:
            return ("Datasets", "Downloaded datasets appear here too. Activate one to give the model focused knowledge.", "Next", nil)
        case .exploreIntro:
            return ("Explore Library", "Use Explore to find new models or subject-specific datasets.", "Next", nil)
        case .exploreDatasets:
            return ("Find Datasets", "Search for textbooks or notes. Not every entry includes a download, so try a few results.", "Next", nil)
        case .exploreImport:
            return ("Import Your Own", "Use the import button to bring in PDFs, EPUBs, or text files. Noema will index them locally.", "Next", nil)
        case .exploreSwitchToModels:
            return ("Switch Views", "Jump between models and datasets right here.", "Go to Models", nil)
        case .exploreModelTypes:
            return ("GGUF Format", "This switch cycles through GGUF, MLX, and ET builds. Start with GGUF for the widest compatibility.", "Next", nil)
        case .exploreMLX:
            return ("MLX Format", "Flip the control to MLX when you want Apple Silicon-optimized builds with excellent speed.", "Next", nil)
        case .exploreSLM:
            return ("ET Format", "Choose ET for lightweight models that run quickly and stay efficient on any device.", "Next", nil)
        case .settingsIntro:
            return ("Settings", "Tune Noema to your needs from here—appearance, network modes, and more.", "Next", nil)
        case .settingsHighlights:
            return ("Off-Grid Mode", "Enable off-grid to block all network access so everything stays local. When you're done, tap Next to wrap up—good luck exploring Noema!", "Next", nil)
        case .completed:
            return ("All Set", "You’re ready to explore Noema. Remember you can revisit this guide from Settings anytime.", "Done", nil)
        case .idle:
            return ("", "", "", nil)
        }
    }

    func performPrimaryAction() {
        switch step {
        case .storedRecommend:
            if recommendedModelInstalled {
                advanceFromOverlay()
            } else {
                startRecommendedDownload()
            }
        default:
            advanceFromOverlay()
        }
    }

    private func advance(to newStep: Step) {
        step = newStep
        switch newStep {
        case .chatIntro:
            tabRouter?.selection = .chat
        case .storedRecommend:
            ensureRecommendedDetailLoaded()
        case .modelSettingsIntro:
            if shouldShowModelSettings {
                pendingModelSettingsID = recommendedModelID
            }
        case .completed:
            finish()
        default:
            break
        }
    }

    func startRecommendedDownload() {
        guard recommendedDownloading == false,
              let detail = recommendedDetail,
              let quant = recommendedQuant,
              let downloadController else { return }
        recommendedDownloading = true
        recommendedProgress = 0
        recommendedSpeed = 0
        downloadController.start(detail: detail, quant: quant)
    }

    func cancelRecommendedDownload() {
        guard let detail = recommendedDetail,
              let quant = recommendedQuant,
              let downloadController else { return }
        let id = "\(detail.id)-\(quant.label)"
        downloadController.cancel(itemID: id)
        recommendedDownloading = false
        recommendedProgress = 0
        recommendedSpeed = 0
    }

    func openRecommendedModel() async {
        guard let chatVM,
              let modelManager,
              let detail = recommendedDetail,
              let quant = recommendedQuant else { return }

        let url = recommendedFileURL(for: quant, detailID: detail.id)
        let name = url.deletingPathExtension().lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let downloadedSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let effectiveSize = downloadedSize > 0 ? downloadedSize : quant.sizeBytes

        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")
        let meta = HuggingFaceMetadataCache.cached(repoId: detail.id)
        var isVision = meta?.isVision ?? false

        if !isVision {
            switch quant.format {
            case .gguf:
                isVision = ModelVisionDetector.guessLlamaVisionModel(from: url)
            case .mlx:
                isVision = MLXBridge.isVLMModel(at: url)
            case .et:
                let slug = detail.id.isEmpty ? url.deletingPathExtension().lastPathComponent : detail.id
                isVision = LeapCatalogService.isVisionQuantizationSlug(slug)
            case .ane:
                isVision = false
            case .afm:
                isVision = false
            case .coreai:
                isVision = false
            }
        }

        var isToolCapable = quant.format == .afm ? false : await ToolCapabilityDetector.isToolCapable(repoId: detail.id, token: token)
        if isToolCapable == false {
            isToolCapable = ToolCapabilityDetector.isToolCapableLocal(url: url, format: quant.format)
        }

        let moeInfo: MoEInfo?
        switch quant.format {
        case .gguf, .mlx:
            moeInfo = ModelScanner.moeInfo(for: url, format: quant.format)
        case .et, .ane, .afm, .coreai:
            moeInfo = nil
        }
        let architectureLabels = LocalModel.architectureLabels(for: url, format: quant.format, modelID: detail.id)
        let local = LocalModel(
            modelID: detail.id,
            name: name,
            url: url,
            quant: quant.label,
            architecture: architectureLabels.display,
            architectureFamily: architectureLabels.family,
            format: quant.format,
            sizeGB: Double(effectiveSize) / 1_073_741_824.0,
            isMultimodal: isVision,
            isToolCapable: isToolCapable,
            isDownloaded: true,
            downloadDate: Date(),
            lastUsedDate: nil,
            isFavourite: false,
            totalLayers: ModelScanner.layerCount(for: url, format: quant.format),
            moeInfo: moeInfo
        )

        var settings = modelManager.settings(for: local)
        settings = tunedSettingsForRecommendedModel(settings, local: local, quant: quant, sizeBytes: effectiveSize)
        settings = modelManager.normalizeLocalSettings(settings, for: local)
        await chatVM.unload()
        if await chatVM.load(url: url, settings: settings, format: quant.format) {
            modelManager.updateSettings(settings, for: local)
            modelManager.markModelUsed(local)
            modelManager.setCapabilities(modelID: detail.id, quant: quant.label, isMultimodal: isVision, isToolCapable: isToolCapable)
        } else {
            modelManager.loadedModel = nil
        }
        tabRouter?.selection = .chat
    }

    private func ensureRecommendedDetailLoaded(force: Bool = false) {
        if recommendedLoading { return }
        if !force, recommendedDetail != nil { return }
        if force {
            recommendedDetail = nil
            recommendedQuant = nil
        }
        recommendedLoading = true
        recommendedLoadFailed = false
        Task {
            do {
                let registry = ManualModelRegistry()
                let details = try await registry.details(for: recommendedModelID)
                if let quant = ManualModelRegistry.recommendedStarterQuant(in: details) {
                    recommendedDetail = details
                    recommendedQuant = quant
                } else {
                    applyRecommendedFallback()
                    recommendedLoadFailed = true
                }
            } catch {
                applyRecommendedFallback()
                recommendedLoadFailed = true
            }
            recommendedLoading = false
        }
    }

    func reloadRecommendedDetail() {
        ensureRecommendedDetailLoaded(force: true)
    }

    private func applyRecommendedFallback() {
        if let entry = ManualModelRegistry.defaultEntries.first(where: { $0.record.id == recommendedModelID }) {
            recommendedDetail = entry.details
            recommendedQuant = ManualModelRegistry.recommendedStarterQuant(in: entry.details)
        }
    }

    private func recommendedFileURL(for quant: QuantInfo, detailID: String) -> URL {
        InstalledModelsStore.localModelURL(for: quant, modelID: detailID)
    }

    private func updateRecommendedDownloadProgress(with items: [DownloadController.Item]) {
        guard let detail = recommendedDetail, let quant = recommendedQuant else { return }
        if let item = items.first(where: { $0.detail.id == detail.id && $0.quant.label == quant.label }) {
            recommendedDownloading = true
            recommendedProgress = item.progress
            recommendedSpeed = item.speed
        } else if recommendedDownloading {
            recommendedDownloading = false
            recommendedProgress = 0
            recommendedSpeed = 0
        }
    }

    private func handleDownloadedModelsChanged() {
        guard let modelManager else { return }
        if modelManager.downloadedModels.contains(where: { $0.modelID == recommendedModelID && recommendedQuantMatches($0.quant) }) {
            shouldShowModelSettings = true
            if step == .storedRecommend && !skippedRecommendedDownload {
                // Auto-advance after a short delay so the user sees completion
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if self.step == .storedRecommend {
                        self.advanceFromOverlay()
                    }
                }
            }
        }
    }

    private func tunedSettingsForRecommendedModel(_ base: ModelSettings, local: LocalModel, quant: QuantInfo, sizeBytes: Int64) -> ModelSettings {
        var updated = base
        let info = DeviceRAMInfo.current()
        let budget = info.conservativeLimitBytes()
        let threeGiB: Int64 = Int64(3) * 1_073_741_824
        let usableSize = sizeBytes > 0 ? sizeBytes : quant.sizeBytes
        let requestedContext = max(512, Int(updated.contextLength.rounded()))
        let layerCount = local.totalLayers > 0 ? local.totalLayers : nil
        let modelMaxContext = ModelSettings.supportedMaxContextLength(for: local)
        let kvCacheEstimate = ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: updated)

        if usableSize > 0 {
            let fits = ModelRAMAdvisor.fitsInRAM(
                format: quant.format,
                sizeBytes: usableSize,
                contextLength: requestedContext,
                layerCount: layerCount,
                moeInfo: local.moeInfo,
                kvCacheEstimate: kvCacheEstimate
            )
            if !fits {
                if let maxContext = ModelRAMAdvisor.maxContextUnderBudget(
                    format: quant.format,
                    sizeBytes: usableSize,
                    layerCount: layerCount,
                    moeInfo: local.moeInfo,
                    upperBound: modelMaxContext,
                    kvCacheEstimate: kvCacheEstimate
                ) {
                    let safeContext = max(512, min(requestedContext, maxContext))
                    if Double(safeContext) < updated.contextLength {
                        updated.contextLength = Double(safeContext)
                    }
                } else if let limit = budget, limit <= threeGiB {
                    updated.contextLength = min(updated.contextLength, 2048)
                }
            }
        } else if let limit = budget, limit <= threeGiB {
            updated.contextLength = min(updated.contextLength, 2048)
        }

        if quant.format == .gguf {
            if updated.gpuLayers == 0 { updated.gpuLayers = -1 }
        }

        return updated.normalizedForLocalModel(local)
    }

    private func recommendedQuantMatches(_ label: String) -> Bool {
        guard let recommendedQuant else { return true }
        return label.caseInsensitiveCompare(recommendedQuant.label) == .orderedSame
    }

    var recommendedModelInstalled: Bool {
        guard let modelManager else { return false }
        return modelManager.downloadedModels.contains(where: { $0.modelID == recommendedModelID && recommendedQuantMatches($0.quant) })
    }
}

struct GuidedHighlightPreferenceKey: PreferenceKey {
    static var defaultValue: [GuidedWalkthroughManager.HighlightID: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [GuidedWalkthroughManager.HighlightID: Anchor<CGRect>], nextValue: () -> [GuidedWalkthroughManager.HighlightID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct GuidedHighlightModifier: ViewModifier {
    let id: GuidedWalkthroughManager.HighlightID

    func body(content: Content) -> some View {
        content.anchorPreference(key: GuidedHighlightPreferenceKey.self, value: .bounds) { [id: $0] }
    }
}

extension View {
    func guideHighlight(_ id: GuidedWalkthroughManager.HighlightID) -> some View {
        modifier(GuidedHighlightModifier(id: id))
    }

    /// Attaches the guided-highlight anchor preference **only** when the walkthrough is
    /// active. The `anchorPreference`/`overlayPreferenceValue` machinery re-propagates on
    /// every geometry change, so leaving it attached makes scrolling a `Form`/`ScrollView`
    /// that contains a highlighted control janky even when no walkthrough is running.
    @ViewBuilder
    func guideHighlightIfActive(_ active: Bool, _ id: GuidedWalkthroughManager.HighlightID) -> some View {
        if active {
            self.guideHighlight(id)
        } else {
            self
        }
    }
}
