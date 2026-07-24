#if os(iOS) || os(visionOS) || os(macOS)
import SwiftUI

struct WebSearchButton: View {
    @ObservedObject private var settings = SettingsStore.shared
#if os(macOS)
    let size: CGFloat = 24
#else
    let size: CGFloat = 28
#endif
#if os(iOS)
    private let controlSize: CGFloat = 48
#endif
#if os(visionOS)
    private let visionButtonSize = CGSize(width: 78, height: 48)
    private let visionButtonCornerRadius: CGFloat = 24
#endif
    @EnvironmentObject var vm: ChatVM
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var datasetManager: DatasetManager
    let onModelRequiredTap: (() -> Void)?
    @State private var supportsFunctionCalling = (UserDefaults.standard.object(forKey: "currentModelSupportsFunctionCalling") as? Bool)
    @State private var showDisabledReason = false
    @AppStorage("hasSeenWebSearchNotice") private var hasSeenWebSearchNotice = false
    @State private var showWebSearchNotice = false

    init(onModelRequiredTap: (() -> Void)? = nil) {
        self.onModelRequiredTap = onModelRequiredTap
    }
#if os(visionOS)
    private struct VisionPillButtonStyle: ButtonStyle {
        let isActive: Bool
        let isDisabled: Bool
        let cornerRadius: CGFloat

        func makeBody(configuration: Configuration) -> some View {
            let active = isActive || configuration.isPressed
            let fill: Color
            let border: Color
            let borderWidth: CGFloat
            let shadow: Color

            if isDisabled {
                fill = Color.gray.opacity(0.12)
                border = Color.gray.opacity(0.2)
                borderWidth = 0.75
                shadow = .clear
            } else if active {
                fill = .accentColor
                border = .clear
                borderWidth = 0
                shadow = Color.accentColor.opacity(0.45)
            } else {
                fill = Color(.systemBackground).opacity(0.9)
                border = Color.gray.opacity(0.25)
                borderWidth = 0.75
                shadow = .clear
            }

            return configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(border, lineWidth: borderWidth)
                        )
                        .shadow(color: shadow, radius: active ? 12 : 0, y: active ? 6 : 0)
                )
        }
    }
