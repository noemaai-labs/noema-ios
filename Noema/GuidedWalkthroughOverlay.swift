#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

struct GuidedWalkthroughOverlay: View {
    @EnvironmentObject private var manager: GuidedWalkthroughManager
    @EnvironmentObject private var downloadController: DownloadController
    @Environment(\.colorScheme) private var colorScheme
    var allowedSteps: Set<GuidedWalkthroughManager.Step>

    private let highlightPadding: CGFloat = 14
    @State private var highlightRect: CGRect = .zero
    @State private var highlightVisible = false
    @State private var pulse = false
    @State private var cardPlacement: CardPlacement = .bottom
    @State private var instructionCardSize: CGSize = .zero

    init(allowedSteps: Set<GuidedWalkthroughManager.Step> = Set(GuidedWalkthroughManager.Step.allCases)) {
        self.allowedSteps = allowedSteps
    }

    var body: some View {
        GeometryReader { proxy in
            overlayContent(in: proxy)
        }
    }

    @ViewBuilder
    private func overlayContent(in proxy: GeometryProxy) -> some View {
        if manager.isActive, allowedSteps.contains(manager.step) {
            let targetRect = currentHighlight(in: proxy)
            let instruction = manager.instruction(for: manager.step)

            ZStack {
                Color.clear
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if highlightVisible {
                    haloLayer(for: highlightRect)
                }

                VStack {
                    if cardPlacement == .top {
                        VStack(spacing: 12) {
                            instructionCard(for: instruction)
                                .frame(maxWidth: .infinity)
                                .padding(.top, topCardPadding(in: proxy))
                                .transition(.move(edge: .top).combined(with: .opacity))
                            HStack {
                                Spacer()
                                endGuideButton()
                                    .transition(.opacity)
                            }
                            .padding(.trailing, 8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        Spacer()
                    } else {
                        Spacer()
                        VStack(spacing: 12) {
                            HStack {
                                Spacer()
                                endGuideButton()
                                    .transition(.opacity)
                            }
                            .padding(.trailing, 8)
                            instructionCard(for: instruction)
                                .frame(maxWidth: .infinity)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onPreferenceChange(InstructionCardSizePreferenceKey.self) { newSize in
                    instructionCardSize = newSize
                }
            }
            .transition(.opacity)
            .overlay(
                Color.clear
                    .allowsHitTesting(false)
                    .onAppear {
                        startPulse()
                        if let forced = forcedPlacement(for: manager.step) {
                            cardPlacement = forced
                        }
                        updateHighlight(to: targetRect, in: proxy)
                    }
                    .onChange(of: targetRect) { updateHighlight(to: $0, in: proxy) }
                    .onChange(of: manager.step) { _ in
                        if let forced = forcedPlacement(for: manager.step) {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                cardPlacement = forced
                            }
                        }
                        updateHighlight(to: currentHighlight(in: proxy), in: proxy)
                    }
            )
        } else {
            EmptyView()
        }
    }

    private func currentHighlight(in proxy: GeometryProxy) -> CGRect? {
        guard let id = manager.highlightID(for: manager.step),
              let anchor = manager.anchors[id] else { return nil }
        var rect = proxy[anchor]
        rect = rect.insetBy(dx: -highlightPadding, dy: -highlightPadding)
        rect = adjustedHighlightRect(rect, for: manager.step, in: proxy)
        rect.origin.x = max(0, rect.origin.x)
        rect.origin.y = max(0, rect.origin.y)
        rect.size.width = min(proxy.size.width - rect.origin.x, rect.width)
        rect.size.height = min(proxy.size.height - rect.origin.y, rect.height)
        if (rect.width < 1 || rect.height < 1),
           let fallback = fallbackRect(for: manager.step, in: proxy) {
            rect = fallback
        }
        return rect
    }

    @ViewBuilder
    private func instructionBody() -> some View {
        switch manager.step {
        case .chatIntro:
            Text("This chat stays private—responses are generated on your device after you load a model.")
                .multilineTextAlignment(.center)
        case .chatSidebar:
            Text("Open the sidebar to revisit any previous session without losing your spot.")
                .multilineTextAlignment(.center)
        case .chatNewChat:
            Text("Need a fresh thread? Tap the plus button for a brand-new conversation.")
                .multilineTextAlignment(.center)
        case .chatInput:
            Text("Write prompts, instructions, or notes here. Press return to add new lines.")
                .multilineTextAlignment(.center)
        case .chatWebSearch:
            Text("Arm web search when you truly need outside info. Most chats don’t require it.")
                .multilineTextAlignment(.center)
        case .storedIntro:
            Text("Downloaded models and datasets live here so you can manage them offline.")
                .multilineTextAlignment(.center)
        case .storedRecommend:
            if manager.recommendedModelInstalled {
                Text("Nice! You already have the recommended GGUF starter model ready to use.")
                    .multilineTextAlignment(.center)
            } else {
                Text("Start with a reliable Qwen 3.5 2B build. It balances capability with a small download size.")
                    .multilineTextAlignment(.center)
            }
        case .storedFormats:
            Text("GGUF works everywhere. MLX targets Apple Silicon speed. ET focuses on responsiveness on any device.")
                .multilineTextAlignment(.center)
        case .modelSettingsIntro:
            Text("These options stay in simple mode for clarity. Let’s cover the essentials.")
                .multilineTextAlignment(.center)
        case .modelSettingsContext:
            Text("A larger context keeps more conversation history, but also uses more memory. Adjust it here.")
                .multilineTextAlignment(.center)
        case .modelSettingsDefault:
            Text("Startup defaults now live in Settings → Startup. Favorite models here to keep them handy.")
                .multilineTextAlignment(.center)
        case .storedDatasets:
            Text("Datasets enrich the model with focused knowledge. Toggle one on to use it in chat.")
                .multilineTextAlignment(.center)
        case .exploreIntro:
            Text("Browse community models and curated datasets to expand what Noema can do.")
                .multilineTextAlignment(.center)
        case .exploreDatasets:
            Text("Downloaded datasets need on-device embedding. Give it a few minutes after download finishes.")
                .multilineTextAlignment(.center)
        case .exploreImport:
            Text("Import your own PDFs, EPUBs, or TXT files and keep them local.")
                .multilineTextAlignment(.center)
        case .exploreSwitchToModels:
            Text("Use this switch to flip between finding models or datasets.")
                .multilineTextAlignment(.center)
        case .exploreModelTypes:
            Text("GGUF models are the most compatible option. Use the format switch to explore the other builds when you need them.")
                .multilineTextAlignment(.center)
        case .exploreMLX:
            Text("Switch the selector to MLX for Apple Silicon‑optimized builds that excel at speed.")
                .multilineTextAlignment(.center)
        case .exploreET:
            Text("Pick the ET format when you want ultra-responsive models that run well anywhere.")
                .multilineTextAlignment(.center)
        case .settingsIntro:
            Text("Adjust appearance, privacy options, and network preferences here.")
                .multilineTextAlignment(.center)
        case .settingsHighlights:
            Text("Off-grid mode blocks every network call so the app stays self-contained. Good luck exploring Noema!")
                .multilineTextAlignment(.center)
        case .completed:
            Text("You’re ready to explore. Download models, add datasets, and start chatting.")
                .multilineTextAlignment(.center)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private func recommendedDownloadCard() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended Starter Model")
                .font(.headline)
            Text("Qwen 3.5 2B GGUF gives you a dependable starting point. Delete it anytime if you need space.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let detail = manager.recommendedDetail, let quant = manager.recommendedQuant {
                QuantRow(
                    canonicalID: detail.id,
                    info: quant,
                    progress: Binding(
                        get: { manager.recommendedProgress },
                        set: { _ in }
                    ),
                    speed: Binding(
                        get: { manager.recommendedSpeed },
                        set: { _ in }
                    ),
                    downloading: manager.recommendedDownloading,
                    remoteMode: false,
                    remoteStatusText: nil,
                    remoteErrorText: nil,
                    remoteUnsupportedReason: nil,
                    remoteCompleted: false,
                    openUnavailableReason: nil,
                    showsLowQualityMarker: quant.isLowBitQuant,
                    downloadController: downloadController,
                    openAction: {
                        await manager.openRecommendedModel()
                    },
                    downloadAction: {
                        await MainActor.run {
                            manager.startRecommendedDownload()
                        }
                    },
                    cancelAction: {
                        manager.cancelRecommendedDownload()
                    }
                )
            } else if manager.recommendedLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading recommendation…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if manager.recommendedLoadFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn’t load the recommended model right now.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        manager.reloadRecommendedDetail()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemBackground).opacity(0.9))
        )
    }

    @ViewBuilder
    private func actionButtons(primary: String, secondary: String?) -> some View {
        let primaryDisabled: Bool = {
            if manager.step == .storedRecommend {
                return manager.recommendedLoading || (manager.recommendedDetail == nil && !manager.recommendedLoadFailed)
            }
            return false
        }()

        HStack(spacing: 12) {
            if let secondary {
                Button(secondary) {
                    manager.skipRecommendedDownload()
                }
                .buttonStyle(.bordered)
            }

            Button(primary) {
                manager.performPrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(primaryDisabled)
        }
    }

    private func endGuideButton() -> some View {
        Button("End Guide") {
            manager.finish()
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(endGuideTint)
        .foregroundStyle(endGuideForeground)
    }

    private var endGuideTint: Color {
        switch colorScheme {
        case .dark:
            return Color.white.opacity(0.82)
        default:
            return Color.black.opacity(0.72)
        }
    }

    private var endGuideForeground: Color {
        switch colorScheme {
        case .dark:
            return Color.black.opacity(0.85)
        default:
            return Color.white
        }
    }

    private func instructionCard(for instruction: (title: String, message: String, primary: String, secondary: String?)) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(instruction.title)
                    .font(.system(size: 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                instructionBody()
                    .font(.subheadline)
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .multilineTextAlignment(.center)
            }

            if manager.step == .storedRecommend, !manager.recommendedModelInstalled {
                recommendedDownloadCard()
                    .transition(.opacity)
            }

            actionButtons(primary: instruction.primary, secondary: instruction.secondary)
        }
        .padding(24)
        .frame(maxWidth: 380)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .shadow(color: Color.black.opacity(0.22), radius: 22, x: 0, y: 18)
        .background(
            GeometryReader { cardProxy in
                Color.clear.preference(key: InstructionCardSizePreferenceKey.self, value: cardProxy.size)
            }
        )
        .animation(.easeInOut(duration: 0.3), value: manager.step)
    }

    private func haloLayer(for rect: CGRect) -> some View {
        let radius = highlightCornerRadius(for: rect)
        let strokeStart = colorScheme == .dark ? Color.white.opacity(0.82) : Color.black.opacity(0.7)
        let strokeEnd = Color.accentColor.opacity(colorScheme == .dark ? 0.55 : 0.75)
        let glow = (colorScheme == .dark ? Color.white : Color.black).opacity(colorScheme == .dark ? 0.3 : 0.18)
        let accentShadow = Color.accentColor.opacity(colorScheme == .dark ? 0.5 : 0.32)

        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(
                LinearGradient(colors: [strokeStart, strokeEnd],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing),
                lineWidth: 4
            )
            .frame(width: rect.width + highlightPadding, height: rect.height + highlightPadding)
            .position(x: rect.midX, y: rect.midY)
            .shadow(color: accentShadow, radius: 18)
            .shadow(color: glow, radius: 12)
            .scaleEffect(pulse ? 1.03 : 0.97)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
            .allowsHitTesting(false)
    }

    private func highlightCornerRadius(for rect: CGRect) -> CGFloat {
        let minSide = max(1, min(rect.width, rect.height))
        if minSide < 64 { return minSide / 2 }
        return max(16, min(minSide / 3.5, 30))
    }

    private func updateHighlight(to rect: CGRect?, in proxy: GeometryProxy) {
        guard let rect else {
            if highlightVisible {
                withAnimation(.easeInOut(duration: 0.2)) {
                    highlightVisible = false
                }
            }
            return
        }
        let availableAbove = rect.minY
        let availableBelow = proxy.size.height - rect.maxY
        let newPlacement: CardPlacement = forcedPlacement(for: manager.step) ?? (availableAbove > availableBelow ? .top : .bottom)

        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            highlightRect = rect
            highlightVisible = true
            cardPlacement = newPlacement
        }
    }

    private func topCardPadding(in proxy: GeometryProxy) -> CGFloat {
        let safeTop = proxy.safeAreaInsets.top + 16
        guard highlightVisible, instructionCardSize.height > 0 else { return safeTop }
        let desiredGap: CGFloat = 32
        if shouldPinInstructionToTop(for: manager.step) {
            return safeTop
        }
        let maxAllowed = highlightRect.minY - instructionCardSize.height - desiredGap
        guard maxAllowed.isFinite else { return safeTop }
        if maxAllowed >= safeTop {
            return safeTop
        }
        return max(safeTop, maxAllowed)
    }

    private func shouldPinInstructionToTop(for step: GuidedWalkthroughManager.Step) -> Bool {
        switch step {
        case .chatInput, .chatWebSearch:
            return true
        default:
            return false
        }
    }

    private func adjustedHighlightRect(_ rect: CGRect, for step: GuidedWalkthroughManager.Step, in proxy: GeometryProxy) -> CGRect {
        var adjusted = rect
        switch step {
        case .chatInput:
            let extraTop: CGFloat = 32
            let newOriginY = max(0, adjusted.origin.y - extraTop)
            adjusted.size.height += adjusted.origin.y - newOriginY
            adjusted.origin.y = newOriginY
        case .chatWebSearch:
            let minimumSize: CGFloat = 54
            let newWidth = max(minimumSize, min(adjusted.size.width, 72))
            let newHeight = max(minimumSize, min(adjusted.size.height, 72))
            let center = CGPoint(x: adjusted.midX, y: adjusted.midY)
            adjusted.size = CGSize(width: newWidth, height: newHeight)
            adjusted.origin.x = max(center.x - newWidth / 2, 0)
            adjusted.origin.y = max(center.y - newHeight / 2 - 4, proxy.safeAreaInsets.top + 8)
        case .exploreImport:
            let side: CGFloat = 54
            let safeTrailing = proxy.size.width - proxy.safeAreaInsets.trailing - 16
            adjusted.size.width = side
            adjusted.size.height = side
            adjusted.origin.x = max(proxy.safeAreaInsets.leading + 8, safeTrailing - side)
            adjusted.origin.y = max(0, rect.minY - side * 1.6)
        case .settingsHighlights:
            let horizontalInset = max(16, proxy.safeAreaInsets.leading + 12)
            adjusted.origin.x = horizontalInset
            let trailingInset = max(16, proxy.safeAreaInsets.trailing + 12)
            adjusted.size.width = max(140, proxy.size.width - horizontalInset - trailingInset)
            adjusted.size.height = max(adjusted.size.height + 18, 64)
            adjusted.origin.y -= 9
        default:
            break
        }
        let maxHeight = proxy.size.height - adjusted.origin.y
        if adjusted.size.height > maxHeight {
            adjusted.size.height = maxHeight
        }
        return adjusted
    }

    private func forcedPlacement(for step: GuidedWalkthroughManager.Step) -> CardPlacement? {
        switch step {
        case .chatInput, .chatWebSearch:
            return .top
        case .storedIntro:
            return .bottom
        default:
            return nil
        }
    }

    private func fallbackRect(for step: GuidedWalkthroughManager.Step, in proxy: GeometryProxy) -> CGRect? {
        switch step {
        case .exploreImport:
            let side: CGFloat = 54
            let inset: CGFloat = 16
            let originX = max(proxy.safeAreaInsets.leading + 8, proxy.size.width - proxy.safeAreaInsets.trailing - inset - side)
            let originY = max(0, proxy.safeAreaInsets.top - 6)
            return CGRect(x: originX, y: originY, width: side, height: side)
        default:
            return nil
        }
    }

    private func startPulse() {
        guard !pulse else { return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulse.toggle()
        }
    }

    private enum CardPlacement {
        case top, bottom
    }
}

private struct InstructionCardSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize { .zero }

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

#endif
