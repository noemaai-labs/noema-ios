import SwiftUI
import RollingThought

#if os(macOS)
import AppKit

typealias ChatView = MessageView.ChatView

final class MacChatChromeState: ObservableObject {
    @Published var showAdvancedControls = false
    @Published var showJSpaceLens = false
    /// Request flag set by the window toolbar; ChatView consumes it and
    /// presents its runtime-info sheet, then resets the flag.
    @Published var runtimeInfoRequested = false
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredTab: MainTab?
    @StateObject private var macModalPresenter = MacModalPresenter()
    @StateObject private var macChatChrome = MacChatChromeState()
    @StateObject private var backgroundUnloadController = BackgroundModelUnloadController()
    @State private var didAutoLoad = false
    @State private var downloadListModalActive = false
    @State private var downloadListModalID: UUID?

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
        .toolbar { windowToolbar }
        .onAppear {
            modelManager.bind(datasetManager: datasetManager)
            downloadController.configure(modelManager: modelManager, datasetManager: datasetManager)
            downloadController.bootstrapIfNeeded()
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
                AutopilotAFMBrain.syncWarmState(armed: modelManager.autoRoutingArmed)
                _ = chatVM.resumeDeferredAutoRoutingIfNeeded()
            case .inactive:
                backgroundUnloadController.scheduleIfNeeded(
                    sceneState: .inactive,
                    chatVM: chatVM,
                    modelManager: modelManager
                )
            case .background:
                AutopilotAFMBrain.syncWarmState(armed: false, cancelInFlight: true)
                _ = chatVM.deferAutoRoutingLocallyUntilActive(reason: "scene-background")
                chatVM.flushPendingSessionSavesNow()
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

    /// The one window toolbar: the model selector rides the leading slot on
    /// every tab (Xcode scheme-picker style), chat actions join it only on
    /// the chat tab. Living in the real NSToolbar restores window dragging
    /// and keeps the controls on screen in fullscreen (auto-hide is opt-in
    /// on macOS and is never requested here).
    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        // The controls draw their own industrial chrome, so each item opts out
        // of the system's Liquid Glass capsule — otherwise they render
        // double-wrapped in glass.
        ToolbarItem(placement: .navigation) {
            MacModelSelectorBar()
                .frame(minWidth: 220, idealWidth: 340, maxWidth: 420)
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(tabRouter)
                .environmentObject(walkthrough)
                .environmentObject(macModalPresenter)
                .environmentObject(macChatChrome)
        }
        .sharedBackgroundVisibility(.hidden)
        if tabRouter.selection == .chat {
            ToolbarItem(placement: .primaryAction) {
                ChatToolbarIconButton(systemImage: "brain", help: "J-Space Lens") {
                    withAnimation(.easeInOut(duration: 0.2)) { macChatChrome.showJSpaceLens.toggle() }
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                ChatToolbarIconButton(systemImage: "info.circle", help: "Runtime Information") {
                    macChatChrome.runtimeInfoRequested = true
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                ChatToolbarIconButton(systemImage: "square.and.pencil", help: "New Chat") {
                    chatVM.startNewSession()
                }
                .contextMenu {
                    if chatVM.activeSessionDataset != nil {
                        Button {
                            chatVM.startNewSession(carryingActiveDataset: false)
                        } label: {
                            Label {
                                Text(verbatim: "\(String(localized: "New Chat")) · \(String(localized: "No Dataset"))")
                            } icon: {
                                Image(systemName: "circle.slash")
                            }
                        }
                    }
                }
                .guideHighlight(.chatNewChatButton)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItem(placement: .primaryAction) {
            MacRAMUsageIndicator()
        }
        .sharedBackgroundVisibility(.hidden)
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
                sidebarButton(for: .tools, systemImage: "wrench.and.screwdriver", help: String(localized: "Tools"))
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
        .animation(AppMotion.resolve(AppMotion.snappy, reduceMotion: reduceMotion), value: isSelected)
        .animation(AppMotion.resolve(AppMotion.snappy, reduceMotion: reduceMotion), value: isHovered)
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
            pageContent
                // Distinct identity per page so SwiftUI runs the insertion/removal
                // transition when the sidebar switches tabs.
                .id(tabRouter.selection)
                .transition(AppMotion.pageTransition)
        }
        .animation(AppMotion.resolve(AppMotion.page, reduceMotion: reduceMotion),
                   value: tabRouter.selection)
    }

    @ViewBuilder
    private var pageContent: some View {
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

    // Stored pads itself (its ScrollView applies widePadding) — padding it here
    // too doubled the inset to 64pt.
    private var detailHorizontalPadding: CGFloat {
        switch tabRouter.selection {
        case .chat, .explore, .stored:
            return 0
        default:
            return UIConstants.widePadding
        }
    }

    private var detailTopPadding: CGFloat {
        switch tabRouter.selection {
        case .chat, .explore, .stored:
            return 0
        default:
            return UIConstants.defaultPadding
        }
    }

    private var detailStackSpacing: CGFloat { tabRouter.selection == .chat ? 0 : 32 } // Increased spacing
    // The old in-content chat toolbar needed 64/88pt clearances here; with the
    // controls in the real window toolbar the standard insets apply everywhere.
    private var notificationsTopPadding: CGFloat { 24 }
    private var notificationsHorizontalPadding: CGFloat { max(detailHorizontalPadding, 24) }
    private var notificationsTrailingPadding: CGFloat { notificationsHorizontalPadding }

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
        .onChange(of: downloadController.showPopup) { show in
            if show {
                if !downloadListModalIsCurrent {
                    presentDownloadList()
                }
            } else if downloadListModalActive {
                let wasCurrent = downloadListModalIsCurrent
                downloadListModalActive = false
                downloadListModalID = nil
                if wasCurrent {
                    macModalPresenter.dismiss(triggerCallback: false)
                }
            }
        }
        // MacModalPresenter.present() replaces the current modal without running
        // its onDismiss, which would strand showPopup/downloadListModalActive and
        // permanently block reopening the list; reconcile on identity changes.
        .onChange(of: macModalPresenter.presentation?.id) { id in
            guard downloadListModalActive, id != downloadListModalID else { return }
            downloadListModalActive = false
            downloadListModalID = nil
            if downloadController.showPopup {
                downloadController.closeList()
            }
        }
        .overlay(alignment: .center) {
            MacModalHost()
                .environmentObject(macModalPresenter)
                .allowsHitTesting(macModalPresenter.isPresented)
                .zIndex(macModalPresenter.isPresented ? 100 : -1)
        }
    }

    private var downloadListModalIsCurrent: Bool {
        downloadListModalActive && macModalPresenter.presentation?.id == downloadListModalID
    }

    private func presentDownloadList() {
        if macModalPresenter.isPresented {
            macModalPresenter.dismiss()
        }
        downloadListModalActive = true
        macModalPresenter.present(
            title: String(localized: "Downloads"),
            dimensions: MacModalDimensions(
                minWidth: 520,
                idealWidth: 560,
                maxWidth: 640,
                minHeight: 420,
                idealHeight: 500,
                maxHeight: 640
            ),
            contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            onDismiss: {
                downloadListModalActive = false
                downloadListModalID = nil
                if downloadController.showPopup {
                    downloadController.closeList()
                }
            }
        ) {
            DownloadListPopup(onClose: { downloadController.closeList() })
                .environmentObject(downloadController)
        }
        downloadListModalID = macModalPresenter.presentation?.id
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

/// Normalizes a window to Noema's standard resizable chrome.
///
/// SwiftUI owns the `NSToolbar` for the main `WindowGroup` window and installs a KVO observer
/// (`BarAppearanceBridge`) on it. Rewriting `styleMask` / `toolbarStyle` out from under SwiftUI
/// — especially while fullscreen is engaged — desyncs that bookkeeping and crashes with an
/// "not registered as an observer" `NSRangeException` during the fullscreen live-resize. So this
/// leaves `styleMask` / `toolbarStyle` alone while the window is in (or transitioning through)
/// fullscreen, and otherwise only assigns a value when it actually differs (a bare assignment
/// still triggers a titlebar/toolbar reshape even when the value is unchanged).
@MainActor
func applyStandardWindowChrome(to window: NSWindow) {
    window.collectionBehavior.remove(.fullScreenNone)
    window.collectionBehavior.insert([.fullScreenPrimary, .fullScreenAllowsTiling])

    if !window.styleMask.contains(.fullScreen) {
        let unwanted: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        if !window.styleMask.isDisjoint(with: unwanted) { window.styleMask.subtract(unwanted) }

        let required: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let missing = required.subtracting(window.styleMask)
        if !missing.isEmpty { window.styleMask.formUnion(missing) }

        if #available(macOS 11.0, *), window.toolbarStyle != .automatic {
            window.toolbarStyle = .automatic
        }
    }

    if window.titleVisibility != .visible { window.titleVisibility = .visible }
    if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false }
    if window.isMovableByWindowBackground { window.isMovableByWindowBackground = false }
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

            // Favor the standard macOS chrome to avoid duplicated titlebars/traffic lights.
            applyStandardWindowChrome(to: window)
            if !window.isOpaque { window.isOpaque = true }
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
