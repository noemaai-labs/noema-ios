// OnboardingView.swift
#if canImport(UIKit)
import SwiftUI
import Combine
import Foundation
import UIKit
#if canImport(AppKit)
import AppKit
#endif

struct OnboardingView: View {
    @Binding var showOnboarding: Bool
    @State private var currentPage = 0
    @StateObject private var embedInstaller = EmbedModelInstaller(recordID: EmbeddingModelCatalog.defaultModelID)
    @State private var animateElements = false
    @State private var logoScale: CGFloat = 0.5
    @State private var textOpacity: Double = 0
    @State private var isDownloadingEmbedModel = false
    @State private var embedProgress: Double = 0
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var downloadController: DownloadController
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var chatVM: ChatVM
    @EnvironmentObject var tabRouter: TabRouter
    @EnvironmentObject var walkthrough: GuidedWalkthroughManager

    private let recommendedModelID = "unsloth/Qwen3.5-2B-GGUF"
    @State private var recommendedDetail: ModelDetails?
    @State private var recommendedQuant: QuantInfo?
    @State private var recommendedLoading = false
    @State private var recommendedLoadFailed = false
    @State private var recommendedProgress = 0.0
    @State private var recommendedSpeed = 0.0
    @State private var recommendedDownloading = false

    let totalPages = 4
    
    // Color Palette - Navy and White
    var navyBlue: Color {
        colorScheme == .dark ? Color(red: 173/255, green: 185/255, blue: 202/255) : Color(red: 20/255, green: 40/255, blue: 80/255)
    }
    
    var navyAccent: Color {
        colorScheme == .dark ? Color(red: 143/255, green: 165/255, blue: 192/255) : Color(red: 40/255, green: 60/255, blue: 100/255)
    }
    
    var backgroundColor: Color {
        colorScheme == .dark ? Color(red: 16/255, green: 20/255, blue: 28/255) : Color.white
    }
    
    var secondaryBackground: Color {
        colorScheme == .dark ? Color(red: 24/255, green: 30/255, blue: 42/255) : Color(red: 248/255, green: 250/255, blue: 252/255)
    }
    
    var textPrimary: Color {
        colorScheme == .dark ? Color.white : Color(red: 10/255, green: 20/255, blue: 40/255)
    }
    
    var textSecondary: Color {
        colorScheme == .dark ? Color(red: 180/255, green: 190/255, blue: 210/255) : Color(red: 100/255, green: 110/255, blue: 130/255)
    }
    
