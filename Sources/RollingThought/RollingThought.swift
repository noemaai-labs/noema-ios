import SwiftUI

#if os(macOS)
import AppKit
#endif

// Quiet, platform-adaptive palette: light translucent surfaces that read as
// native disclosure rows rather than debug consoles. Built on Color.primary
// so light and dark mode both stay low-contrast.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private extension Color {
    static var rollingThoughtSurface: Color {
        Color.primary.opacity(0.045)
    }

    static var rollingThoughtPillBackground: Color {
        Color.primary.opacity(0.06)
    }

    static var rollingThoughtPillForeground: Color {
        Color.primary.opacity(0.75)
    }

    static var rollingThoughtSecondaryPillBackground: Color {
        Color.primary.opacity(0.05)
    }

    static var rollingThoughtSecondaryPillForeground: Color {
        Color.primary.opacity(0.55)
    }

    static var rollingThoughtText: Color {
        Color.primary.opacity(0.78)
    }

    static var rollingThoughtSubtext: Color {
        Color.primary.opacity(0.5)
    }

    static var rollingThoughtLabel: Color {
        Color.primary.opacity(0.6)
    }

    static var rollingThoughtInset: Color {
        Color.primary.opacity(0.035)
    }

    static var rollingThoughtBorder: Color {
        Color.primary.opacity(0.08)
    }

    static var rollingThoughtShadow: Color {
        Color.clear
    }

    static var rollingThoughtWarningBackground: Color {
#if os(macOS)
        return Color(nsColor: NSColor.systemOrange.withAlphaComponent(0.10))
#else
        return Color.orange.opacity(0.08)
#endif
    }

    static var rollingThoughtWarningBorder: Color {
#if os(macOS)
        return Color(nsColor: NSColor.systemOrange).opacity(0.25)
#else
        return Color.orange.opacity(0.22)
#endif
    }
}

// MARK: - Token Stream Protocol
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol TokenStream: Sendable {
    associatedtype AsyncTokenSequence: AsyncSequence where AsyncTokenSequence.Element == String
    func tokens() -> AsyncTokenSequence
}

// MARK: - Rolling Thought View Model
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@MainActor
public final class RollingThoughtViewModel: ObservableObject {
    public enum Phase: String, Codable, Equatable {
        case idle
        case streaming
        case expanded
        case complete
        case interrupted
    }

    @Published public var phase: Phase = .idle {
        didSet {
            if phase == .complete {
                didReachLogicalCompletion = true
            } else if phase == .idle {
                didReachLogicalCompletion = false
            } else if phase == .interrupted {
                didReachLogicalCompletion = false
            }
        }
    }
    @Published public private(set) var rollingLines: [String] = []
    @Published public var fullText: String = ""
    /// Wall-clock moment the current reasoning stream began; nil once captured.
    public private(set) var thinkingStartedAt: Date?
    /// Seconds spent reasoning, captured when the stream finishes or is interrupted.
    @Published public private(set) var thinkingDuration: TimeInterval?
    // Tracks whether the logical stream (final </think>) has completed
    private(set) var didReachLogicalCompletion: Bool = false
    public var isLogicallyComplete: Bool { didReachLogicalCompletion }
    // If true, automatically call finish() once the currently running token stream ends
    private var shouldFinishWhenStreamEnds: Bool = false
    /// Whether the view model is waiting for its token stream to end before marking complete.
    public var isPendingCompletion: Bool { shouldFinishWhenStreamEnds }
    // Whether generation was explicitly interrupted (via `markInterrupted()`).
    // Used when collapsing an expanded box to decide the underlying state to
    // restore. We can't infer this from `streamTask == nil` because the
    // race-free `setContent` driver always clears `streamTask`, so an active
    // stream would otherwise look identical to an interrupted one.
    private var wasInterrupted: Bool = false
    
    // Configuration
    public let rollingLineLimit = 3
    public let collapseLabel = "Thought."
    public let showCollapseLabelWhenComplete = true
    
    private var streamTask: Task<Void, Never>?
    private var currentLines: [String] = []
    
    // Persistence
    private let persistenceKey = "RollingThoughtViewModel.State"
    
    struct State: Codable {
        var phase: Phase
        var fullText: String
        var didReachLogicalCompletion: Bool
        var thinkingDuration: TimeInterval?
    }
    
    public init() {}
    
