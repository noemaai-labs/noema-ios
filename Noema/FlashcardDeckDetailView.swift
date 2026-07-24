import SwiftUI

struct FlashcardDeckDetailView: View {
    let deckID: UUID

    @ObservedObject private var store = FlashcardDeckStore.shared
    @State private var editingCard: Flashcard?
    @State private var addingCard = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDelete = false
    @Environment(\.dismiss) private var dismiss

    private var deck: FlashcardDeck? {
        store.deck(id: deckID)
    }

    var body: some View {
        Group {
            if let deck {
                content(deck)
            } else {
                deckDeletedState
            }
        }
        .sheet(item: $editingCard) { card in
            FlashcardEditorSheet(card: card, showsDelete: true) { updated in
                store.updateCard(updated, in: deckID)
            } onDelete: {
                store.deleteCard(id: card.id, from: deckID)
            }
        }
        .sheet(isPresented: $addingCard) {
            FlashcardEditorSheet(card: nil, showsDelete: false, onSave: { newCard in
                store.addCard(newCard, to: deckID)
            }, onDelete: nil)
        }
    }

    private var deckDeletedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey("Deck deleted"))
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func content(_ deck: FlashcardDeck) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                studySection(deck)
                cardsSection(deck)
            }
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(pageBackground.ignoresSafeArea())
        .navigationTitle(deck.name)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        addingCard = true
                    } label: {
                        Label(LocalizedStringKey("Add Card"), systemImage: "plus")
                    }
                    Button {
                        renameText = deck.name
                        showRename = true
                    } label: {
                        Label(LocalizedStringKey("Rename"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDelete = true
                    } label: {
                        Label(LocalizedStringKey("Delete"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert(Text(LocalizedStringKey("Rename Deck")), isPresented: $showRename) {
            TextField(LocalizedStringKey("Deck name"), text: $renameText)
            Button(LocalizedStringKey("Save")) {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    store.rename(deckID: deckID, to: trimmed)
                }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {}
        }
        .alert(Text(LocalizedStringKey("Delete Deck?")), isPresented: $showDelete) {
            Button(LocalizedStringKey("Delete"), role: .destructive) {
                store.delete(deckID: deckID)
                dismiss()
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {}
        } message: {
            Text(String.localizedStringWithFormat(
                String(localized: "This deletes the deck and its %d cards. This can't be undone."),
                deck.cards.count
            ))
        }
    }

    // MARK: Study section

    private func studySection(_ deck: FlashcardDeck) -> some View {
        let dueCount = FlashcardLeitnerScheduler.dueCount(in: deck)
        return VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(LocalizedStringKey("Study"))

            if deck.cards.isEmpty {
                Text(LocalizedStringKey("Add or generate cards to start studying."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .flashcardCard()
            } else if dueCount > 0 {
                NavigationLink {
                    FlashcardStudyView(deckID: deck.id, reviewAll: false)
                } label: {
                    Label {
                        Text(String.localizedStringWithFormat(
                            String(localized: "Study %d Due Cards"), dueCount))
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                    .industrialCTAWidth()
                }
                .buttonStyle(.industrial(.prominent, tint: .purple))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringKey("All caught up — no cards due."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let next = FlashcardLeitnerScheduler.nextDueDate(in: deck) {
                        Text(String.localizedStringWithFormat(
                            String(localized: "Next review %@"),
                            next.formatted(.relative(presentation: .named))
                        ))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        FlashcardStudyView(deckID: deck.id, reviewAll: true)
                    } label: {
                        Text(LocalizedStringKey("Review All"))
                    }
                    .buttonStyle(.industrial(.quiet))
                }
            }

            if let modelName = deck.sourceModelName {
                Text(String.localizedStringWithFormat(
                    String(localized: "Generated by %@"),
                    modelName
                ))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.4))
            }
            if let datasetName = deck.sourceDatasetName {
                Text(String.localizedStringWithFormat(
                    String(localized: "Grounded in %@"),
                    datasetName
                ))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.4))
            }
        }
    }

    // MARK: Cards section

    private func cardsSection(_ deck: FlashcardDeck) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(
                LocalizedStringKey("Cards"),
                detail: String.localizedStringWithFormat(String(localized: "%d cards"), deck.cards.count)
            ) {
                Button {
                    addingCard = true
                } label: {
                    Label(LocalizedStringKey("Add Card"), systemImage: "plus")
                }
                .buttonStyle(.industrial(.quiet))
            }

            if deck.cards.isEmpty {
                Text(LocalizedStringKey("No cards in this deck yet."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .flashcardCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(deck.cards.enumerated()), id: \.element.id) { idx, card in
                        cardRow(card)
                        if idx < deck.cards.count - 1 {
                            Divider().overlay(Color.primary.opacity(0.06))
                        }
                    }
                }
                .flashcardCard()
            }
        }
    }

    private func cardRow(_ card: Flashcard) -> some View {
        HStack(spacing: 10) {
            Button {
                editingCard = card
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: card.front)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: card.back)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            IndustrialBadge(masteryTitle(card), tint: masteryTint(card))

            Button {
                store.deleteCard(id: card.id, from: deckID)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey("Delete Card")))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // The Leitner box number means nothing to users; surface it as a
    // plain-language mastery level instead.
    private func masteryTitle(_ card: Flashcard) -> LocalizedStringKey {
        if card.reviewCount == 0 { return "New" }
        switch card.box {
        case ...2: return "Learning"
        case 3, 4: return "Familiar"
        default: return "Mastered"
        }
    }

    private func masteryTint(_ card: Flashcard) -> Color {
        if card.reviewCount == 0 { return .secondary }
        switch card.box {
        case ...2: return .orange
        case 3, 4: return .blue
        default: return .green
        }
    }

    private var horizontalPadding: CGFloat {
#if os(macOS)
        return 0
#else
        return 16
#endif
    }

    private var pageBackground: Color {
#if os(macOS)
        return .clear
#else
        return Color(.systemGroupedBackground)
#endif
    }
}