    var body: some View {
        ZStack {
            // Clean background
            backgroundColor
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Page content
                TabView(selection: $currentPage) {
                    ScrollView {
                        welcomePage
                            .padding(.vertical, 20)
                    }
                    .tag(0)
                    
                    ScrollView {
                        overviewPage
                            .padding(.vertical, 20)
                    }
                    .tag(1)
                    
                    ScrollView {
                        modelsPage
                            .padding(.vertical, 20)
                    }
                    .tag(2)
                    
                    ScrollView {
                        getStartedPage
                            .padding(.vertical, 20)
                    }
                    .tag(3)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: currentPage)
                
                // Navigation
                navigationView
                    .padding(.horizontal, 30)
                    .padding(.bottom, 50)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                logoScale = 1.0
            }
            withAnimation(.easeOut(duration: 1.0).delay(0.3)) {
                textOpacity = 1.0
                animateElements = true
            }
            // Ensure the embed installer reflects current disk state if the user reopens onboarding
            embedInstaller.refreshStateFromDisk()
            loadRecommendedModel()
        }
    }
    
    private var welcomePage: some View {
        VStack(spacing: 40) {
            Spacer()
            
            // Logo and title
            VStack(spacing: 24) {
                Image("Noema")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .scaleEffect(logoScale)
                
                VStack(spacing: 12) {
                    Text("Welcome to Noema")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .foregroundColor(textPrimary)
                        .opacity(textOpacity)
                    
                    Text("Your private AI workspace")
                        .font(.title3)
                        .foregroundColor(textSecondary)
                        .opacity(textOpacity)
                }
            }
            
            Spacer()
            
            // Key benefits
            VStack(spacing: 24) {
                benefitRow(
                    icon: "lock.shield",
                    title: "100% Private",
                    description: "Your data never leaves your device"
                )
                
                benefitRow(
                    icon: "cpu",
                    title: "Runs Locally",
                    description: "No cloud required"
                )
                
                benefitRow(
                    icon: "books.vertical",
                    title: "Smart Datasets",
                    description: "Add open textbooks and datasets to guide answers"
                )
            }
            .padding(.horizontal, 40)
            .opacity(animateElements ? 1 : 0)
            .animation(.easeOut(duration: 0.8).delay(0.4), value: animateElements)
            
            Spacer()
        }
    }
    
    private func benefitRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(navyBlue)
                .frame(width: 40, height: 40)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(textPrimary)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(textSecondary)
            }
            
            Spacer()
        }
    }
    
    private var overviewPage: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                Text("What is Noema?")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(textPrimary)
                
                Text("Think of Noema as a simple way to run AI on your device. To get useful answers, you pair a local model with datasets (like open textbooks). We’ll guide you through the first setup.")
                    .font(.body)
                    .foregroundColor(textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .lineSpacing(4)
            }
            .padding(.top, 40)
            
            onboardingImageView(keywords: ["Onboarding2", "overview", "interface", "home"], height: 200)
            
            VStack(spacing: 20) {
                Text("How it works")
                    .font(.headline)
                    .foregroundColor(textPrimary)
                
                VStack(alignment: .leading, spacing: 16) {
                    stepRow(number: "1", text: "Download AI models that run locally")
                    stepRow(number: "2", text: "Add datasets to enhance model knowledge")
                    stepRow(number: "3", text: "Chat with AI using your curated sources")
                }
                .padding(.horizontal, 40)
            }
            
            Spacer()
        }
        .opacity(animateElements ? 1 : 0)
        .animation(.easeOut(duration: 0.6), value: animateElements)
    }
    
    private func stepRow(number: String, text: String) -> some View {
        HStack(spacing: 16) {
            Text(number)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(navyBlue)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(navyBlue.opacity(0.1))
                )
            
            Text(text)
                .font(.body)
                .foregroundColor(textPrimary)
            
            Spacer()
        }
    }
    
    private var modelsPage: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                Text("Pick a model and add a dataset")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(textPrimary)
                
                Text("Start by installing one model. Then add a dataset (like an open textbook) so the AI can answer with grounded knowledge.")
                    .font(.body)
                    .foregroundColor(textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .padding(.top, 40)
            
            // Models section
            VStack(spacing: 20) {
                Text("Model Formats")
                    .font(.headline)
                    .foregroundColor(textPrimary)
                
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    modelFormatCard(icon: "cube", title: "GGUF", description: "Portable llama.cpp")
                    modelFormatCard(icon: "bolt", title: "MLX", description: "Apple Silicon speed")
                    modelFormatCard(icon: "rectangle.stack", title: "ET", description: "ExecuTorch runtime")
                    modelFormatCard(icon: "cpu", title: "CML", description: "Core ML runtime")
                }
                .padding(.horizontal, 30)
            }
            
            onboardingImageView(keywords: ["Onboarding3", "models", "model", "selection"], height: 150)
            
            // Datasets section
            VStack(spacing: 16) {
                Text("Enhance with Datasets")
                    .font(.headline)
                    .foregroundColor(textPrimary)
                
                Text("Add one or two datasets (like open textbooks) to keep responses accurate and help the AI cite sources.")
                    .font(.body)
                    .foregroundColor(textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .lineSpacing(4)
            }
            
            Spacer()
        }
        .opacity(animateElements ? 1 : 0)
        .animation(.easeOut(duration: 0.6), value: animateElements)
    }
    
    private func modelFormatCard(icon: String, title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(navyBlue)
            
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(textPrimary)
            
            Text(description)
                .font(.caption2)
                .foregroundColor(textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(secondaryBackground)
        .cornerRadius(8)
    }

    private var recommendedStarterModelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended Starter Model")
                .font(.headline)
                .foregroundColor(textPrimary)

            Text("Try the Qwen 3.5 2B GGUF build below. It's a good starting point and you can delete it anytime.")
                .font(.caption)
                .foregroundColor(textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = recommendedDetail, let quant = recommendedQuant {
                QuantRow(
                    canonicalID: detail.id,
                    info: quant,
                    progress: Binding(
                        get: {
                            if let item = downloadController.items.first(where: { $0.detail.id == detail.id && $0.quant.label == quant.label }) {
                                return item.progress
                            }
                            return recommendedProgress
                        },
                        set: { _ in }
                    ),
                    speed: Binding(
                        get: {
                            if let item = downloadController.items.first(where: { $0.detail.id == detail.id && $0.quant.label == quant.label }) {
                                return item.speed
                            }
                            return recommendedSpeed
                        },
                        set: { _ in }
                    ),
                    downloading: recommendedDownloading,
                    remoteMode: false,
                    remoteStatusText: nil,
                    remoteErrorText: nil,
                    remoteUnsupportedReason: nil,
                    remoteCompleted: false,
                    openUnavailableReason: nil,
                    showsLowQualityMarker: quant.isLowBitQuant,
                    downloadController: downloadController,
                    openAction: { await openRecommendedModel(detail: detail, quant: quant) },
                    downloadAction: { await downloadRecommendedModel(detail: detail, quant: quant) },
                    cancelAction: { cancelRecommendedDownload(detail: detail, quant: quant) }
                )
            } else if recommendedLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading recommendation…")
                        .font(.caption2)
                        .foregroundColor(textSecondary)
                }
            }

            if recommendedLoadFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn't load the recommended model.")
                        .font(.caption)
                        .foregroundColor(.red)
                    Button("Retry") { loadRecommendedModel(force: true) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var getStartedPage: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                Text("Get Started")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(textPrimary)
                
                Text("First, enable fast dataset search")
                    .font(.body)
                    .foregroundColor(textSecondary)
            }
            .padding(.top, 40)
            
            onboardingImageView(keywords: ["Onboarding4", "get-started", "getting-started", "setup", "start"], height: 180)
            
            // Embedding model download section
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Label("Enable dataset search", systemImage: "magnifyingglass")
                        .font(.headline)
                        .foregroundColor(textPrimary)
                    
                    Text("Download Qwen3 Embedding 0.6B so Noema can index and search your datasets")
                        .font(.caption)
                        .foregroundColor(textSecondary)
                        .multilineTextAlignment(.center)
                    
                    Text("640 MB • One-time download")
                        .font(.caption2)
                        .foregroundColor(textSecondary.opacity(0.8))
                }
                
                if embedInstaller.state == .ready {
                    Label(LocalizedStringKey("Downloaded"), systemImage: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundColor(.green)
                } else {
                    VStack(spacing: 12) {
                        Button(action: {
                            startEmbeddingDownload()
                        }) {
                            if isDownloadingEmbedModel {
                                HStack(spacing: 12) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .scaleEffect(0.8)
                                    Text(downloadStatusText)
                                        .font(.body)
                                }
                                .frame(width: 200)
                            } else {
                                Text("Download Now")
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .frame(width: 200)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(navyBlue)
                        .disabled(isDownloadingEmbedModel || embedInstaller.state == .ready)
                        
                        if isDownloadingEmbedModel && embedProgress > 0 {
                            ProgressView(value: embedProgress)
                                .frame(width: 240)
                                .tint(navyBlue)
                        }
                    }
                }

                Divider()
                    .padding(.top, 4)

                recommendedStarterModelSection

                Button(action: {
                    withAnimation(.easeInOut) {
                        showOnboarding = false
                    }
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                }) {
                    Text(embedInstaller.state == .ready ? "Start Using Noema" : "Skip for Now")
                        .font(.body)
                        .foregroundColor(embedInstaller.state == .ready ? navyBlue : textSecondary)
                }
                .padding(.top, 8)

                Button(action: beginGuidedWalkthrough) {
                    Text("I'm New to Local LLMs, Guide Me")
                        .font(.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(navyAccent)
                .padding(.top, 4)
            }
            .padding(24)
            .background(secondaryBackground)
            .cornerRadius(12)
            .padding(.horizontal, 30)
            
            Spacer()
        }
        .opacity(animateElements ? 1 : 0)
        .animation(.easeOut(duration: 0.6), value: animateElements)
        .onReceive(downloadController.itemsPublisher) { items in
            guard let detail = recommendedDetail, let quant = recommendedQuant else { return }
            if let item = items.first(where: { $0.detail.id == detail.id && $0.quant.label == quant.label }) {
                recommendedProgress = item.progress
                recommendedSpeed = item.speed
                if item.completed {
                    recommendedDownloading = false
                } else if let error = item.error, !error.isRetryable {
                    recommendedDownloading = false
                } else {
                    recommendedDownloading = true
                }
            } else {
                recommendedDownloading = false
                recommendedProgress = 0
                recommendedSpeed = 0
            }
        }
    }

    private func beginGuidedWalkthrough() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        withAnimation(.easeInOut) {
            showOnboarding = false
        }
        let delay = DispatchTime.now() + .milliseconds(450)
        DispatchQueue.main.asyncAfter(deadline: delay) {
            walkthrough.begin()
        }
    }

    private func loadRecommendedModel(force: Bool = false) {
        if recommendedLoading { return }
        if !force, recommendedDetail != nil { return }
        recommendedLoading = true
        recommendedLoadFailed = false
        if force || recommendedDetail == nil {
            recommendedDetail = nil
            recommendedQuant = nil
        }

        Task {
            do {
                let registry = ManualModelRegistry()
                let details = try await registry.details(for: recommendedModelID)
                if let quant = ManualModelRegistry.recommendedStarterQuant(in: details) {
                    await MainActor.run {
                        recommendedDetail = details
                        recommendedQuant = quant
                        recommendedLoading = false
                        recommendedLoadFailed = false
                    }
                } else {
                    await MainActor.run {
                        applyRecommendedFallback()
                        recommendedLoading = false
                        recommendedLoadFailed = true
                    }
                }
            } catch {
                await MainActor.run {
                    applyRecommendedFallback()
                    recommendedLoading = false
                    recommendedLoadFailed = true
                }
            }
        }
    }

    private func applyRecommendedFallback() {
        if let entry = ManualModelRegistry.defaultEntries.first(where: { $0.record.id == recommendedModelID }) {
            recommendedDetail = entry.details
            recommendedQuant = ManualModelRegistry.recommendedStarterQuant(in: entry.details)
        }
    }

    @MainActor
    private func downloadRecommendedModel(detail: ModelDetails, quant: QuantInfo) async {
        recommendedDownloading = true
        recommendedProgress = 0
        recommendedSpeed = 0
        downloadController.start(detail: detail, quant: quant)
    }

    private func cancelRecommendedDownload(detail: ModelDetails, quant: QuantInfo) {
        let id = "\(detail.id)-\(quant.label)"
        downloadController.cancel(itemID: id)
        recommendedDownloading = false
    }

    private func recommendedFileURL(for quant: QuantInfo, detailID: String) -> URL {
        InstalledModelsStore.localModelURL(for: quant, modelID: detailID)
    }

    @MainActor
    private func openRecommendedModel(detail: ModelDetails, quant: QuantInfo) async {
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

        tabRouter.selection = .chat
        withAnimation(.easeInOut) { showOnboarding = false }
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
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

        if let limit = budget, limit <= threeGiB, updated.gpuLayers < 0 {
            updated.gpuLayers = 0
        }

        return updated.normalizedForLocalModel(local)
    }

    private func onboardingImageView(keywords: [String], height: CGFloat) -> some View {
        Group {
            if let img = loadOnboardingImage(keywords: keywords) {
                img
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 30)
            } else {
                fallbackOnboardingImage()
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 30)
            }
        }
    }

    private func loadOnboardingImage(keywords: [String]) -> Image? {
        let candidateAssetNames: [String] = keywords.flatMap { key in
            let k = key
            return [
                k,
                "Onboarding_\(k)",
                "onboarding_\(k)",
                "Onboarding-\(k)",
                "onboarding-\(k)"
            ]
        }
#if canImport(UIKit)
        for name in candidateAssetNames {
            if let ui = UIImage(named: name) {
                return Image(platformImage: ui)
            }
        }
        if let urls = Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: "OnboardingImages") {
            let lowerKeywords = keywords.map { $0.lowercased() }
            let exts = Set(["png","jpg","jpeg","heic","heif","webp","gif","pdf"])
            if let url = urls.first(where: { url in
                exts.contains(url.pathExtension.lowercased()) &&
                lowerKeywords.contains(where: { url.lastPathComponent.lowercased().contains($0) })
            }) {
                if let img = UIImage(contentsOfFile: url.path) {
                    return Image(platformImage: img)
                }
            }
        }