#endif

    var body: some View {
        Button(action: toggle) {
            Image(systemName: iconName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(fgColor)
#if os(visionOS)
                .frame(width: visionButtonSize.width, height: visionButtonSize.height)
#else
#if os(iOS)
                .frame(width: controlSize, height: controlSize)
#else
                .padding(10)
#endif
                .background(buttonBackground)
#endif
                .accessibilityLabel(Text("Web Search"))
                .accessibilityHint(accessibilityHint)
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: settings.webSearchArmed)
        .help(helpText)
#if os(visionOS)
        .buttonStyle(VisionPillButtonStyle(isActive: settings.webSearchArmed, isDisabled: isDisabled, cornerRadius: visionButtonCornerRadius))
#endif
#if os(macOS)
        .buttonStyle(.plain)
#endif
        // Capture taps even when visually disabled to explain why it is disabled
        .overlay {
#if os(visionOS)
            Color.clear
                .contentShape(RoundedRectangle(cornerRadius: visionButtonCornerRadius, style: .continuous))
                .onTapGesture {
                    guard isDisabled else { return }
                    if !hasActiveChatModel {
                        presentModelRequiredPopup()
                    } else {
                        showDisabledReason = true
                    }
                }
                .allowsHitTesting(isDisabled)
#else
            Color.clear
                .contentShape(Circle())
                .onTapGesture {
                    guard isDisabled else { return }
                    if !hasActiveChatModel {
                        presentModelRequiredPopup()
                    } else {
                        showDisabledReason = true
                    }
                }
                .allowsHitTesting(isDisabled)
#endif
        }
        .alert("Web Search Unavailable", isPresented: $showDisabledReason) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(disabledReason)
        }
        .alert("Tool Calling", isPresented: $showWebSearchNotice) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Tool calling isn't perfect. Although Noema implements many methods of detecting and instructing models to use tools, not all LLMs will follow instructions and some might not call them correctly or at all. Tool calling heavily depends on model pre-training and will get better as time passes.")
        }
        .onChangeCompat(of: datasetActive) { _, active in
            if active && settings.webSearchArmed { settings.webSearchArmed = false }
        }
        .onChangeCompat(of: supportsFunctionCalling) { _, supported in
            if supported == false && settings.webSearchArmed { settings.webSearchArmed = false }
        }
        .onChangeCompat(of: webSearchBlockedByModelFormat) { _, blocked in
            if blocked && settings.webSearchArmed { settings.webSearchArmed = false }
        }
        .onChangeCompat(of: hasActiveChatModel) { _, active in
            if !active && settings.webSearchArmed { settings.webSearchArmed = false }
        }
        .onAppear {
            if datasetActive && settings.webSearchArmed { settings.webSearchArmed = false }
            supportsFunctionCalling = functionCallingSupport
            if webSearchBlockedByModelFormat && settings.webSearchArmed { settings.webSearchArmed = false }
            if !hasActiveChatModel && settings.webSearchArmed { settings.webSearchArmed = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            supportsFunctionCalling = functionCallingSupport
        }
    }

    private var datasetActive: Bool {
        if modelManager.activeDataset != nil { return true }
        if datasetManager.indexingDatasetID != nil { return true }
        return false
    }

    private var hasRecentWebSearch: Bool {
        if let lastMsg = vm.msgs.last(where: { $0.role == "🤖" || $0.role.lowercased() == "assistant" }) {
            return lastMsg.usedWebSearch == true || lastMsg.webHits != nil
        }
        return false
    }

    private var hasActiveChatModel: Bool { vm.hasActiveChatModel }

    private var isRemoteSession: Bool {
        modelManager.activeRemoteSession != nil
    }

    private var isMLXModel: Bool {
        vm.currentModelFormat == .some(.mlx) && !isRemoteSession
    }

    private var isAFMModel: Bool {
        vm.currentModelFormat == .some(.afm) && !isRemoteSession
    }

    private var webSearchBlockedByModelFormat: Bool {
        // PCC-backed AFM runs the native FoundationModels web tool, so only the
        // on-device AFM variant stays blocked.
        isMLXModel || (isAFMModel && vm.afmChatToolsUnavailable)
    }

    private var functionCallingSupport: Bool? {
        UserDefaults.standard.object(forKey: "currentModelSupportsFunctionCalling") as? Bool
    }

    private var iconName: String {
        // Don't show exclamation if we just performed a successful search
        if hasRecentWebSearch {
            return "globe"
        }
        return "globe"
    }

    private var isDisabled: Bool {
        // Disable while dataset is in use (selected or indexing), or off-grid, or globally disabled
        let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
        // Also disable if current model does not support function calling (model card check)
        let supportedFlag = functionCallingSupport
        if webSearchBlockedByModelFormat { return true }
        return !hasActiveChatModel || offGrid || !settings.webSearchEnabled || datasetActive || supportedFlag == false
    }
    private var disabledReason: String {
        let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
        let supported = functionCallingSupport
        if !hasActiveChatModel {
            return String(localized: "Open Stored to choose a model to run locally or connect to a remote endpoint.")
        }
        if isMLXModel {
            return String(localized: "Web Search is currently unreliable with MLX models due to MLX limitations.")
        }
        if isAFMModel && vm.afmChatToolsUnavailable {
            return String(localized: "Web search is disabled for Apple Foundation Models because their context budget cannot reliably accommodate tool input.")
        }
        if supported == false {
            return String(localized: "This model does not support function calling; web search requires it.")
        }
        if datasetActive {
            return String(localized: "Web search can't be used while a dataset is active or indexing.")
        }
        if offGrid {
            return String(localized: "Off‑Grid mode is on. Network features like web search are disabled.")
        }
        if !settings.webSearchEnabled {
            return String(localized: "Web Search is turned off in Settings.")
        }
        return String(localized: "Web Search is currently unavailable.")
    }
    private var fgColor: Color {
        if isDisabled { return .secondary }
        return settings.webSearchArmed ? .white : .primary
    }
    private var bgFill: Color {
        if isDisabled { return Color.gray.opacity(0.12) }
        return settings.webSearchArmed ? Color.accentColor : Color(.systemBackground).opacity(0.9)
    }
    private var borderColor: Color {
        if settings.webSearchArmed { return .clear }
        return isDisabled ? Color.gray.opacity(0.2) : Color.gray.opacity(0.25)
    }
    private var borderLineWidth: CGFloat {
        settings.webSearchArmed ? 0 : 0.75
    }
    private var glowColor: Color {
        return settings.webSearchArmed ? Color.accentColor.opacity(0.45) : .clear
    }