    public func start<T: TokenStream>(with stream: T) {
        // Only reset if we're starting fresh (not already streaming)
        if phase == .idle {
            reset()
        }
        // Cancel any in-flight stream without changing the current phase
        streamTask?.cancel()
        streamTask = nil
        phase = .streaming
        didReachLogicalCompletion = false
        shouldFinishWhenStreamEnds = false
        wasInterrupted = false
        beginThinkingClockIfNeeded()

        streamTask = Task {
            await consumeStream(stream.tokens())
        }
    }

    public func append<T: TokenStream>(with stream: T) {
        // For appending to existing content without resetting
        // Preserve deferred-completion intent across appends
        let preserveDeferredCompletion = shouldFinishWhenStreamEnds
        // Cancel any in-flight stream without changing the current phase
        streamTask?.cancel()
        streamTask = nil
        shouldFinishWhenStreamEnds = preserveDeferredCompletion
        wasInterrupted = false
        if phase != .streaming && phase != .expanded {
            phase = .streaming
        }
        beginThinkingClockIfNeeded()

        streamTask = Task {
            await consumeStream(stream.tokens())
        }
    }
    
    public func toggleExpanded() {
        switch phase {
        case .streaming:
            phase = .expanded
        case .complete:
            // Allow reopening from complete state
            phase = .expanded
        case .interrupted:
            phase = .expanded
        case .expanded:
            // Collapse back to the underlying state. Completion takes priority
            // (the stream may have finished while the box was open); otherwise
            // restore interrupted vs. still-streaming. We rely on the explicit
            // `wasInterrupted` flag rather than `streamTask == nil`, because the
            // race-free `setContent` driver always nils `streamTask` even mid-
            // stream — so checking it would wrongly report "interrupted" while
            // generation is still active.
            if didReachLogicalCompletion {
                phase = .complete
            } else if wasInterrupted {
                phase = .interrupted
            } else {
                phase = .streaming
            }
        case .idle:
            break
        }
    }

    public func finish() {
        streamTask?.cancel()
        streamTask = nil
        captureThinkingDuration()
        didReachLogicalCompletion = true
        shouldFinishWhenStreamEnds = false
        wasInterrupted = false

        if phase != .expanded {
            phase = .complete
        }
        
        // Privacy option: uncomment the next line to clear full text on completion
        // fullText = ""
    }
    
