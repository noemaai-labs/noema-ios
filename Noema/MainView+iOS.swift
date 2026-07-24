import SwiftUI
import RollingThought
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit) && !os(visionOS)
typealias ChatView = MessageView.ChatView

/// Hosts the main tabs with the default system tab bar.
struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var tabRouter: TabRouter
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @EnvironmentObject private var downloadController: DownloadController
    @EnvironmentObject private var walkthrough: GuidedWalkthroughManager
    @AppStorage("offGrid") private var offGrid = false
    @State private var didAutoLoad = false
    @StateObject private var backgroundUnloadController = BackgroundModelUnloadController()

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
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $tabRouter.selection) {
                ChatView()
                    .tag(MainTab.chat)
                    .environmentObject(chatVM)
                    .environmentObject(modelManager)
                    .environmentObject(datasetManager)
                    .environmentObject(tabRouter)
                    .environmentObject(downloadController)
                    .environmentObject(walkthrough)
                    .tabItem { Label(LocalizedStringKey("Chat"), systemImage: "message.fill") }

                StoredView()
                    .tag(MainTab.stored)
                    .environmentObject(chatVM)
                    .environmentObject(modelManager)
                    .environmentObject(datasetManager)
                    .environmentObject(tabRouter)
                    .environmentObject(downloadController)
                    .environmentObject(walkthrough)
                    .tabItem { Label(LocalizedStringKey("Stored"), systemImage: "externaldrive") }

                if !offGrid {
                    ExploreContainerView()
                        .tag(MainTab.explore)
                        .environmentObject(chatVM)
                        .environmentObject(modelManager)
                        .environmentObject(datasetManager)
                        .environmentObject(tabRouter)
                        .environmentObject(downloadController)
                        .environmentObject(walkthrough)
                        .tabItem { Label(LocalizedStringKey("Explore"), systemImage: "safari") }
                }

                ToolsHubView()
                    .tag(MainTab.tools)
                    .environmentObject(chatVM)
                    .environmentObject(modelManager)
                    .environmentObject(datasetManager)
                    .environmentObject(tabRouter)
                    .environmentObject(downloadController)
                    .environmentObject(walkthrough)
                    .tabItem { Label(LocalizedStringKey("Tools"), systemImage: "wrench.and.screwdriver") }

                SettingsView()
                    .tag(MainTab.settings)
                    .environmentObject(chatVM)
                    .environmentObject(modelManager)
                    .environmentObject(datasetManager)
                    .environmentObject(tabRouter)
                    .environmentObject(downloadController)
                    .environmentObject(walkthrough)
                    .tabItem { Label(LocalizedStringKey("Settings"), systemImage: "gearshape") }
            }

            DownloadOverlay()
                .environmentObject(downloadController)
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
        .sheet(isPresented: $downloadController.showPopup) {
            DownloadListPopup()
                .environmentObject(downloadController)
                .presentationDetents([.fraction(0.5)])
        }
        .onAppear {
            modelManager.bind(datasetManager: datasetManager)
            downloadController.configure(modelManager: modelManager, datasetManager: datasetManager)
            downloadController.bootstrapIfNeeded()
            datasetManager.bind(downloadController: downloadController)
            chatVM.modelManager = modelManager
            chatVM.datasetManager = datasetManager
            Task { await autoLoad() }
            // Don't automatically initialize embedding model or select datasets
            // User must explicitly choose to use a dataset
            // Load persisted rolling thought boxes, if any
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
        }
        .onChange(of: offGrid) { on in
            NetworkKillSwitch.setEnabled(on)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                backgroundUnloadController.cancelPendingUnload()
                AutopilotAFMBrain.syncWarmState(armed: modelManager.autoRoutingArmed)
                _ = chatVM.resumeDeferredAutoRoutingIfNeeded()
            case .inactive:
                // Inactive is commonly transient (system overlays, permission
                // prompts, app switching). Never destroy an in-flight turn here.
                backgroundUnloadController.scheduleIfNeeded(
                    sceneState: .inactive,
                    chatVM: chatVM,
                    modelManager: modelManager
                )
            case .background:
                AutopilotAFMBrain.syncWarmState(armed: false, cancelInFlight: true)
                _ = chatVM.deferAutoRoutingLocallyUntilActive(
                    reason: "scene-background"
                )
                // Flush any coalesced session save now so a message added just before
                // backgrounding isn't lost if the app is suspended/killed before the
                // trailing delayed save fires.
                chatVM.flushPendingSessionSavesNow()
                // Persist all rolling thought boxes for restoration on next launch
                let keys = Array(chatVM.rollingThoughtViewModels.keys)
                UserDefaults.standard.set(keys, forKey: "RollingThought.Keys")
                for (key, vm) in chatVM.rollingThoughtViewModels {
                    vm.saveState(forKey: "RollingThought." + key)
                }
                // Free large local runtimes in the background while keeping lightweight ET/CML/AFM ready.
                backgroundUnloadController.scheduleIfNeeded(
                    sceneState: .background,
                    chatVM: chatVM,
                    modelManager: modelManager
                )
                // If the embedder isn't actively running, unload it too to reduce memory pressure.
                Task.detached {
                    if await EmbeddingModel.shared.activeOperationsCount == 0 {
                        await EmbeddingModel.shared.unload()
                    }
                    await DatasetRetriever.shared.clearCache()
                }
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            // A memory warning during autopilot routing must not call `stop()`:
            // that invalidates the send, deletes its empty assistant placeholder,
            // and makes the resident GGUF appear idle. Abandon only the routing
            // verdict and let the same turn continue locally. Win the one-shot
            // router continuation synchronously, before a late result can replace
            // the local memory-pressure fallback.
            let deferredUntilActive: Bool
            let continuedLocally: Bool
            AutopilotAFMBrain.syncWarmState(armed: false, cancelInFlight: true)
            if scenePhase == .active {
                deferredUntilActive = false
                continuedLocally = chatVM.cancelAutoRoutingAndContinueLocally(
                    reason: "memory-warning"
                )
            } else {
                deferredUntilActive = chatVM.deferAutoRoutingLocallyUntilActive(
                    reason: "memory-warning-background"
                )
                continuedLocally = false
            }
            let wasStreaming = chatVM.isStreaming
            let sendWasInFlight = chatVM.sendInFlight
            Task {
                await logger.log(
                    "[Lifecycle][MemoryWarning] routingFallback=\(continuedLocally) deferredUntilActive=\(deferredUntilActive) streaming=\(wasStreaming) sendInFlight=\(sendWasInFlight)"
                )
            }
            Task.detached {
                if await EmbeddingModel.shared.activeOperationsCount == 0 {
                    await EmbeddingModel.shared.unload()
                }
                await DatasetRetriever.shared.clearCache()
                _ = await chatVM.unloadIfIdle(reason: "memory-warning")
            }
        }
    }

    @MainActor
    private func autoLoad() async {
        guard !didAutoLoad else { return }
        didAutoLoad = true
        await StartupLoader.performStartupLoad(chatVM: chatVM, modelManager: modelManager, offGrid: offGrid)
    }
}
#endif
