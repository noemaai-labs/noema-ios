import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct FlashcardStudyView: View {
    let deckID: UUID
    let reviewAll: Bool

    @ObservedObject private var store = FlashcardDeckStore.shared
    @State private var queueIDs: [UUID] = []
    @State private var position = 0
    @State private var isFlipped = false
    /// Once the answer has been seen, the card can be flipped back and forth
    /// freely and the grade buttons stay available on either face.
    @State private var hasRevealed = false
    @State private var tallyMissed = 0
    @State private var tallyKnew = 0
    @State private var sessionComplete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var cardFocused: Bool

    private var deck: FlashcardDeck? {
        store.deck(id: deckID)
    }

    private var currentCard: Flashcard? {
        guard let deck, position < queueIDs.count else { return nil }
        return deck.cards.first { $0.id == queueIDs[position] }
    }

    private var isVoiceOverActive: Bool {
#if canImport(UIKit)
        UIAccessibility.isVoiceOverRunning
#elseif canImport(AppKit)
        NSWorkspace.shared.isVoiceOverEnabled
#else
        false
#endif
    }

    private var motionSafe: Bool {
        !reduceMotion && !isVoiceOverActive
    }

    var body: some View {
        Group {
            if let deck {
                if sessionComplete {
                    summaryView(deck)
                } else if let card = currentCard {
                    studyLayout(card)
                } else {
                    // Queue exhausted by deletions or an empty deck.
                    summaryView(deck)
                }
            } else {
                deckDeletedState
            }
        }
        .navigationTitle(deck?.name ?? "")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .onAppear(perform: startSession)
        .onDisappear { store.flushPendingSave() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.flushPendingSave()
            }
        }
    }

    private var deckDeletedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey("Deck deleted"))
                .font(.headline)
            Button(LocalizedStringKey("Done")) { dismiss() }
                .buttonStyle(.industrial(.quiet))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Session

    private func startSession() {
        guard queueIDs.isEmpty, let deck else { return }
        let queue = FlashcardLeitnerScheduler.buildQueue(for: deck)
        queueIDs = queue.cards.map(\.id)
        position = 0
        isFlipped = false
        hasRevealed = false
        sessionComplete = queueIDs.isEmpty
        skipMissingCards()
    }

    private func toggleFlip() {
        isFlipped.toggle()
        if isFlipped {
            hasRevealed = true
            AccessibilityAnnouncer.announceLocalized("Answer shown.")
        }
    }

    private func grade(_ grade: FlashcardGrade) {
        guard hasRevealed, let card = currentCard else { return }
        store.applyReview(deckID: deckID, cardID: card.id, grade: grade)
        switch grade {
        case .again:
            tallyMissed += 1
            // Box 1 has a zero-day interval, so the card is still due today:
            // resurface it at the end of this session's queue.
            queueIDs.append(card.id)
        case .good, .easy:
            tallyKnew += 1
        }
        isFlipped = false
        hasRevealed = false
        position += 1
        skipMissingCards()
        if position >= queueIDs.count {
            completeSession()
        } else {
            AccessibilityAnnouncer.announceLocalized("Next card.")
            if isVoiceOverActive {
                cardFocused = true
            }
        }
    }

    private func skipMissingCards() {
        guard let deck else { return }
        let cardIDs = Set(deck.cards.map(\.id))
        while position < queueIDs.count, !cardIDs.contains(queueIDs[position]) {
            position += 1
        }
    }

    private func completeSession() {
        sessionComplete = true
        store.flushPendingSave()
        AccessibilityAnnouncer.announceLocalized("Session complete.")
    }

    private func restartWithRemainingDue() {
        guard let deck else { return }
        let queue = FlashcardLeitnerScheduler.buildQueue(for: deck)
        guard !queue.isReviewAhead, !queue.cards.isEmpty else { return }
        queueIDs = queue.cards.map(\.id)
        position = 0
        isFlipped = false
        hasRevealed = false
        tallyMissed = 0
        tallyKnew = 0
        sessionComplete = false
        skipMissingCards()
    }

    // MARK: Layout

    private func studyLayout(_ card: Flashcard) -> some View {
        VStack(spacing: 16) {
            progressHeader

            Spacer(minLength: 0)

            flipCard(card)
                .id(position)
                .transition(advanceTransition)
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)

            Spacer(minLength: 0)

            gradeBar
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

#if os(macOS)
            Text(LocalizedStringKey("Space to flip · 1–2 to grade"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.35))
                .padding(.bottom, 12)
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pageBackground.ignoresSafeArea())
        .animation(motionSafe ? .easeInOut(duration: 0.25) : nil, value: position)
    }

    private var progressHeader: some View {
        VStack(spacing: 6) {
            Text(String.localizedStringWithFormat(
                String(localized: "Card %1$d of %2$d"),
                min(position + 1, max(1, queueIDs.count)), max(1, queueIDs.count)
            ))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            IndustrialProgressBar(
                value: Double(position) / Double(max(1, queueIDs.count)),
                tint: .purple
            )
            .padding(.horizontal, 20)
        }
        .padding(.top, 12)
    }

    private var advanceTransition: AnyTransition {
        guard motionSafe else { return .opacity }
        let leading: Edge = layoutDirection == .rightToLeft ? .trailing : .leading
        let trailing: Edge = layoutDirection == .rightToLeft ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: trailing).combined(with: .opacity),
            removal: .move(edge: leading).combined(with: .opacity)
        )
    }

    // MARK: Flip card

    private func flipCard(_ card: Flashcard) -> some View {
        Button {
            toggleFlip()
        } label: {
            ZStack {
                cardFace {
                    VStack(spacing: 10) {
                        Text(verbatim: card.front)
                            .font(.title3.weight(.medium))
                            .multilineTextAlignment(.center)
                        if let hint = card.hint {
                            Text(verbatim: hint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Text(LocalizedStringKey("Tap to reveal"))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .textCase(.uppercase)
                            .foregroundStyle(Color.primary.opacity(0.3))
                    }
                }
                .opacity(isFlipped ? 0 : 1)

                cardFace {
                    VStack(spacing: 10) {
                        Text(verbatim: card.front)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text(verbatim: card.back)
                            .font(.body)
                            .multilineTextAlignment(.center)
                    }
                }
                .rotation3DEffect(.degrees(motionSafe ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)
            }
            .rotation3DEffect(
                .degrees(motionSafe && isFlipped ? 180 : 0),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.5
            )
            .animation(
                motionSafe ? .spring(response: 0.4, dampingFraction: 0.8) : .easeInOut(duration: 0.15),
                value: isFlipped
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(String.localizedStringWithFormat(
            String(localized: "Card %1$d of %2$d"),
            min(position + 1, max(1, queueIDs.count)), max(1, queueIDs.count)
        )))
        .accessibilityHint(isFlipped
                           ? Text(LocalizedStringKey("Double tap to show the question."))
                           : Text(LocalizedStringKey("Double tap to show the answer.")))
        .accessibilityFocused($cardFocused)
    }

    private func cardFace<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .padding(24)
        }
        .frame(minHeight: 220, maxHeight: 360)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.flashcardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: Grade bar

    private var gradeBar: some View {
        Group {
            if hasRevealed {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { gradeButtons }
                    VStack(spacing: 8) { gradeButtons }
                }
                // Keeps Space flipping the card after Show Answer disappears.
                .background(
                    Button(action: toggleFlip) { EmptyView() }
                        .keyboardShortcut(.space, modifiers: [])
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                )
            } else {
                showAnswerButton
            }
        }
        .frame(minHeight: 52)
    }

    private var showAnswerButton: some View {
        Button {
            toggleFlip()
        } label: {
            Text(LocalizedStringKey("Show Answer"))
                .industrialCTAWidth()
        }
        .buttonStyle(.industrial(.prominent, tint: .purple))
        .keyboardShortcut(.space, modifiers: [])
    }

    @ViewBuilder
    private var gradeButtons: some View {
        Button {
            grade(.again)
        } label: {
            Label(LocalizedStringKey("Didn't Know"), systemImage: "arrow.counterclockwise")
                .industrialCTAWidth()
        }
        .buttonStyle(.industrial(.tinted, tint: .orange))
        .keyboardShortcut("1", modifiers: [])
        .accessibilityHint(Text(LocalizedStringKey("Repeats this card soon.")))

        Button {
            grade(.good)
        } label: {
            Label(LocalizedStringKey("Knew It"), systemImage: "checkmark")
                .industrialCTAWidth()
        }
        .buttonStyle(.industrial(.tinted, tint: .green))
        .keyboardShortcut("2", modifiers: [])
        .accessibilityHint(Text(LocalizedStringKey("Schedules this card for later.")))
    }

    // MARK: Summary

    private func summaryView(_ deck: FlashcardDeck) -> some View {
        let reviewed = tallyMissed + tallyKnew
        let remainingDue = FlashcardLeitnerScheduler.dueCount(in: deck)
        return VStack(spacing: 14) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 34))
                .foregroundStyle(.purple)
            Text(LocalizedStringKey("Session Complete"))
                .font(.title2.weight(.semibold))
            Text(String.localizedStringWithFormat(
                String(localized: "%d cards reviewed"), reviewed))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(String.localizedStringWithFormat(
                String(localized: "Missed %1$d · Knew %2$d"),
                tallyMissed, tallyKnew
            ))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Text(LocalizedStringKey("Done"))
                }
                .buttonStyle(.industrial(.prominent, tint: .purple))

                if remainingDue > 0 {
                    Button {
                        restartWithRemainingDue()
                    } label: {
                        Text(LocalizedStringKey("Study Again"))
                    }
                    .buttonStyle(.industrial(.quiet))
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(pageBackground.ignoresSafeArea())
    }

    private var pageBackground: Color {
#if os(macOS)
        return .clear
#else
        return Color(.systemGroupedBackground)
#endif
    }
}