    public func cancel() {
        streamTask?.cancel()
        streamTask = nil

        // Defer state mutation to the next runloop to avoid publishing
        // changes while SwiftUI is in the middle of a view update pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.phase = .idle
            self.didReachLogicalCompletion = false
            self.shouldFinishWhenStreamEnds = false
            self.wasInterrupted = false
        }
    }

    public func markInterrupted() {
        streamTask?.cancel()
        streamTask = nil
        shouldFinishWhenStreamEnds = false
        didReachLogicalCompletion = false
        wasInterrupted = true
        captureThinkingDuration()
        // Preserve an expanded box just like finish() does; collapsing it later
        // lands on the interrupted pill via the `wasInterrupted` flag.
        if phase != .idle && phase != .expanded {
            phase = .interrupted
        }
    }
    
    private func reset() {
        fullText = ""
        rollingLines = []
        currentLines = []
        didReachLogicalCompletion = false
        shouldFinishWhenStreamEnds = false
        wasInterrupted = false
        thinkingStartedAt = nil
        thinkingDuration = nil
    }

    /// Request that the view model transition to complete immediately after the
    /// currently running token stream finishes delivering its tokens.
    public func deferCompletionUntilStreamEnds() {
        shouldFinishWhenStreamEnds = true
    }

    /// Authoritatively replace the thinking text in one shot.
    ///
    /// This is the race-free alternative to `start`/`append`: callers that already
    /// hold the complete text so far (e.g. re-parsed from a growing stream buffer)
    /// should use this instead of computing a delta and feeding a token stream.
    /// The delta+`append` approach raced with `consumeStream`'s async `fullText`
    /// mutation and could duplicate content ("results results"), which also broke
    /// the `fullText == content` completion check so the box never finalized.
    public func setContent(_ text: String) {
        // Drop any in-flight token stream so it can't append stale tokens on top
        // of the authoritative text we're assigning here.
        streamTask?.cancel()
        streamTask = nil
        if phase == .idle {
            phase = .streaming
        }
        if phase == .streaming || phase == .expanded {
            beginThinkingClockIfNeeded()
        }
        guard fullText != text else { return }
        fullText = text
        updateRollingLines()
    }
    
    private func consumeStream<S: AsyncSequence>(_ sequence: S) async where S.Element == String {
        do {
            for try await token in sequence {
                guard !Task.isCancelled else { break }
                
                await MainActor.run {
                    fullText.append(token)
                    updateRollingLines()
                }
            }
        } catch {
            // Handle streaming errors gracefully
            print("RollingThought stream error: \(error)")
        }
        
        if !Task.isCancelled {
            await MainActor.run {
                self.streamTask = nil
                if self.shouldFinishWhenStreamEnds {
                    self.finish()
                }
            }
        }
    }
    
    public func updateRollingLines() {
        // Split text into lines
        let allLines = fullText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        
        // Get the last N lines for rolling display
        var visibleLines = Array(allLines.suffix(rollingLineLimit))
        
        // Ensure we always have consistent line count to prevent height changes
        while visibleLines.count < rollingLineLimit {
            visibleLines.insert("", at: 0)
        }
        
        // Update with a subtle animation to reveal the rolling effect
        withAnimation(.linear(duration: 0.12)) {
            rollingLines = visibleLines
        }
    }
    
    private func beginThinkingClockIfNeeded() {
        guard thinkingStartedAt == nil, !didReachLogicalCompletion else { return }
        thinkingStartedAt = Date()
    }

    private func captureThinkingDuration() {
        if let start = thinkingStartedAt {
            thinkingDuration = Date().timeIntervalSince(start)
        }
        thinkingStartedAt = nil
    }

    /// Compact "12s" / "1m 4s" readout for the finished-reasoning row.
    public var thinkingDurationLabel: String? {
        guard let seconds = thinkingDuration, seconds >= 0.05 else { return nil }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let whole = Int(seconds.rounded())
        return String(format: "%dm %ds", whole / 60, whole % 60)
    }

    // MARK: - Persistence
    public func saveState() {
        let state = State(phase: phase, fullText: fullText, didReachLogicalCompletion: didReachLogicalCompletion, thinkingDuration: thinkingDuration)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }
    
    public func loadState() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return
        }
        self.phase = state.phase
        self.fullText = state.fullText
        self.didReachLogicalCompletion = state.didReachLogicalCompletion
        self.thinkingDuration = state.thinkingDuration
        self.wasInterrupted = (state.phase == .interrupted)
        updateRollingLines()
    }

    public func saveState(forKey key: String) {
        let state = State(phase: phase, fullText: fullText, didReachLogicalCompletion: didReachLogicalCompletion, thinkingDuration: thinkingDuration)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    public func loadState(forKey key: String) {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return
        }
        self.phase = state.phase
        self.fullText = state.fullText
        self.didReachLogicalCompletion = state.didReachLogicalCompletion
        self.thinkingDuration = state.thinkingDuration
        self.wasInterrupted = (state.phase == .interrupted)
        updateRollingLines()
    }
}

// MARK: - Rolling Thought Box Component
@available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
public struct RollingThoughtBox: View {
    @ObservedObject public var viewModel: RollingThoughtViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var namespace
    @State private var isAppearing = false
    @State private var shouldAutoScroll: Bool = true
    @State private var dotPulsing = false

    public init(viewModel: RollingThoughtViewModel) {
        self.viewModel = viewModel
    }

    /// One visual row of the 11 pt monospaced font.
    private static let streamingRowHeight: CGFloat = 14.0

    /// The rolling window never grows past `rollingLineLimit` visual rows.
    private var streamingMaxContentHeight: CGFloat {
        CGFloat(viewModel.rollingLineLimit) * Self.streamingRowHeight
    }

    /// Measured (wrapped) height of the streaming content, clamped to the
    /// rolling window. Lines wrap now, so the window height must come from
    /// actual layout instead of counting "\n" — a long paragraph with no
    /// newline still needs the full window.
    @State private var measuredStreamHeight: CGFloat = 14.0

    private struct StreamContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private var thoughtSurfaceBackground: Color {
        .rollingThoughtSurface
    }

    private var thoughtSurfaceBorder: Color {
        .rollingThoughtBorder
    }

    private var thoughtPillBackground: Color {
        .rollingThoughtPillBackground
    }

    private var thoughtPillForeground: Color {
        .rollingThoughtPillForeground
    }

    private var thoughtSecondaryPillBackground: Color {
        .rollingThoughtSecondaryPillBackground
    }

    private var thoughtSecondaryPillForeground: Color {
        .rollingThoughtSecondaryPillForeground
    }

    private var thoughtTextColor: Color {
        .rollingThoughtText
    }

    private var thoughtSubtextColor: Color {
        .rollingThoughtSubtext
    }

    private var thoughtInsetBackground: Color {
        .rollingThoughtInset
    }

    private var cardCornerRadius: CGFloat {
        10
    }

    private var insetCornerRadius: CGFloat {
        8
    }

