import SwiftUI

#if canImport(UIKit) || os(macOS)
extension ChatVM.Msg {
    /// Returns a copy of this message with its visible text replaced. Used to render the
    /// streaming bubble from the live `StreamingMessageStore` text without mutating the
    /// `sessions`-backed copy on every token.
    func replacingText(_ newText: String) -> ChatVM.Msg {
        var copy = self
        copy.text = newText
        return copy
    }
}

/// Wraps `MessageView` so only the in-flight assistant bubble re-renders from the
/// `StreamingMessageStore` on every token. All other messages render statically from
/// their `msg` copy — no `@ObservedObject` subscription here, so a token update
/// never touches completed messages (tool calls, previous turns, etc.).
struct StreamingAwareMessageView: View {
    let msg: ChatVM.Msg
    let store: StreamingMessageStore   // plain let — no subscription

    /// Tracks whether THIS specific message is the one currently streaming.
    /// Updated via `onReceive(store.$activeID)` + `onAppear` so the transition
    /// is immediate even when the view is first mounted mid-stream.
    @State private var isStreamingThis = false

    var body: some View {
        Group {
            if isStreamingThis {
                ActiveStreamingMessageView(msg: msg, store: store)
            } else {
                MessageView(msg: msg)
            }
        }
        .onAppear {
            // Handle the case where the view mounts while streaming is already active.
            isStreamingThis = (store.activeID == msg.id)
        }
        .onReceive(store.$activeID) { id in
            let should = (id == msg.id)
            if isStreamingThis != should { isStreamingThis = should }
        }
    }
}

/// Holds the `@ObservedObject` subscription so only the one in-flight bubble
/// re-renders per token. Separated into its own struct so the subscription is
/// mounted/unmounted with the view rather than living on every row.
private struct ActiveStreamingMessageView: View {
    let msg: ChatVM.Msg
    @ObservedObject var store: StreamingMessageStore

    var body: some View {
        // Render the live bubble from the narrow store text. We intentionally do NOT attach
        // `.animation(value: store.visibleText)` here: at the ~30 Hz flush cadence it forced
        // SwiftUI to diff and animate the entire (growing) bubble every flush — O(n) layout
        // work per flush on the main thread, a measurable source of streaming jank.
        // Token fade-in is armed via the environment instead: each newly appended word
        // fragment fades its own composited opacity in place (StreamFragmentFadeIn on
        // iOS/visionOS, temporary-attribute fade in MacLatexTextView on macOS), which
        // costs O(appended text) per flush and never animates the bubble's layout.
        MessageView(msg: msg.replacingText(store.visibleText))
            .environment(\.streamTokenFadeIn, true)
    }
}

/// Invisible view that follows the streaming text and keeps the chat pinned to the
/// bottom. It subscribes to the `StreamingMessageStore`, so it (and not the whole chat
/// list) is what re-renders on every token.
struct StreamingScrollAnchor: View {
    @ObservedObject var store: StreamingMessageStore
    let proxy: ScrollViewProxy
    let enabled: Bool

    /// `scrollTo` forces a synchronous layout pass of the scroll content. At
    /// the store's ~30 Hz flush cadence that triples the layout work and makes
    /// concurrent user scrolling stutter; ~12 Hz is visually identical for a
    /// bottom pin. A trailing call guarantees the final position after the
    /// last flush (e.g. `finish()`).
    @State private var lastScrollAt = Date.distantPast
    @State private var trailingScrollScheduled = false
    private static let minScrollInterval: TimeInterval = 0.08

    var body: some View {
        Color.clear
            .frame(height: 0)
            .onChangeCompat(of: store.visibleText) { _, _ in
                scrollToBottomThrottled()
            }
    }

    /// Critically damped spring: retargeting at the throttle cadence preserves
    /// velocity, so the pinned view glides continuously instead of snapping to
    /// each new bottom position.
    private static let followAnimation = Animation.spring(response: 0.28, dampingFraction: 1.0)

    private func scrollToBottomThrottled() {
        guard enabled, let id = store.activeID else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastScrollAt)
        if elapsed >= Self.minScrollInterval {
            lastScrollAt = now
            withAnimation(Self.followAnimation) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        } else if !trailingScrollScheduled {
            trailingScrollScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.minScrollInterval - elapsed)) {
                trailingScrollScheduled = false
                guard enabled, let id = store.activeID else { return }
                lastScrollAt = Date()
                withAnimation(Self.followAnimation) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }
}


#endif
