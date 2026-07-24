#if os(visionOS)
import SwiftUI
import UIKit
import RollingThought

/// Hosts the main tabs on visionOS, mirroring the iOS `MainView` hierarchy so
/// both platforms stay in sync while letting the visionOS scene supply shared
/// model objects.
struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @EnvironmentObject private var tabRouter: TabRouter
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @EnvironmentObject private var downloadController: DownloadController
    @EnvironmentObject private var walkthrough: GuidedWalkthroughManager
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("offGrid") private var offGrid = false
    @AppStorage("visionVerticalPanelLayout") private var useVerticalPanelLayout = false
    @AppStorage("storedPanelWindowActive") private var storedPanelWindowActive = false
    @AppStorage("storedPanelWindowCount") private var storedPanelWindowCount = 0
    @State private var didAutoLoad = false
    @State private var storedPanelLaunchInFlight = false // Legacy flag kept for state compatibility; now mirrors pending reopen work items.
    @State private var storedPanelRefreshWorkItem: DispatchWorkItem?

    private let storedPanelPlacementDelay: TimeInterval = 0.2

    private var colorScheme: ColorScheme? { VisionAppearance.forcedScheme(for: appearance) }

    private let mainGuideSteps: Set<GuidedWalkthroughManager.Step> = [
        .chatIntro,
        .chatSidebar,
        .chatNewChat,
        .chatInput,
        .chatWebSearch,
        .storedIntro,
        .storedRecommend,
        .storedFormats,
        .storedDatasets,
        .exploreIntro,
        .exploreDatasets,
        .exploreImport,
        .exploreSwitchToModels,
        .exploreModelTypes,
        .exploreMLX,
        .exploreET,
        .settingsIntro,
        .settingsHighlights,
        .completed
    ]

    var body: some View {
        Group {
            if useVerticalPanelLayout {
                tabLayout(includeStored: false)
            } else {
                tabLayout(includeStored: true)
            }
        }
        .visionAppearance(colorScheme)
        .ornament(attachmentAnchor: .scene(.bottomLeading)) {
            DownloadOverlay()
                .environmentObject(downloadController)
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            if useVerticalPanelLayout {
                Button {
                    reopenStoredPanel()
                } label: {
                    Label(LocalizedStringKey("Open Stored"), systemImage: "externaldrive")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 12)
            }
        }
        .onPreferenceChange(GuidedHighlightPreferenceKey.self) { anchors in
            walkthrough.updateAnchors(anchors)
        }
        .overlay(alignment: .top) {
            TopNotificationStack(
                datasetManager: datasetManager,
                modelManager: modelManager,
                loadingTracker: chatVM.loadingProgressTracker
            )
            .padding(.top, UIDevice.current.userInterfaceIdiom == .pad ? 60 : 8)
        }
        .overlay {
            GuidedWalkthroughOverlay(allowedSteps: mainGuideSteps)
                .environmentObject(walkthrough)
        }
        .overlay { DownloadPopupOverlay() }
        .onAppear {
            modelManager.bind(datasetManager: datasetManager)
            downloadController.configure(modelManager: modelManager, datasetManager: datasetManager)
            downloadController.bootstrapIfNeeded()
            datasetManager.bind(downloadController: downloadController)
            chatVM.modelManager = modelManager
            chatVM.datasetManager = datasetManager
            Task { await autoLoad() }
            let sanitized = sanitizedSelection(tabRouter.selection)
            if sanitized != tabRouter.selection {
                tabRouter.selection = sanitized
            }
            if let keys = UserDefaults.standard.array(forKey: "RollingThought.Keys") as? [String] {
                for key in keys {
                    let storageKey = "RollingThought." + key
                    if let existing = chatVM.rollingThoughtViewModels[key] {
                        existing.loadState(forKey: storageKey)
                    } else {
                        let vm = RollingThoughtViewModel()
                        vm.loadState(forKey: storageKey)
                        chatVM.rollingThoughtViewModels[key] = vm
                    }
                }
            }
            if !storedPanelWindowActive && storedPanelWindowCount > 0 {
                storedPanelWindowCount = 0
            }
            updateStoredPanelWindow(forceRecreation: true)
        }
        .onChange(of: offGrid) { on in
            NetworkKillSwitch.setEnabled(on)
            let sanitized = sanitizedSelection(tabRouter.selection)
            if sanitized != tabRouter.selection {
                tabRouter.selection = sanitized
            }
        }
        .onChange(of: useVerticalPanelLayout) { _ in
            let sanitized = sanitizedSelection(tabRouter.selection)
            if sanitized != tabRouter.selection {
                tabRouter.selection = sanitized
            }
            updateStoredPanelWindow(forceRecreation: true)
        }
        .onChangeCompat(of: tabRouter.selection) { oldValue, newValue in
            if oldValue != .chat,
               newValue == .chat,
               chatVM.loading || chatVM.stillLoading,
               !chatVM.canAcceptChatInput {
                tabRouter.selection = oldValue
                Task { await logger.log("[UI][Tab] blocked chat switch while model loading") }
                return
            }
            let sanitized = sanitizedSelection(newValue)
            if sanitized != newValue {
                tabRouter.selection = sanitized
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                let keys = Array(chatVM.rollingThoughtViewModels.keys)
                UserDefaults.standard.set(keys, forKey: "RollingThought.Keys")
                for (key, vm) in chatVM.rollingThoughtViewModels {
                    vm.saveState(forKey: "RollingThought." + key)
                }
            } else if phase == .active {
                updateStoredPanelWindow(forceRecreation: true)
            }
        }
        .onChangeCompat(of: storedPanelWindowActive) { _, isActive in
            storedPanelRefreshWorkItem?.cancel()
            storedPanelRefreshWorkItem = nil

            if isActive {
                storedPanelLaunchInFlight = false
            } else {
                storedPanelLaunchInFlight = false
                if useVerticalPanelLayout && storedPanelWindowCount == 0 {
                    scheduleStoredPanelOpen()
                }
            }
        }
        .onChangeCompat(of: storedPanelWindowCount) { _, count in
            if count == 0 {
                storedPanelWindowActive = false
            }
        }
    }

    @ViewBuilder
    private func tabLayout(includeStored: Bool) -> some View {
        TabView(selection: $tabRouter.selection) {
            tabContent(for: .chat)
                .tag(MainTab.chat)
                .tabItem { Label(tabTitle(for: .chat), systemImage: tabSystemImage(for: .chat)) }

            if includeStored {
                tabContent(for: .stored)
                    .tag(MainTab.stored)
                    .tabItem { Label(tabTitle(for: .stored), systemImage: tabSystemImage(for: .stored)) }
            }

            if !offGrid {
                tabContent(for: .explore)
                    .tag(MainTab.explore)
                    .tabItem { Label(tabTitle(for: .explore), systemImage: tabSystemImage(for: .explore)) }
            }

            tabContent(for: .tools)
                .tag(MainTab.tools)
                .tabItem { Label(tabTitle(for: .tools), systemImage: tabSystemImage(for: .tools)) }

            tabContent(for: .settings)
                .tag(MainTab.settings)
                .tabItem { Label(tabTitle(for: .settings), systemImage: tabSystemImage(for: .settings)) }
        }
    }

    @ViewBuilder
    private func tabContent(for tab: MainTab) -> some View {
        switch tab {
        case .chat:
            ChatView()
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(tabRouter)
                .environmentObject(downloadController)
                .environmentObject(walkthrough)
        case .stored:
            StoredView()
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(tabRouter)
                .environmentObject(downloadController)
                .environmentObject(walkthrough)
        case .explore:
            ExploreContainerView()
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(tabRouter)
                .environmentObject(downloadController)
                .environmentObject(walkthrough)
        case .tools:
            ToolsHubView()
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(tabRouter)
                .environmentObject(downloadController)
                .environmentObject(walkthrough)
        case .settings:
            SettingsView()
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(tabRouter)
                .environmentObject(downloadController)
                .environmentObject(walkthrough)
        }
    }

    private func tabTitle(for tab: MainTab) -> LocalizedStringKey {
        switch tab {
        case .chat:
            return "Chat"
        case .stored:
            return "Stored"
        case .explore:
            return "Explore"
        case .tools:
            return "Tools"
        case .settings:
            return "Settings"
        }
    }

    private func tabSystemImage(for tab: MainTab) -> String {
        switch tab {
        case .chat:
            return "message.fill"
        case .stored:
            return "externaldrive"
        case .explore:
            return "safari"
        case .tools:
            return "wrench.and.screwdriver"
        case .settings:
            return "gearshape"
        }
    }

    private func sanitizedSelection(_ proposed: MainTab) -> MainTab {
        if useVerticalPanelLayout && proposed == .stored {
            return .chat
        }
        if offGrid && proposed == .explore {
            return .chat
        }
        return proposed
    }

    private func updateStoredPanelWindow(forceRecreation: Bool = false) {
        if let workItem = storedPanelRefreshWorkItem {
            workItem.cancel()
            storedPanelRefreshWorkItem = nil
            storedPanelLaunchInFlight = false
        }

        guard useVerticalPanelLayout else {
            dismissWindow(id: VisionSceneID.storedPanelWindow)
            return
        }

        if storedPanelWindowActive || storedPanelWindowCount > 0 {
            if forceRecreation {
                dismissWindow(id: VisionSceneID.storedPanelWindow)
                scheduleStoredPanelOpen(after: storedPanelPlacementDelay)
            }
            return
        }

        if storedPanelLaunchInFlight {
            return
        }

        scheduleStoredPanelOpen()
    }

    private func scheduleStoredPanelOpen(after delay: TimeInterval? = nil) {
        if let workItem = storedPanelRefreshWorkItem {
            workItem.cancel()
            storedPanelRefreshWorkItem = nil
            storedPanelLaunchInFlight = false
        }

        guard storedPanelWindowCount == 0, !storedPanelLaunchInFlight else { return }

        let reopen = DispatchWorkItem {
            guard storedPanelWindowCount == 0 else {
                storedPanelRefreshWorkItem = nil
                return
            }
            openWindow(id: VisionSceneID.storedPanelWindow)
            storedPanelRefreshWorkItem = nil
        }
        storedPanelRefreshWorkItem = reopen
        storedPanelLaunchInFlight = true
        let openDelay = delay ?? storedPanelPlacementDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: reopen)
    }

    private func reopenStoredPanel() {
        guard useVerticalPanelLayout else { return }

        storedPanelRefreshWorkItem?.cancel()
        storedPanelRefreshWorkItem = nil

        if storedPanelWindowActive || storedPanelWindowCount > 0 {
            dismissWindow(id: VisionSceneID.storedPanelWindow)
        }

        storedPanelWindowCount = 0
        storedPanelWindowActive = false
        storedPanelLaunchInFlight = false

        scheduleStoredPanelOpen(after: storedPanelPlacementDelay)
    }

    @MainActor
    private func autoLoad() async {
        guard !didAutoLoad else { return }
        didAutoLoad = true

        await StartupLoader.performStartupLoad(chatVM: chatVM, modelManager: modelManager, offGrid: offGrid)
    }
}

