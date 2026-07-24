#if canImport(UIKit)
import SwiftUI
import Combine
import Foundation
import UIKit
#if canImport(AppKit)
import AppKit
#endif

private struct FLPressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

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

    // MARK: First Light flow state
    enum Act: Int, CaseIterable { case ignition, fork, chat, dark, constellation, handoff, console, grid, open }
    @State private var act: Act = .ignition
    @AppStorage("isAdvancedMode") private var isAdvancedMode = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ignited = false
    @State private var streamedText = ""
    @State private var reasoningDone = false
    @State private var selectedEngine = "GGUF"

    let totalPages = 4
    
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
    
    private var flSpring: Animation { reduceMotion ? .easeInOut(duration: 0.28) : .spring(response: 0.34, dampingFraction: 0.84) }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            // "The Dark" privacy beat dims the whole canvas to near-black.
            Color.black
                .opacity(act == .dark ? 0.94 : 0)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: act)

            actContent
                .padding(.horizontal, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Persistent "Skip to setup" escape on the simple path.
            if !isAdvancedMode, act != .ignition, act != .fork {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { isAdvancedMode = true; act = .console }) {
                            Text("Skip to setup ›").font(.footnote)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(textSecondary)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    Spacer()
                }
                .padding(.top, 8).padding(.trailing, 16)
                .transition(.opacity)
            }

            // Bottom control bar (Back + progress) for the narrative acts.
            if act != .handoff, act != .open {
                VStack {
                    Spacer()
                    controlBar.padding(.horizontal, 28).padding(.bottom, 30)
                }
            }
        }
        .animation(flSpring, value: act)
        .onAppear {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.4) : .spring(response: 0.6, dampingFraction: 0.72)) {
                ignited = true
            }
            embedInstaller.refreshStateFromDisk()
            loadRecommendedModel()
        }
    }

    @ViewBuilder private var actContent: some View {
        switch act {
        case .ignition: ignitionAct
        case .fork: forkAct
        case .chat: livingChatAct
        case .dark: theDarkAct
        case .constellation: constellationAct
        case .handoff: handoffAct
        case .console: consoleAct
        case .grid: capabilitiesGridAct
        case .open: openNoemaAct
        }
    }
    
    private var welcomePage: some View {
        VStack(spacing: 40) {
            Spacer()

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
                            DownloadCapsuleBar(value: embedProgress, tint: navyBlue)
                                .frame(width: 240)
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

    // MARK: - First Light acts

    private var actSequence: [Act] {
        isAdvancedMode ? [.ignition, .fork, .console, .grid, .open]
                       : [.ignition, .fork, .chat, .dark, .constellation, .handoff]
    }
    private var actIndex: Int { actSequence.firstIndex(of: act) ?? 0 }

    private func flAdvance() {
        let s = actSequence
        guard let i = s.firstIndex(of: act), i + 1 < s.count else { return }
        act = s[i + 1]
        if act == .chat { runScriptedStream() }
    }
    private func flBack() {
        let s = actSequence
        guard let i = s.firstIndex(of: act), i > 0 else { return }
        act = s[i - 1]
    }
    private func flPick(advanced: Bool) {
        isAdvancedMode = advanced
        #if os(iOS)
        Haptics.impact(.medium)
        #endif
        act = advanced ? .console : .chat
        if act == .chat { runScriptedStream() }
    }
    private func flSkipExit() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        withAnimation(.easeInOut) { showOnboarding = false }
    }
    private func flFinishPower() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        let dest: MainTab = modelManager.downloadedModels.isEmpty ? .explore : .stored
        withAnimation(.easeInOut) { showOnboarding = false }
        tabRouter.selection = dest
    }

    private func runScriptedStream() {
        streamedText = ""
        reasoningDone = false
        let full = "Your prompt and the model both stay on your device. Nothing is sent to a server — the AI runs in your phone's own memory."
        if reduceMotion {
            reasoningDone = true
            streamedText = full
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard act == .chat else { return }
            withAnimation { reasoningDone = true }
            for word in full.split(separator: " ").map(String.init) {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard act == .chat else { return }
                streamedText += (streamedText.isEmpty ? "" : " ") + word
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            if actIndex > 0 {
                Button(action: flBack) {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Back") }
                }
                .buttonStyle(.plain).foregroundColor(textSecondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<actSequence.count, id: \.self) { i in
                    Capsule()
                        .fill(i == actIndex ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: i == actIndex ? 18 : 7, height: 7)
                }
            }
            Spacer()
            if act != .fork {
                Button(action: flAdvance) {
                    Text(act == .ignition ? "Begin" : "Continue").fontWeight(.semibold)
                }
                .buttonStyle(.plain).foregroundColor(.accentColor)
            } else {
                Color.clear.frame(width: 44, height: 1)
            }
        }
        .font(.subheadline)
    }

    private func featurePill(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 6) { Image(systemName: icon); Text(label) }
            .font(.caption)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .foregroundColor(.accentColor)
    }

    private var ignitionAct: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("Noema")
                .resizable().scaledToFit()
                .frame(width: 94, height: 94)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .scaleEffect(ignited ? 1 : 0.6)
                .opacity(ignited ? 1 : 0)
            Text("Noema").font(.system(size: 34, weight: .semibold)).foregroundColor(textPrimary).opacity(ignited ? 1 : 0)
            Text("It runs here. Watch.").font(.title3).foregroundColor(textSecondary).opacity(ignited ? 1 : 0)
            featurePill("iphone", "On-device").opacity(ignited ? 1 : 0).padding(.top, 2)
            Spacer()
            Text("Tap to begin").font(.footnote).foregroundColor(textSecondary.opacity(0.7))
                .padding(.bottom, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { flAdvance() }
        .transition(.opacity)
    }

    private func doorCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 22)).foregroundColor(.accentColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundColor(textPrimary)
                    Text(subtitle).font(.caption).foregroundColor(textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(secondaryBackground))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.08)))
        }
        .buttonStyle(FLPressableStyle())
    }

    private var forkAct: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("FIRST, ONE CHOICE").font(.caption).tracking(1.4).foregroundColor(textSecondary)
            Text("How do you want to meet Noema?").font(.system(size: 26, weight: .semibold)).foregroundColor(textPrimary)
            doorCard(icon: "sparkles", title: "Show me around", subtitle: "Learn by doing — I'll walk you through it") { flPick(advanced: false) }
                .padding(.top, 6)
            doorCard(icon: "slider.horizontal.3", title: "I know my way around", subtitle: "Skip to setup · engine · quant · context · backends") { flPick(advanced: true) }
            Text("This sets the app's mode — you can flip it anytime in Settings.")
                .font(.caption2).foregroundColor(textSecondary.opacity(0.8)).padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
    }

    private var livingChatAct: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text("IT'S ALREADY RUNNING").font(.caption).tracking(1.4).foregroundColor(textSecondary)
            Text("A real answer, on your phone").font(.system(size: 24, weight: .semibold)).foregroundColor(textPrimary)
            HStack(spacing: 8) { featurePill("globe", "Web"); featurePill("photo", "Vision"); featurePill("mic", "Voice") }
            VStack(alignment: .leading, spacing: 10) {
                Label("Explain how on-device AI keeps my data private", systemImage: "person.fill")
                    .font(.subheadline).foregroundColor(textSecondary)
                HStack(spacing: 7) {
                    Image(systemName: reasoningDone ? "checkmark" : "ellipsis").font(.caption)
                    Text(reasoningDone ? "Reasoning complete" : "Thinking…").font(.caption)
                }
                .foregroundColor(textSecondary)
                Text(streamedText.isEmpty ? " " : streamedText)
                    .font(.body).foregroundColor(textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.12), value: streamedText)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(secondaryBackground))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .transition(.opacity)
        .onAppear { if streamedText.isEmpty { runScriptedStream() } }
    }

    private var theDarkAct: some View {
        let local = ["Model", "Dataset", "Memory", "Python"]
        let blocked = ["Web", "Cloud"]
        return VStack(spacing: 16) {
            Spacer()
            Text("FLIP ONE SWITCH").font(.caption).tracking(1.4).foregroundColor(Color.green.opacity(0.8))
            Text("Nothing left your device.").font(.system(size: 28, weight: .semibold)).foregroundColor(.white)
            Text("Off-grid blocks every network path — and proves it.")
                .font(.subheadline).foregroundColor(.white.opacity(0.7)).multilineTextAlignment(.center)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(local, id: \.self) { darkBadge($0, "Local", color: .green) }
                ForEach(blocked, id: \.self) { darkBadge($0, "Blocked", color: .red) }
            }
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
    private func darkBadge(_ name: String, _ state: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: color == .green ? "lock.fill" : "xmark.circle.fill").font(.caption2)
            Text("\(name) · \(state)").font(.caption)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.18)))
        .foregroundColor(color == .green ? Color.green : Color(red: 0.95, green: 0.6, blue: 0.5))
    }

    private var constellationAct: some View {
        let nodes: [(String, String)] = [
            ("doc.text.magnifyingglass", "Chat your docs"), ("shippingbox", "Knowledge Packs"),
            ("magnifyingglass", "Explore models"), ("function", "Real tools"),
            ("waveform", "Voice notes"), ("bolt", "Siri + Shortcuts"),
            ("square.grid.2x2", "Live Activities"), ("building.2", "Teams")
        ]
        return VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("EVERYTHING IT CAN DO").font(.caption).tracking(1.4).foregroundColor(textSecondary)
            Text("And so much more").font(.system(size: 24, weight: .semibold)).foregroundColor(textPrimary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(nodes, id: \.1) { n in
                    HStack(spacing: 7) {
                        Image(systemName: n.0).foregroundColor(.accentColor)
                        Text(n.1).font(.caption).foregroundColor(textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(secondaryBackground))
                }
            }
            Text("5 engines · iPhone · iPad · Mac · Vision Pro")
                .font(.caption2).foregroundColor(textSecondary).padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private var embedCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Document memory").font(.subheadline).fontWeight(.medium).foregroundColor(textPrimary)
                Text("For chatting your files · 640 MB").font(.caption).foregroundColor(textSecondary)
            }
            Spacer()
            if embedInstaller.state == .ready {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else if isDownloadingEmbedModel {
                DownloadCapsuleBar(value: embedProgress, tint: navyBlue).frame(width: 70)
            } else {
                Button("Enable") { startEmbeddingDownload() }.buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(secondaryBackground))
    }

    private var handoffAct: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("LET'S GET YOU SET").font(.caption).tracking(1.4).foregroundColor(textSecondary)
                Text("One starter model, then you're in").font(.system(size: 22, weight: .semibold)).foregroundColor(textPrimary)
                recommendedStarterModelSection
                embedCard
                Button(action: beginGuidedWalkthrough) {
                    Text("Take the tour").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: flSkipExit) {
                    Text("Skip, I'll explore myself").font(.subheadline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain).foregroundColor(textSecondary)
            }
            .padding(.top, 40).padding(.bottom, 40)
        }
        .transition(.opacity)
    }

    private var consoleAct: some View {
        let engines = ["GGUF", "MLX", "Core ML", "ExecuTorch", "Apple"]
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("POWER SETUP").font(.caption).tracking(1.4).foregroundColor(textSecondary)
                Text("Engine · quant · context").font(.system(size: 22, weight: .semibold)).foregroundColor(textPrimary)
                Text("Inference engine — auto-picked for your device").font(.caption).foregroundColor(textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(engines, id: \.self) { e in
                        Text(e).font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(Capsule().fill(selectedEngine == e ? Color.accentColor.opacity(0.16) : secondaryBackground))
                            .overlay(Capsule().stroke(selectedEngine == e ? Color.accentColor : Color.primary.opacity(0.08)))
                            .foregroundColor(selectedEngine == e ? .accentColor : textPrimary)
                            .onTapGesture { selectedEngine = e }
                    }
                }
                recommendedStarterModelSection
                Text("Adjust context length, GPU layers, KV-cache, presets, and connect remote backends or a Mac Relay anytime in Model Settings.")
                    .font(.caption).foregroundColor(textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 40).padding(.bottom, 110)
        }
        .transition(.opacity)
    }

    private var capabilitiesGridAct: some View {
        let cells: [(String, String)] = [
            ("magnifyingglass", "Explore + import"), ("doc.text", "Datasets + RAG"),
            ("wrench.and.screwdriver", "Tool Store"), ("shield.lefthalf.filled", "Privacy recorder"),
            ("server.rack", "Remote + Relay"), ("stethoscope", "Model Doctor")
        ]
        return VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("JUMP ANYWHERE").font(.caption).tracking(1.4).foregroundColor(textSecondary)
            Text("Every capability, one tap away").font(.system(size: 22, weight: .semibold)).foregroundColor(textPrimary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                ForEach(cells, id: \.1) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: c.0).foregroundColor(.accentColor)
                        Text(c.1).font(.caption).foregroundColor(textPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(secondaryBackground))
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private var openNoemaAct: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundColor(.green)
            Text("You're set up").font(.system(size: 26, weight: .semibold)).foregroundColor(textPrimary)
            Text("\(selectedEngine) · Balanced preset").font(.subheadline).foregroundColor(textSecondary)
            Button(action: flFinishPower) {
                Text("Open Noema").fontWeight(.semibold).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).padding(.top, 8).padding(.horizontal, 40)
            Button(action: { isAdvancedMode = false; act = .handoff }) {
                Text("Replay guided tour").font(.subheadline)
            }
            .buttonStyle(.plain).foregroundColor(textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
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
                isVision = ETModelResolver.isVisionIdentifier(slug)
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
                kvCacheEstimate: kvCacheEstimate,
                runtimeConfiguration: .resolved(from: updated, modelURL: local.url)
            )
            if !fits {
                if let maxContext = ModelRAMAdvisor.maxContextUnderBudget(
                    format: quant.format,
                    sizeBytes: usableSize,
                    layerCount: layerCount,
                    moeInfo: local.moeInfo,
                    upperBound: modelMaxContext,
                    kvCacheEstimate: kvCacheEstimate,
                    runtimeConfiguration: .resolved(from: updated, modelURL: local.url)
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
    
    private var downloadStatusText: LocalizedStringKey {
        switch embedInstaller.state {
        case .downloading:
            return "Downloading…"
        case .verifying:
            return "Verifying…"
        case .installing:
            return "Installing…"
        default:
            return "Preparing…"
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