    private var dotGradient: LinearGradient {
        LinearGradient(
            colors: [Color.purple, Color(red: 0.35, green: 0.34, blue: 0.84)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func identityDot(pulsing: Bool) -> some View {
        Circle()
            .fill(dotGradient)
            .frame(width: 6, height: 6)
            .opacity(pulsing && dotPulsing ? 0.35 : 1)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }

    private func rowLabel(_ titleKey: LocalizedStringKey) -> some View {
        Text(titleKey)
            .textCase(.uppercase)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(Color.rollingThoughtLabel)
            .lineLimit(1)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var liveElapsedText: some View {
        if #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *),
           let start = viewModel.thinkingStartedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(Self.elapsedLabel(from: start, to: context.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(thoughtSubtextColor)
                    .opacity(dotPulsing ? 0.45 : 1)
            }
        }
    }

    private static func elapsedLabel(from start: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let whole = Int(seconds.rounded())
        return String(format: "%dm %ds", whole / 60, whole % 60)
    }

    private func syncPulse(streaming: Bool) {
        if streaming {
            guard !dotPulsing else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                dotPulsing = true
            }
        } else if dotPulsing {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dotPulsing = false
            }
        }
    }

    public var body: some View {
        ZStack {
            ZStack {
                switch viewModel.phase {
                case .idle:
                    EmptyView()
                    
                case .streaming:
                    streamingView
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .identity
                        ))
                    
                case .expanded:
                    expandedView
                        .transition(.identity)

                case .complete:
                    if viewModel.showCollapseLabelWhenComplete {
                        completeView
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .identity
                            ))
                    } else {
                        // Keep a minimal placeholder to prevent layout jump when box completes
                        Color.clear.frame(height: 1)
                    }

                case .interrupted:
                    interruptedView
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .identity
                        ))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.phase)
            .id(viewModel.phase) // Force view identity update on phase change
        }
        .opacity(isAppearing ? 1 : 0)
        .onAppear {
            guard !isAppearing else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isAppearing = true
            }
        }
    }
    
    private var streamingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                identityDot(pulsing: true)
                rowLabel("Thinking…")
                Spacer(minLength: 8)
                liveElapsedText
            }
            .padding(.top, 7)

            // Rolling content with auto-scroll to the currently generating line
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let allLines = viewModel.fullText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                        ForEach(Array(allLines.enumerated()), id: \.offset) { i, l in
                            Text(l.isEmpty ? " " : l)
                                .id("rt-line-\(i)")
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(thoughtTextColor.opacity(0.82))
                                // Wrap instead of truncating: a paragraph that hasn't
                                // emitted "\n" yet must stay fully readable inside the
                                // box rather than running past its trailing edge.
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: Self.streamingRowHeight)
                        }
                        // Bottom anchor to ensure reliable auto-scroll as content grows
                        Color.clear
                            .frame(height: 1)
                            .id("rt-bottom")
                    }
                    .background(
                        GeometryReader { contentProxy in
                            Color.clear.preference(
                                key: StreamContentHeightKey.self,
                                value: contentProxy.size.height
                            )
                        }
                    )
                }
                .frame(height: measuredStreamHeight)
                .onPreferenceChange(StreamContentHeightKey.self) { height in
                    // Clamp before storing so state stops churning once the
                    // window is at its cap (content keeps growing past it).
                    let clamped = min(max(height, Self.streamingRowHeight), streamingMaxContentHeight)
                    guard abs(clamped - measuredStreamHeight) > 0.5 else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        measuredStreamHeight = clamped
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
                // Collapsed rolling window: keep the original simple drag-based detach. The
                // onScrollGeometryChange detach misfires in this small, masked, height-
                // animating window (content-growth vs user-scroll can't be told apart there)
                // and stalls the live auto-scroll. Only the expanded view needs the
                // trackpad/wheel-aware detach.
                .simultaneousGesture(DragGesture().onChanged { _ in shouldAutoScroll = false })
                .onChange(of: viewModel.fullText) { _ in
                    guard shouldAutoScroll else { return }
                    DispatchQueue.main.async {
                        guard shouldAutoScroll else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo("rt-bottom", anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    // Scroll to bottom on first appear so the generating line is visible
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo("rt-bottom", anchor: .bottom)
                        }
                        shouldAutoScroll = true
                    }
                }
                .overlay(alignment: .topLeading) {
                    if viewModel.phase == .streaming && viewModel.fullText.isEmpty {
                        Text("• • •")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(thoughtSubtextColor)
                            .padding(.leading, 14)
                    }
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.8),
                            .init(color: .black.opacity(0.2), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .padding(.bottom, 8)

            hairline
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.toggleExpanded()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { syncPulse(streaming: true) }
        .onDisappear { syncPulse(streaming: false) }
    }

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                identityDot(pulsing: false)
                rowLabel("Reasoning")
                Spacer(minLength: 8)
                Button(action: { viewModel.toggleExpanded() }) {
                    HStack(spacing: 3) {
                        Text("Hide")
                            .textCase(.uppercase)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(thoughtSubtextColor)
            }
            .padding(.top, 7)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Group {
                            if viewModel.fullText.isEmpty {
                                Text("Waiting for thoughts...")
                            } else {
                                Text(viewModel.fullText)
                            }
                        }
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(thoughtTextColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                            .id("fullText")
                        // Bottom anchor to ensure reliable auto-scroll as content grows
                        Color.clear
                            .frame(height: 1)
                            .id("scrollBottom")
                    }
                }
                .frame(maxHeight: 200)
                .background(thoughtInsetBackground)
                .clipShape(RoundedRectangle(cornerRadius: insetCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: insetCornerRadius, style: .continuous)
                        .stroke(thoughtSurfaceBorder, lineWidth: 0.6)
                )
                .detachAutoScrollOnUserScroll($shouldAutoScroll)
                .overlay(alignment: .bottomTrailing) {
                    if !shouldAutoScroll && viewModel.phase == .streaming {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("scrollBottom", anchor: .bottom)
                            }
                            shouldAutoScroll = true
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.caption)
                                .padding(6)
                                .foregroundColor(thoughtSubtextColor)
                                .background(thoughtSecondaryPillBackground)
                                .clipShape(Circle())
                        }
                        .padding(8)
                    }
                }
                .onChange(of: viewModel.fullText) { _ in
                    guard shouldAutoScroll else { return }
                    DispatchQueue.main.async {
                        guard shouldAutoScroll else { return }
                        proxy.scrollTo("scrollBottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    // Scroll to bottom on first appear as well
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("scrollBottom", anchor: .bottom)
                        }
                        shouldAutoScroll = true
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.bottom, 8)

            hairline
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Full-width disclosure row shown once reasoning has finished; reopens on tap.
    private var completeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { viewModel.toggleExpanded() }) {
                HStack(spacing: 8) {
                    identityDot(pulsing: false)
                    rowLabel("Reasoning")
                    if let durationLabel = viewModel.thinkingDurationLabel {
                        Text(verbatim: "· " + String.localizedStringWithFormat(NSLocalizedString("thought for %@", comment: "Reasoning row duration detail"), durationLabel))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(thoughtSubtextColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color.primary.opacity(0.3))
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Reasoning complete. Show reasoning."))

            hairline
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var interruptedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { viewModel.toggleExpanded() }) {
                HStack(spacing: 8) {
                    identityDot(pulsing: false)
                    rowLabel("Reasoning")
                    Spacer(minLength: 8)
                    Text("Interrupted")
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.rollingThoughtWarningBackground)
                        )
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color.primary.opacity(0.3))
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Reasoning interrupted. Show partial reasoning."))

            hairline
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RollingScrollSnapshot: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
}

