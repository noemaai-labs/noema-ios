import SwiftUI
import RollingThought

#if os(macOS)
import AppKit

typealias ChatView = MessageView.ChatView

final class MacChatChromeState: ObservableObject {
    @Published var showAdvancedControls = false
}

struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var tabRouter: TabRouter
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @EnvironmentObject private var downloadController: DownloadController
    @EnvironmentObject private var walkthrough: GuidedWalkthroughManager
    @AppStorage("offGrid") private var offGrid = false
    @State private var hoveredTab: MainTab?
    @StateObject private var macModalPresenter = MacModalPresenter()
    @StateObject private var macChatChrome = MacChatChromeState()
    @StateObject private var backgroundUnloadController = BackgroundModelUnloadController()
    @State private var didAutoLoad = false

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
        .settingsIntro,
        .settingsHighlights,
        .completed
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detailContainer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.windowBackground)
        .background(FullScreenWindowConfigurator())
        .frame(minWidth: 1100, minHeight: 720)
        .onAppear {
            modelManager.bind(datasetManager: datasetManager)
            downloadController.configure(modelManager: modelManager, datasetManager: datasetManager)
            datasetManager.bind(downloadController: downloadController)
            chatVM.modelManager = modelManager
            chatVM.datasetManager = datasetManager
            restoreRollingThoughts()
            Task { await autoLoad() }
        }
        .onChange(of: offGrid) { on in
            NetworkKillSwitch.setEnabled(on)
            if on && tabRouter.selection == .explore {
                tabRouter.selection = .settings
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                backgroundUnloadController.cancelPendingUnload()
            case .inactive:
                backgroundUnloadController.scheduleIfNeeded(
                    sceneState: .inactive,
                    chatVM: chatVM,
                    modelManager: modelManager
                )
            case .background:
                persistRollingThoughts()
                backgroundUnloadController.scheduleIfNeeded(
                    sceneState: .background,
                    chatVM: chatVM,
                    modelManager: modelManager
                )
            @unknown default:
                break
            }
        }
    }

    // Extremely quiet, narrow icon rail: navigation should never compete with
    // the conversation or the chat list for attention.
    private var sidebar: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                sidebarButton(for: .chat, systemImage: "message", help: String(localized: "Chat"))
                    .guideHighlight(.chatSidebarButton)
                sidebarButton(for: .stored, systemImage: "externaldrive", help: String(localized: "Stored"))

                if !offGrid {
                    sidebarButton(for: .explore, systemImage: "safari", help: String(localized: "Explore"))
                }
            }

            sidebarDivider

            VStack(spacing: 6) {
                sidebarButton(for: .relay, systemImage: "bolt.horizontal", help: String(localized: "Mac Relay"))
            }

            Spacer(minLength: 12)

            sidebarDivider

            sidebarButton(for: .settings, systemImage: "gearshape", help: String(localized: "Settings"))
        }
        .padding(.vertical, SidebarMetrics.verticalInset)
        .padding(.horizontal, SidebarMetrics.horizontalInset)
        .frame(width: SidebarMetrics.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.sidebarBackground)
        .background(.ultraThinMaterial) // Ensure blur effect
        .overlay(alignment: .trailing) {
            AppTheme.separator
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func sidebarButton(for tab: MainTab, systemImage: String, help: String) -> some View {
        let isSelected = tabRouter.selection == tab
        let isHovered = hoveredTab == tab

        Button {
            if tab == .explore && offGrid {
                tabRouter.selection = .settings
            } else {
                tabRouter.selection = tab
            }
        } label: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16, weight: .medium))
                .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.8))
                .padding(SidebarMetrics.buttonPadding)
                .frame(width: SidebarMetrics.buttonSize, height: SidebarMetrics.buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            isSelected
                                ? Color.primary.opacity(0.08)
                                : Color.primary.opacity(isHovered ? 0.04 : 0)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
        }
    }

    private enum SidebarMetrics {
        static let horizontalInset: CGFloat = 10
        static let verticalInset: CGFloat = 24
        static let iconSize: CGFloat = 18
        static let buttonPadding: CGFloat = 9
        static let buttonSize: CGFloat = iconSize + (buttonPadding * 2)
        static let width: CGFloat = (horizontalInset * 2) + buttonSize
    }

    private var sidebarDivider: some View {
        Color.primary.opacity(0.08)
            .frame(height: 1)
            .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var detailContent: some View {
        ZStack {
            switch tabRouter.selection {
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
            case .relay:
                RelayManagementView()
                    .environmentObject(modelManager)
                    .environmentObject(chatVM)
                    .environmentObject(downloadController)
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
    }

    private var detailHorizontalPadding: CGFloat {
        switch tabRouter.selection {
        case .chat, .explore:
            return 0
        default:
            return UIConstants.widePadding // Use new wide padding
        }
    }

    private var detailTopPadding: CGFloat {
        switch tabRouter.selection {
        case .chat, .explore:
            return 0
        default:
            return UIConstants.defaultPadding
        }
    }

    private var detailStackSpacing: CGFloat { tabRouter.selection == .chat ? 0 : 32 } // Increased spacing
    private var notificationsTopPadding: CGFloat {
        tabRouter.selection == .chat ? 64 : 24
    }
    private var notificationsHorizontalPadding: CGFloat { max(detailHorizontalPadding, 24) }
    private var notificationsTrailingPadding: CGFloat {
        tabRouter.selection == .chat ? 88 : notificationsHorizontalPadding
    }

    private var detailContainer: some View {
        ZStack(alignment: .topLeading) {
            Color.clear // Let window background show through
                .ignoresSafeArea(edges: [.horizontal, .bottom])

            VStack(alignment: .leading, spacing: detailStackSpacing) {
                detailContent
                    .padding(.horizontal, detailHorizontalPadding)
                    .padding(.top, detailTopPadding)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .environmentObject(macChatChrome)
            .environmentObject(macModalPresenter)
            .scaleEffect(macModalPresenter.isPresented ? 0.97 : 1)
            .animation(.spring(response: 0.36, dampingFraction: 0.85), value: macModalPresenter.isPresented)
            .allowsHitTesting(!macModalPresenter.isPresented)

            VStack(spacing: 12) {
                TopNotificationStack(
                    datasetManager: datasetManager,
                    modelManager: modelManager,
                    loadingTracker: chatVM.loadingProgressTracker
                )
            }
            .padding(.top, notificationsTopPadding)
            .padding(.leading, notificationsHorizontalPadding)
            .padding(.trailing, notificationsTrailingPadding)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .allowsHitTesting(true)

            DownloadOverlay()
                .environmentObject(downloadController)
                .padding(36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            GuidedWalkthroughOverlay(allowedSteps: mainGuideSteps)
                .environmentObject(walkthrough)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $downloadController.showPopup) {
            DownloadListPopup()
                .environmentObject(downloadController)
                .frame(minWidth: 520, minHeight: 420)
        }
        .overlay(alignment: .center) {
            MacModalHost()
                .environmentObject(macModalPresenter)
                .allowsHitTesting(macModalPresenter.isPresented)
                .zIndex(macModalPresenter.isPresented ? 100 : -1)
        }
    }

    private var windowBackground: some View {
        AppTheme.windowBackground
            .ignoresSafeArea()
    }

    private func restoreRollingThoughts() {
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

    private func persistRollingThoughts() {
        let keys = Array(chatVM.rollingThoughtViewModels.keys)
        UserDefaults.standard.set(keys, forKey: "RollingThought.Keys")
        for (key, vm) in chatVM.rollingThoughtViewModels {
            vm.saveState(forKey: "RollingThought." + key)
        }
    }

    @MainActor
    private func autoLoad() async {
        guard !didAutoLoad else { return }
        didAutoLoad = true
        await StartupLoader.performStartupLoad(chatVM: chatVM, modelManager: modelManager, offGrid: offGrid)
    }
}

private struct FullScreenWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView(frame: .zero)
        view.coordinator = context.coordinator
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    final class ObservingView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                configure(window)
                return
            }

            removeObservers()
            self.window = window

            guard let window else { return }

            configure(window)

            let center = NotificationCenter.default
            observers.append(
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.configure(window)
                }
            )
            observers.append(
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.configure(window)
                }
            )
        }

        private func configure(_ window: NSWindow?) {
            guard let window else { return }

            // Avoid touching system helper overlays created for fullscreen/menu bar tracking.
            let cls = window.className
            if cls.contains("NSToolbarFullScreenWindow") || cls.contains("FullScreenMouse") || cls.contains("NSStatusBar") || cls.contains("NSTouchBar") {
                return
            }

            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert([.fullScreenPrimary, .fullScreenAllowsTiling])
            window.styleMask.remove(.borderless)
            // Favor the standard macOS chrome to avoid duplicated titlebars/traffic lights.
            window.styleMask.remove(.fullSizeContentView)
            window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.isMovableByWindowBackground = false
            // Let macOS decide toolbar styling; do not force unified/overlay styles.
            if #available(macOS 11.0, *) {
                window.toolbarStyle = .automatic
            }
            window.isOpaque = true
            window.backgroundColor = NSColor.windowBackgroundColor

            // No need to tweak the standard buttons or titlebar container when using default chrome,
            // but keep metrics updated for any consumers.
            WindowChromeMetrics.update(from: window)

            // Make sure only this window is eligible for fullscreen primary and log current windows.
            WindowDiagnostics.restrictFullScreen(to: window)
            WindowDiagnostics.logWindows(reason: "FullScreenConfigurator.configure")
        }

        // When using default chrome, no explicit standard-button or titlebar-container tweaks are required.

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach { center.removeObserver($0) }
            observers.removeAll()
        }

        deinit {
            MainActor.assumeIsolated { [self] in
                removeObservers()
            }
        }
    }
}

#endif