#if !os(visionOS)
    @ViewBuilder
    private var buttonBackground: some View {
#if os(iOS)
        let shape = Circle()
        let isArmedVisual = settings.webSearchArmed && !isDisabled
        shape
            .fill(Color.clear)
            .glassifyIfAvailable(in: shape)
            .overlay(
                shape.fill(
                    isArmedVisual
                        ? Color.accentColor.opacity(0.34)
                        : Color.white.opacity(isDisabled ? 0.04 : 0.10)
                )
            )
            .overlay(
                shape.strokeBorder(
                    isArmedVisual
                        ? Color.accentColor.opacity(0.42)
                        : Color.white.opacity(isDisabled ? 0.14 : 0.32),
                    lineWidth: 0.8
                )
            )
            .shadow(
                color: isDisabled ? .clear : glowColor,
                radius: isArmedVisual ? 10 : 6,
                y: isArmedVisual ? 5 : 3
            )
#else
        Circle()
            .fill(bgFill)
            .overlay(
                Circle()
                    .strokeBorder(borderColor, lineWidth: borderLineWidth)
            )
            .shadow(color: glowColor, radius: settings.webSearchArmed ? 8 : 0)
#endif
    }
#endif
    private var accessibilityHint: String {
        if isDisabled {
            if !hasActiveChatModel { return String(localized: "Disabled: load a model in Stored first") }
            if isMLXModel { return String(localized: "Disabled: MLX models can't use reliable web search right now") }
            if functionCallingSupport == false { return String(localized: "Disabled: model lacks function calling support") }
            return String(localized: "Disabled while using a dataset")
        }
        return settings.webSearchArmed ? String(localized: "On") : String(localized: "Off")
    }

    private var helpText: String {
        // Brief guidance shown as a tooltip on macOS/iPadOS pointer hover
        if !hasActiveChatModel { return String(localized: "Open Stored to choose a model to run locally or connect to a remote endpoint.") }
        if isMLXModel { return String(localized: "Web search is currently unreliable on MLX due to platform limitations.") }
        if functionCallingSupport == false {
            return String(localized: "This model does not advertise function calling support in its model card; web search is disabled.")
        }
        return String(localized: "Toggle web search tool. Uses SearXNG. Requires models with function calling support.")
    }

    private func toggle() {
        guard !isDisabled else { return }

        let newValue = !settings.webSearchArmed
        settings.webSearchArmed = newValue
        #if os(iOS)
        Haptics.impact(.light)
        #endif
        if newValue && !hasSeenWebSearchNotice {
            hasSeenWebSearchNotice = true
            showWebSearchNotice = true
        }
    }

    private func presentModelRequiredPopup() {
        if let onModelRequiredTap {
            onModelRequiredTap()
        } else {
            showDisabledReason = true
        }
    }
}

#else
import SwiftUI

struct WebSearchButton: View {
    var body: some View {
        EmptyView()
    }
}
#endif
