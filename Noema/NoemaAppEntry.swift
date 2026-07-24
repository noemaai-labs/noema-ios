import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
import AppKit
import RelayKit
#endif

#if canImport(FBSDKCoreKit) && os(iOS)
import FBSDKCoreKit
#endif

#if os(visionOS)

@main
struct NoemaVisionOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @MainActor
    init() {
        configureSharedApplicationEnvironment()
    }

    var body: some Scene {
        NoemaVisionMainScene()
    }
}

#elseif canImport(UIKit)

@main
struct NoemaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @AppStorage("appearance") private var appearance = "system"
    @StateObject private var tabRouter: TabRouter
    @StateObject private var chatVM: ChatVM
    @StateObject private var modelManager: AppModelManager
    @StateObject private var datasetManager: DatasetManager
    @StateObject private var downloadController: DownloadController
    @StateObject private var walkthroughManager: GuidedWalkthroughManager
    @StateObject private var localizationManager: LocalizationManager

    @Environment(\.scenePhase) private var scenePhase

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    init() {
        configureSharedApplicationEnvironment()
        let tabRouter = TabRouter()
        let chatVM = ChatVM()
        let modelManager = AppModelManager()
        let datasetManager = DatasetManager()
        let downloadController = DownloadController()
        let walkthroughManager = GuidedWalkthroughManager()
        let localizationManager = LocalizationManager()

        UITestLaunchConfiguration.applyIfNeeded(modelManager: modelManager, chatVM: chatVM)

        AppIntentDriver.shared.bind(chatVM: chatVM,
                                    modelManager: modelManager,
                                    datasetManager: datasetManager,
                                    tabRouter: tabRouter,
                                    downloadController: downloadController)

        _tabRouter = StateObject(wrappedValue: tabRouter)
        _chatVM = StateObject(wrappedValue: chatVM)
        _modelManager = StateObject(wrappedValue: modelManager)
        _datasetManager = StateObject(wrappedValue: datasetManager)
        _downloadController = StateObject(wrappedValue: downloadController)
        _walkthroughManager = StateObject(wrappedValue: walkthroughManager)
        _localizationManager = StateObject(wrappedValue: localizationManager)
    }

    var body: some Scene {
        WindowGroup {
            ContentView().preferredColorScheme(colorScheme)
                .calendarConfirmationHost()
#if canImport(FBSDKCoreKit) && os(iOS)
                .onAppear {
                    AppEvents.shared.activateApp()
                }
#endif
                .onAppear {
                    // Count a user session for review‑prompt throttling
                    ReviewPrompter.shared.trackSession()
                }
                .environmentObject(tabRouter)
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(downloadController)
                .environmentObject(walkthroughManager)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
#if canImport(FBSDKCoreKit) && os(iOS)
                AppEvents.shared.activateApp()
#endif
                EnterprisePolicyManager.shared.refreshIfEnrolled()
            }
        }
        .commands {
            NoemaKeyboardCommands(tabRouter: tabRouter, chatVM: chatVM)
        }
    }
}

private struct NoemaKeyboardCommands: Commands {
    @ObservedObject var tabRouter: TabRouter
    @ObservedObject var chatVM: ChatVM

