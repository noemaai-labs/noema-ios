import SwiftUI
#if os(macOS)
import AppKit
#endif

#if canImport(UIKit) && !os(visionOS)
/// Root SwiftUI view for the iOS and iPadOS experience. It owns the shared
/// view models so they persist across the tab hierarchy and manages the launch
/// splash/onboarding flow.
struct ContentView: View {
    @State private var showSplash = true
    @State private var showOnboarding = false
    @State private var showUpdate = false
    @State private var showAutopilotSetup = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(NoemaUpdateView.lastPresentedVersionDefaultsKey) private var lastPresentedUpdateVersion = ""
    @EnvironmentObject private var tabRouter: TabRouter
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @EnvironmentObject private var downloadController: DownloadController
    @EnvironmentObject private var walkthroughManager: GuidedWalkthroughManager

    var body: some View {
        ZStack {
            MainView()
                .environmentObject(tabRouter)
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(downloadController)
                .environmentObject(walkthroughManager)

            if showSplash {
                SplashView()
                    .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("noemaOpenAutopilotSetup"))) { _ in
            showAutopilotSetup = true
        }
        .sheet(isPresented: $showAutopilotSetup) {
            AutopilotSetupView()
                .environmentObject(modelManager)
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(showOnboarding: $showOnboarding)
                .environmentObject(tabRouter)
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(downloadController)
                .environmentObject(walkthroughManager)
        }
        .fullScreenCover(isPresented: $showUpdate, onDismiss: markUpdatePresented) {
            NoemaUpdateView {
                showUpdate = false
            }
        }
        .onAppear {
            print("[Noema] app launched 🚀")
            walkthroughManager.configure(tabRouter: tabRouter,
                                         chatVM: chatVM,
                                         modelManager: modelManager,
                                         datasetManager: datasetManager,
                                         downloadController: downloadController)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    showSplash = false
                    if !hasCompletedOnboarding {
                        markUpdatePresented()
                        showOnboarding = true
                    } else if lastPresentedUpdateVersion != NoemaUpdateView.releaseVersion {
                        showUpdate = true
                    }
                }
            }
        }
    }

    private func markUpdatePresented() {
        lastPresentedUpdateVersion = NoemaUpdateView.releaseVersion
    }
}

/// Splash screen shown at launch with the app logo and a spinner.
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
#elseif os(macOS)

struct ContentView: View {
    @State private var showSplash = true
    @State private var showOnboarding = false
    @State private var showUpdate = false
    @State private var showAutopilotSetup = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(NoemaUpdateView.lastPresentedVersionDefaultsKey) private var lastPresentedUpdateVersion = ""
    @EnvironmentObject private var tabRouter: TabRouter
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @EnvironmentObject private var downloadController: DownloadController
    @EnvironmentObject private var walkthroughManager: GuidedWalkthroughManager

    var body: some View {
        ZStack {
            MainView()
                .environmentObject(tabRouter)
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(datasetManager)
                .environmentObject(downloadController)
                .environmentObject(walkthroughManager)

            if showSplash {
                MacSplashView()
                    .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("noemaOpenAutopilotSetup"))) { _ in
            showAutopilotSetup = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .mcpServerAdded)) { notification in
            var serverIDs = MCPChatDefaults.consumePendingServerIDs()
            if let serverID = notification.object as? String { serverIDs.insert(serverID) }
            for serverID in serverIDs {
                chatVM.setMCPServerPermissionForActiveSession(serverID, enabled: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mcpCatalogChanged)) { _ in
            chatVM.toolSpecsCache = []
        }
        .onReceive(NotificationCenter.default.publisher(for: .mcpToolApprovalResolved)) { notification in
            if let alias = notification.object as? String { chatVM.markMCPToolExecuting(alias: alias) }
        }
        .mcpInteractionPresenter(chatVM: chatVM)
        .sheet(isPresented: $showAutopilotSetup) {
            AutopilotSetupView()
                .environmentObject(modelManager)
        }
        .sheet(isPresented: $showOnboarding) {
            MacOnboardingView(showOnboarding: $showOnboarding) {
                hasCompletedOnboarding = true
            }
            .environmentObject(tabRouter)
            .environmentObject(chatVM)
            .environmentObject(modelManager)
            .environmentObject(datasetManager)
            .environmentObject(downloadController)
            .environmentObject(walkthroughManager)
        }
        .sheet(isPresented: $showUpdate, onDismiss: markUpdatePresented) {
            NoemaUpdateView {
                showUpdate = false
            }
        }
        .onAppear {
            for serverID in MCPChatDefaults.consumePendingServerIDs() {
                chatVM.setMCPServerPermissionForActiveSession(serverID, enabled: true)
            }
            chatVM.installMCPSamplingProvider()
            walkthroughManager.configure(tabRouter: tabRouter,
                                         chatVM: chatVM,
                                         modelManager: modelManager,
                                         datasetManager: datasetManager,
                                         downloadController: downloadController)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showSplash = false
                    if !hasCompletedOnboarding {
                        markUpdatePresented()
                        showOnboarding = true
                    } else if lastPresentedUpdateVersion != NoemaUpdateView.releaseVersion {
                        showUpdate = true
                    }
                }
            }
        }
    }

    private func markUpdatePresented() {
        lastPresentedUpdateVersion = NoemaUpdateView.releaseVersion
    }
}

private struct MacSplashView: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 16) {
                Image("Noema")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
    }
}

struct MacOnboardingView: View {
    @Binding var showOnboarding: Bool
    var complete: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image("Noema")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("Welcome to Noema for Mac"))
                        .font(.largeTitle.bold())
                    Text(LocalizedStringKey("Chat privately with your local models, sync datasets, and manage the relay server in one place."))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                onboardingRow(icon: "message.fill", title: LocalizedStringKey("All-in-one workspace"), subtitle: LocalizedStringKey("Chat, manage datasets, explore new models, and fine-tune settings in a spacious Mac layout."))
                onboardingRow(icon: "bolt.horizontal", title: LocalizedStringKey("Mac relay included"), subtitle: LocalizedStringKey("Share a secure CloudKit relay with your iPhone or iPad. Initial pairing is effortless via Bluetooth."))
                onboardingRow(icon: "lock.shield", title: LocalizedStringKey("Private by default"), subtitle: LocalizedStringKey("All processing happens locally—remote connections stay disabled until you opt in."))
            }

            Spacer()

            HStack {
                Spacer()
                Button(LocalizedStringKey("Get Started")) {
                    complete()
                    withAnimation {
                        showOnboarding = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.industrial(.prominent))
            }
        }
        .padding(32)
        .frame(minWidth: 620, minHeight: 480)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor))
        )
        .padding()
    }

    @ViewBuilder
    private func onboardingRow(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32, height: 32)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