private extension View {
    /// Detaches auto-scroll ("snap to newest") the moment the user scrolls the reasoning
    /// content UP to read it, and stays detached until the box is closed and reopened
    /// (which re-arms it via the scroll view's onAppear). Uses onScrollGeometryChange so it
    /// works for touch AND trackpad/mouse-wheel scrolling; a genuine user scroll is told
    /// apart from content growth (new tokens) and our own programmatic scroll-to-bottom by
    /// requiring the offset to DECREASE without the content height increasing. Falls back to
    /// a drag gesture on OS versions without onScrollGeometryChange.
    @ViewBuilder
    func detachAutoScrollOnUserScroll(_ shouldAutoScroll: Binding<Bool>) -> some View {
        if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
            self.onScrollGeometryChange(for: RollingScrollSnapshot.self) { geometry in
                RollingScrollSnapshot(
                    offsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height
                )
            } action: { previous, current in
                // Content grew (a new token pushed the bottom down) → not a user scroll.
                guard current.contentHeight <= previous.contentHeight + 0.5 else { return }
                // Offset moved up (toward earlier text) with stable content → user wants to
                // read; stop snapping back. One-way: only reopening re-arms auto-scroll.
                if current.offsetY < previous.offsetY - 4 {
                    shouldAutoScroll.wrappedValue = false
                }
            }
        } else {
            self.simultaneousGesture(DragGesture().onChanged { _ in shouldAutoScroll.wrappedValue = false })
        }
    }
}