    var body: some Commands {
        CommandMenu(LocalizedStringKey("Navigate")) {
            Button(LocalizedStringKey("Chat")) {
                tabRouter.selection = .chat
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button(LocalizedStringKey("Stored")) {
                tabRouter.selection = .stored
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button(LocalizedStringKey("Explore")) {
                tabRouter.selection = .explore
            }
            .keyboardShortcut("3", modifiers: [.command])

            Button(LocalizedStringKey("Settings")) {
                tabRouter.selection = .settings
            }
            .keyboardShortcut("4", modifiers: [.command])

            Divider()

            Button(LocalizedStringKey("New Chat")) {
                tabRouter.selection = .chat
                chatVM.startNewSession()
            }
            .keyboardShortcut("n", modifiers: [.command])

            if chatVM.activeSessionDataset != nil {
                Button {
                    tabRouter.selection = .chat
                    chatVM.startNewSession(carryingActiveDataset: false)
                } label: {
                    Text(verbatim: "\(String(localized: "New Chat")) · \(String(localized: "No Dataset"))")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            Button(LocalizedStringKey("Stop")) {
                chatVM.stop()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!chatVM.isStreaming)

            Button(LocalizedStringKey("Stop After Paragraph")) {
                chatVM.requestStopAfterParagraph()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(!chatVM.isStreaming)
        }
    }
}

#elseif os(macOS)

@main
struct NoemaMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = "system"
    @StateObject private var tabRouter: TabRouter
    @StateObject private var chatVM: ChatVM
    @StateObject private var modelManager: AppModelManager
    @StateObject private var datasetManager: DatasetManager
    @StateObject private var downloadController: DownloadController
    @StateObject private var walkthroughManager: GuidedWalkthroughManager
    @StateObject private var localizationManager: LocalizationManager

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    init() {
        configureSharedApplicationEnvironment()
        let tabRouter = TabRouter()
        let chatVM = ChatVM()
        let modelManager = AppModelManager()
        let datasetManager = DatasetManager()
        let downloadController = DownloadController()

        AppIntentDriver.shared.bind(chatVM: chatVM,
                                    modelManager: modelManager,
                                    datasetManager: datasetManager,
                                    tabRouter: tabRouter,
                                    downloadController: downloadController)

        _tabRouter = StateObject(wrappedValue: tabRouter)
        _chatVM = StateObject(wrappedValue: chatVM)
        _modelManager = StateObject(wrappedValue: modelManager)
        _datasetManager = StateObject(wrappedValue: datasetManager)
        _downloadController = StateObject(wrappedValue: downloadController)
        _walkthroughManager = StateObject(wrappedValue: GuidedWalkthroughManager())
        _localizationManager = StateObject(wrappedValue: LocalizationManager())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(colorScheme)
                .calendarConfirmationHost()
                .onAppear {
                    ReviewPrompter.shared.trackSession()
                }
                .environmentObject(tabRouter)
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(downloadController)
                .environmentObject(walkthroughManager)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .task {
                    await MainActor.run {
                        RelayManagementViewModel.shared.bind(modelManager: modelManager, chatVM: chatVM)
                        RelayControlCenter.shared.refresh(from: RelayManagementViewModel.shared)
                        RelayManagementViewModel.shared.start()
                    }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            NoemaMacKeyboardCommands(tabRouter: tabRouter, chatVM: chatVM)
        }
    }
}

private struct NoemaMacKeyboardCommands: Commands {
    @ObservedObject var tabRouter: TabRouter
    @ObservedObject var chatVM: ChatVM
    @AppStorage("offGrid") private var offGrid = false

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(LocalizedStringKey("Settings")) {
                tabRouter.selection = .settings
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandGroup(replacing: .newItem) {
            Button(LocalizedStringKey("New Chat")) {
                tabRouter.selection = .chat
                chatVM.startNewSession()
            }
            .keyboardShortcut("n", modifiers: [.command])

            if chatVM.activeSessionDataset != nil {
                Button {
                    tabRouter.selection = .chat
                    chatVM.startNewSession(carryingActiveDataset: false)
                } label: {
                    Text(verbatim: "\(String(localized: "New Chat")) · \(String(localized: "No Dataset"))")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        CommandMenu(LocalizedStringKey("Navigate")) {
            Button(LocalizedStringKey("Chat")) {
                tabRouter.selection = .chat
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button(LocalizedStringKey("Stored")) {
                tabRouter.selection = .stored
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button(LocalizedStringKey("Explore")) {
                tabRouter.selection = .explore
            }
            .keyboardShortcut("3", modifiers: [.command])
            .disabled(offGrid)

            Button(LocalizedStringKey("Mac Relay")) {
                tabRouter.selection = .relay
            }
            .keyboardShortcut("4", modifiers: [.command])

            Button(LocalizedStringKey("Tools")) {
                tabRouter.selection = .tools
            }
            .keyboardShortcut("5", modifiers: [.command])

            Button(LocalizedStringKey("Settings")) {
                tabRouter.selection = .settings
            }
            .keyboardShortcut("6", modifiers: [.command])

            Divider()

            Button(LocalizedStringKey("Stop")) {
                chatVM.stop()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!chatVM.isStreaming)

            Button(LocalizedStringKey("Stop After Paragraph")) {
                chatVM.requestStopAfterParagraph()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(!chatVM.isStreaming)
        }
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private let relayViewModel = RelayManagementViewModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Guard against a SwiftUI/AppKit reentrancy bug that throws an unhandled
        // NSRangeException while tearing down an NSToolbar KVO observer during fullscreen
        // resize. Installed before any window can enter fullscreen.
        NoemaInstallToolbarObserverCrashGuard()

        NSApplication.shared.registerForRemoteNotifications()
        if #available(macOS 10.12, *) {
            NSWindow.allowsAutomaticWindowTabbing = false
        }

        // Ensure all app windows support native full screen and show the button
        configureAllWindowsForFullScreen()

        // Constrain fullscreen behavior to a single primary window
        if let primary = NSApplication.shared.windows.first(where: { !($0 is NSPanel) }) {
            WindowDiagnostics.restrictFullScreen(to: primary)
        }
        WindowDiagnostics.logWindows(reason: "didFinishLaunching")

        // Configure future windows when they become main
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.configure(window: window)
            WindowDiagnostics.restrictFullScreen(to: window)
            WindowDiagnostics.logWindows(reason: "didBecomeMain")
        }

        RelayControlCenter.shared.refresh(from: relayViewModel)
    }

    private func configureAllWindowsForFullScreen() {
        for window in NSApplication.shared.windows {
            configure(window: window)
        }
    }

    private func configure(window: NSWindow) {
        // Skip system-managed helper windows (fullscreen overlays, mouse trackers, status/touch bar hosts)
        // and any lightweight panels/popovers so we don't accidentally re-style them.
        if isSystemHelperWindow(window) { return }
        // Use standard titled resizable window with default chrome. Shared helper keeps the
        // styleMask/toolbarStyle changes idempotent and inert during fullscreen so it never
        // desyncs SwiftUI's toolbar KVO observers.
        applyStandardWindowChrome(to: window)
        window.isReleasedWhenClosed = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // On macOS the SwiftUI scene phase is not reliably driven to `.background`
        // on quit, so MainView's scenePhase flush may never run. Persist the
        // pending chat state here so quitting never loses it.
        if let chatVM = AppIntentDriver.shared.chatVM {
            chatVM.flushPendingSessionSavesNow()
            chatVM.persistRollingThoughtsNow()
        }

        // The `_exit(0)` below skips URLSession teardown. Durable background-session
        // transfers remain owned by nsurlsessiond; any legacy foreground transfer gets
        // resume data captured before the process exits.
        BackgroundDownloadManager.shared.flushForTermination()

        // Quitting (or force-quitting) while a model is loaded leaves the in-process
        // inference threads and their GGML/Metal resources live. If we let AppKit run
        // its normal exit() teardown, the C++ static destructors and Metal backend get
        // torn down out from under those still-running threads and the process faults —
        // which macOS reports as a crash ("Noema quit unexpectedly… send report to
        // Apple"). Exit cleanly with status 0 instead: the kernel reaps the process
        // without running that teardown and without invoking the crash reporter.
        _exit(0)
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String : Any]) {
        Task { await CloudKitRelay.shared.handleRemoteNotification() }
    }
}

#if os(macOS)
@MainActor
enum WindowDiagnostics {
    static func restrictFullScreen(to primary: NSWindow) {
        for window in NSApplication.shared.windows {
            guard window !== primary else {
                window.collectionBehavior.remove(.fullScreenNone)
                window.collectionBehavior.insert([.fullScreenPrimary, .fullScreenAllowsTiling])
                continue
            }
            if isSystemHelperWindow(window) { continue }
            window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAllowsTiling])
            window.collectionBehavior.insert(.fullScreenNone)
        }
    }

    static func logWindows(reason: String) {
        #if DEBUG
        let windows = NSApplication.shared.windows
        print("[Windows] ==== \(reason) (count=\(windows.count)) ====")
        for (i, w) in windows.enumerated() {
            let mask = w.styleMask
            let flags: [String] = [
                w.isVisible ? "vis" : "hid",
                w.isMainWindow ? "main" : "",
                w.isKeyWindow ? "key" : "",
                mask.contains(.borderless) ? "borderless" : "titled",
                (w is NSPanel) ? "panel" : "window"
            ].filter { !$0.isEmpty }
            let size = Int(w.frame.width.rounded())
            let sizeH = Int(w.frame.height.rounded())
            let contentClass = String(describing: type(of: w.contentView ?? NSView()))
            print("[Windows] #\(i): \(w.className) [\(flags.joined(separator: ","))] \(size)x\(sizeH) content=\(contentClass) title=\(w.title)")
        }
        print("[Windows] ================================")
        #endif
    }
}

// Identify system-managed helper windows that should not be restyled or
// have their collection behaviors tweaked.
private func isSystemHelperWindow(_ window: NSWindow) -> Bool {
    let cls = window.className
    if window is NSPanel { return true }
    if cls.contains("Popover") { return true }
    if cls.contains("NSToolbarFullScreenWindow") { return true }
    if cls.contains("FullScreenMouse") { return true }
    if cls.contains("NSStatusBar") { return true }
    if cls.contains("NSTouchBar") { return true }
    return false
}
#endif

#endif
