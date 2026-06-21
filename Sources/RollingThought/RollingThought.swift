// RollingThought.swift
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
    // Tracks whether the logical stream (final </think>) has completed
    private(set) var didReachLogicalCompletion: Bool = false
    public var isLogicallyComplete: Bool { didReachLogicalCompletion }
    // If true, automatically call finish() once the currently running token stream ends
    private var shouldFinishWhenStreamEnds: Bool = false
    /// Whether the view model is waiting for its token stream to end before marking complete.
    public var isPendingCompletion: Bool { shouldFinishWhenStreamEnds }
    
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
        if phase != .streaming && phase != .expanded {
            phase = .streaming
        }
        
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
            // Collapse back to streaming unless we have truly completed
            if didReachLogicalCompletion {
                phase = .complete
            } else if streamTask == nil {
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
        didReachLogicalCompletion = true
        shouldFinishWhenStreamEnds = false
        
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
        }
    }

    public func markInterrupted() {
        streamTask?.cancel()
        streamTask = nil
        shouldFinishWhenStreamEnds = false
        didReachLogicalCompletion = false
        if phase != .idle {
            phase = .interrupted
        }
    }
    
    private func reset() {
        fullText = ""
        rollingLines = []
        currentLines = []
        didReachLogicalCompletion = false
        shouldFinishWhenStreamEnds = false
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
    
    // MARK: - Persistence
    public func saveState() {
        let state = State(phase: phase, fullText: fullText, didReachLogicalCompletion: didReachLogicalCompletion)
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
        updateRollingLines()
    }
    
    public func saveState(forKey key: String) {
        let state = State(phase: phase, fullText: fullText, didReachLogicalCompletion: didReachLogicalCompletion)
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

    public var body: some View {
        ZStack {
            ZStack {
                switch viewModel.phase {
                case .idle:
                    EmptyView()
                    
                case .streaming:
                    streamingView
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity),
                            removal: .identity
                        ))
                    
                case .expanded:
                    expandedView
                        .transition(.identity)

                case .complete:
                    if viewModel.showCollapseLabelWhenComplete {
                        completeView
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.9, anchor: .center).combined(with: .opacity),
                                removal: .identity
                            ))
                    } else {
                        // Keep a minimal placeholder to prevent layout jump when box completes
                        Color.clear.frame(height: 1)
                    }

                case .interrupted:
                    interruptedView
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9, anchor: .center).combined(with: .opacity),
                            removal: .identity
                        ))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.phase)
            .id(viewModel.phase) // Force view identity update on phase change
        }
        .opacity(isAppearing ? 1 : 0)
        .scaleEffect(isAppearing ? 1 : 0.98)
        .onAppear {
            guard !isAppearing else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isAppearing = true
            }
        }
    }
    
    private var streamingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(thoughtSubtextColor)
                    Text("Thinking…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(thoughtSubtextColor)
                }

                Spacer()
            }
            
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
                .padding(.horizontal, 4)
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
        }
        .padding(12)
        .background(thoughtSurfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(thoughtSurfaceBorder, lineWidth: 0.6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.toggleExpanded()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(thoughtSubtextColor)
                    Text("Reasoning")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(thoughtSubtextColor)
                }

                Spacer()
                Button(action: { viewModel.toggleExpanded() }) {
                    HStack(spacing: 3) {
                        Text("Hide")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(thoughtSecondaryPillForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            
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
                .simultaneousGesture(DragGesture().onChanged { _ in shouldAutoScroll = false })
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
        }
        .padding(12)
        .background(thoughtSurfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(thoughtSurfaceBorder, lineWidth: 0.6)
        )
    }
    
    /// Compact disclosure row shown once reasoning has finished. Hugs its
    /// content instead of spanning the chat width, and reopens on tap.
    private var completeView: some View {
        Button(action: { viewModel.toggleExpanded() }) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(thoughtSubtextColor)
                Text("Reasoning complete")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(thoughtSubtextColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(thoughtSecondaryPillForeground)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(thoughtSurfaceBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(thoughtSurfaceBorder, lineWidth: 0.6)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Reasoning complete. Show reasoning."))
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var interruptedView: some View {
        Button(action: { viewModel.toggleExpanded() }) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange)
                Text("Reasoning interrupted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(thoughtSubtextColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(thoughtSecondaryPillForeground)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.rollingThoughtWarningBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.rollingThoughtWarningBorder, lineWidth: 0.6)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Reasoning interrupted. Show partial reasoning."))
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