/// Vision-specific wrapper around the shared tab hierarchy. The iOS
/// implementation owns its view models via `@StateObject`, while the visionOS
/// scene receives them from the app entry point so they can also drive the
/// immersive space. This view therefore observes the supplied objects without
/// taking ownership.
struct ContentView: View {
    private let mode: VisionWindowMode
    @ObservedObject private var tabRouter: TabRouter
    @ObservedObject private var chatVM: ChatVM
    @ObservedObject private var modelManager: AppModelManager
    @ObservedObject private var datasetManager: DatasetManager
    @ObservedObject private var downloadController: DownloadController
    @ObservedObject private var walkthroughManager: GuidedWalkthroughManager

    @State private var showSplash: Bool
    @State private var showOnboarding = false
    @State private var didConfigure = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init(
        mode: VisionWindowMode,
        tabRouter: TabRouter,
        chatVM: ChatVM,
        modelManager: AppModelManager,
        datasetManager: DatasetManager,
        downloadController: DownloadController,
        walkthroughManager: GuidedWalkthroughManager
    ) {
        self.mode = mode
        _showSplash = State(initialValue: mode == .planar)
        _tabRouter = ObservedObject(wrappedValue: tabRouter)
        _chatVM = ObservedObject(wrappedValue: chatVM)
        _modelManager = ObservedObject(wrappedValue: modelManager)
        _datasetManager = ObservedObject(wrappedValue: datasetManager)
        _downloadController = ObservedObject(wrappedValue: downloadController)
        _walkthroughManager = ObservedObject(wrappedValue: walkthroughManager)
    }