// MARK: - Card editor

struct FlashcardEditorSheet: View {
    private let existingCard: Flashcard?
    private let showsDelete: Bool
    private let onSave: (Flashcard) -> Void
    private let onDelete: (() -> Void)?

    @State private var front: String
    @State private var back: String
    @State private var hint: String
    @Environment(\.dismiss) private var dismiss

    init(card: Flashcard?, showsDelete: Bool, onSave: @escaping (Flashcard) -> Void, onDelete: (() -> Void)?) {
        self.existingCard = card
        self.showsDelete = showsDelete && card != nil
        self.onSave = onSave
        self.onDelete = onDelete
        _front = State(initialValue: card?.front ?? "")
        _back = State(initialValue: card?.back ?? "")
        _hint = State(initialValue: card?.hint ?? "")
    }

    private var canSave: Bool {
        !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field(title: "Front", text: $front)
                    field(title: "Back", text: $back)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey("Hint (optional)"))
                            .textCase(.uppercase)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.6))
                        TextField("", text: $hint)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .flashcardCard()
                    }

                    if showsDelete {
                        Button(role: .destructive) {
                            onDelete?()
                            dismiss()
                        } label: {
                            Label(LocalizedStringKey("Delete Card"), systemImage: "trash")
                        }
                        .buttonStyle(.industrial(.destructive))
                        .padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .navigationTitle(existingCard == nil
                             ? LocalizedStringKey("New Card")
                             : LocalizedStringKey("Edit Card"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("Cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey("Save")) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
#endif
    }

    private func field(title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.6))
            TextEditor(text: text)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(6)
                .flashcardCard()
        }
    }

    private func save() {
        let trimmedFront = front.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBack = back.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFront.isEmpty, !trimmedBack.isEmpty else { return }
        if var card = existingCard {
            card.front = trimmedFront
            card.back = trimmedBack
            card.hint = trimmedHint.isEmpty ? nil : trimmedHint
            onSave(card)
        } else {
            onSave(Flashcard(
                front: trimmedFront,
                back: trimmedBack,
                hint: trimmedHint.isEmpty ? nil : trimmedHint
            ))
        }
        dismiss()
    }
}