#endif
#if canImport(AppKit)
        for name in candidateAssetNames {
            if let ns = NSImage(named: NSImage.Name(name)) {
                return Image(nsImage: ns)
            }
        }
        if let urls = Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: "OnboardingImages") {
            let lowerKeywords = keywords.map { $0.lowercased() }
            let exts = Set(["png","jpg","jpeg","heic","heif","webp","gif","pdf"])
            if let url = urls.first(where: { url in
                exts.contains(url.pathExtension.lowercased()) &&
                lowerKeywords.contains(where: { url.lastPathComponent.lowercased().contains($0) })
            }) {
                if let ns = NSImage(contentsOf: url) {
                    return Image(nsImage: ns)
                }
            }
        }
#endif
        return nil
    }
    
    private func fallbackOnboardingImage() -> Image {
#if canImport(UIKit)
        if let ui = UIImage(named: "Noema") {
            return Image(platformImage: ui)
        }
#endif
#if canImport(AppKit)
        if let ns = NSImage(named: NSImage.Name("Noema")) {
            return Image(nsImage: ns)
        }
#endif
        return Image(systemName: "photo.on.rectangle.angled")
    }
    
    private var downloadStatusText: String {
        switch embedInstaller.state {
        case .downloading:
            return "Downloading..."
        case .verifying:
            return "Verifying..."
        case .installing:
            return "Installing..."
        default:
            return "Preparing..."
        }
    }
    
    private func startEmbeddingDownload() {
        if embedInstaller.state == .ready {
            return
        }
        EmbeddingModelCatalog.setActiveRecordID(EmbeddingModelCatalog.defaultModelID)
        if FileManager.default.fileExists(atPath: onboardingEmbeddingModelURL.path) {
            embedInstaller.refreshStateFromDisk()
            return
        }
        isDownloadingEmbedModel = true
        embedProgress = 0

        // Create a timer to smoothly update progress
        let progressTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
        var timerCancellable: AnyCancellable?
        
        timerCancellable = progressTimer.sink { _ in
            if self.embedInstaller.state == .downloading {
                self.embedProgress = self.embedInstaller.progress
            }
        }
        
        Task { @MainActor in
            await embedInstaller.installIfNeeded()
            
            // Cancel the timer
            timerCancellable?.cancel()
            
            // Ensure final progress
            embedProgress = embedInstaller.state == .ready ? 1.0 : embedProgress
            
            // After installation completes, proactively load & warm up the backend
            if embedInstaller.state == .ready {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000) // brief delay to ensure FS move complete
                    await EmbeddingModel.shared.warmUp()
                } catch {
                    // Ignore; UI already reflects installer state
                }
            }
            
            isDownloadingEmbedModel = false
        }
    }
    
    private var navigationView: some View {
        HStack {
            // Skip button (except on last page)
            if currentPage < totalPages - 1 {
                Button("Skip") {
                    withAnimation {
                        showOnboarding = false
                    }
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                }
                .foregroundColor(textSecondary)
            } else {
                Spacer()
                    .frame(width: 60)
            }
            
            Spacer()
            
            // Page indicators
            HStack(spacing: 8) {
                ForEach(0..<totalPages, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? navyBlue : textSecondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .scaleEffect(index == currentPage ? 1.2 : 1)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: currentPage)
                }
            }
            
            Spacer()
            
            // Next button
            if currentPage < totalPages - 1 {
                Button("Next") {
                    withAnimation {
                        currentPage += 1
                        animateElements = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            animateElements = true
                        }
                    }
                }
                .fontWeight(.medium)
                .foregroundColor(navyBlue)
            } else {
                Spacer()
                    .frame(width: 60)
            }
        }
    }

    private var onboardingEmbeddingModelURL: URL {
        EmbeddingModelCatalog.record(for: EmbeddingModelCatalog.defaultModelID)?.installedURL ?? EmbeddingModel.modelURL
    }
}
#Preview {
    OnboardingView(showOnboarding: .constant(true))
}
#endif