    var body: some View {
        ZStack {
            MainView()
                .environmentObject(tabRouter)
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(downloadController)
                .environmentObject(walkthroughManager)
                .glassBackgroundEffect()

            if showSplash {
                SplashView()
                    .transition(.opacity)
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { mode == .planar && showOnboarding },
                set: { showOnboarding = $0 }
            )
        ) {
            OnboardingView(showOnboarding: $showOnboarding)
                .environmentObject(tabRouter)
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(downloadController)
                .environmentObject(walkthroughManager)
        }
        .onAppear(perform: configureOnce)
    }

    private func configureOnce() {
        guard !didConfigure else { return }
        didConfigure = true
        walkthroughManager.configure(tabRouter: tabRouter,
                                      chatVM: chatVM,
                                      modelManager: modelManager,
                                      datasetManager: datasetManager,
                                      downloadController: downloadController)

        guard mode == .planar else {
            showSplash = false
            return
        }
        print("[Noema] visionOS app launched 🚀")

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation {
                showSplash = false
                if !hasCompletedOnboarding {
                    showOnboarding = true
                }
            }
        }
    }
}

/// Splash screen used on visionOS to mirror the iOS experience.
private struct SplashView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image("Noema")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
    }
}

struct StoredPanelWindow: View {
    @AppStorage("storedPanelWindowActive") private var storedPanelWindowActive = false
    @AppStorage("storedPanelWindowCount") private var storedPanelWindowCount = 0
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.dismiss) private var dismiss

    @State private var hasRegisteredWindow = false

    private var colorScheme: ColorScheme? { VisionAppearance.forcedScheme(for: appearance) }

    var body: some View {
        VisionStoredPanel()
            .frame(width: 520, height: 620)
            .glassBackgroundEffect()
            .visionAppearance(colorScheme)
            .onAppear {
                guard !hasRegisteredWindow else { return }
                if storedPanelWindowCount > 0 {
                    DispatchQueue.main.async {
                        dismiss()
                    }
                    return
                }
                hasRegisteredWindow = true
                storedPanelWindowCount = 1
                storedPanelWindowActive = true
            }
            .onDisappear {
                guard hasRegisteredWindow else { return }
                hasRegisteredWindow = false
                storedPanelWindowCount = max(0, storedPanelWindowCount - 1)
                storedPanelWindowActive = storedPanelWindowCount > 0
            }
    }
}

private struct DownloadPopupOverlay: View {
    @EnvironmentObject private var downloadController: DownloadController

    var body: some View {
        Group {
            if downloadController.showPopup {
                ZStack {
                    Color.black.opacity(0.2)
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { downloadController.closeList() }

                    DownloadListPopup(onClose: { downloadController.closeList() })
                        .environmentObject(downloadController)
                        .frame(maxWidth: 520)
                        .padding(32)
                        .background(
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .fill(.thinMaterial)
                        )
                        .glassBackgroundEffect()
                        .shadow(radius: 24)
                }
                .zIndex(1)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: downloadController.showPopup)
    }
}

#endif
