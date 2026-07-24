import SwiftUI

struct FlashcardsHomeView: View {
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @ObservedObject private var store = FlashcardDeckStore.shared
    @ObservedObject private var generation = FlashcardGenerationController.shared

    @State private var showGeneration = false
    @State private var renamingDeckID: UUID?
    @State private var renameText = ""
    @State private var deletingDeckID: UUID?

    var body: some View {
#if os(macOS)
        macBody
            .modifier(FlashcardsHomeChrome(
                store: store,
                showGeneration: $showGeneration,
                renamingDeckID: $renamingDeckID,
                renameText: $renameText,
                deletingDeckID: $deletingDeckID,
                chatVM: chatVM,
                modelManager: modelManager
            ))
#else
        formBody
            .modifier(FlashcardsHomeChrome(
                store: store,
                showGeneration: $showGeneration,
                renamingDeckID: $renamingDeckID,
                renameText: $renameText,
                deletingDeckID: $deletingDeckID,
                chatVM: chatVM,
                modelManager: modelManager
            ))
#endif
    }

    private var deletingDeck: FlashcardDeck? {
        deletingDeckID.flatMap { store.deck(id: $0) }
    }

    // MARK: iOS / visionOS

#if !os(macOS)
    private var formBody: some View {
        Group {
            if store.decks.isEmpty && !generation.hasPendingResult && !generation.isRunning {
                emptyState
            } else {
                List {
                    if generation.isRunning || generation.hasPendingResult {
                        Section {
                            generationBanner
                        }
                    }
                    Section {
                        ForEach(store.decks) { deck in
                            NavigationLink {
                                FlashcardDeckDetailView(deckID: deck.id)
                            } label: {
                                FlashcardDeckRow(deck: deck)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deletingDeckID = deck.id
                                } label: {
                                    Label(LocalizedStringKey("Delete"), systemImage: "trash")
                                }
                                Button {
                                    beginRename(deck)
                                } label: {
                                    Label(LocalizedStringKey("Rename"), systemImage: "pencil")
                                }
                            }
                            .contextMenu { deckMenu(deck) }
                        }
                    }
                }
#if os(iOS)
                .listStyle(.insetGrouped)
#endif
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showGeneration = true
                } label: {
                    Label(LocalizedStringKey("New Deck"), systemImage: "plus")
                }
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.purple)
                        .padding(.top, 6)
                    Text(LocalizedStringKey("No flashcard decks yet"))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(LocalizedStringKey("Generate a deck from a topic, or ground one in an indexed dataset."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    showGeneration = true
                } label: {
                    Label(LocalizedStringKey("New Deck"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.purple)
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }
#endif

    // MARK: macOS

#if os(macOS)
    private var macBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if generation.isRunning || generation.hasPendingResult {
                    Button {
                        showGeneration = true
                    } label: {
                        generationBanner
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .flashcardCard()
                }

                VStack(alignment: .leading, spacing: 8) {
                    IndustrialSectionHeader(LocalizedStringKey("Decks")) {
                        Button {
                            showGeneration = true
                        } label: {
                            Label(LocalizedStringKey("New Deck"), systemImage: "plus")
                        }
                        .buttonStyle(.industrial(.prominent, tint: .purple))
                    }

                    if store.decks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(LocalizedStringKey("No flashcard decks yet"))
                                .font(.system(size: 14, weight: .medium))
                            Text(LocalizedStringKey("Generate a deck from a topic, or ground one in an indexed dataset."))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .flashcardCard()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(store.decks.enumerated()), id: \.element.id) { idx, deck in
                                NavigationLink {
                                    FlashcardDeckDetailView(deckID: deck.id)
                                } label: {
                                    FlashcardDeckRow(deck: deck)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu { deckMenu(deck) }

                                if idx < store.decks.count - 1 {
                                    IndustrialHairline().padding(.leading, 46)
                                }
                            }
                        }
                        .flashcardCard()
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }
#endif

    // MARK: Shared pieces

    private var generationBanner: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.purple.opacity(0.16))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: generation.isRunning ? "sparkles" : "checkmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.purple)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(generation.isRunning
                     ? LocalizedStringKey("Generating cards…")
                     : LocalizedStringKey("Cards ready to review"))
                    .font(.body)
                if let context = generation.context {
                    Text(verbatim: context.topic)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if generation.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.25))
            }
        }
#if !os(macOS)
        .contentShape(Rectangle())
        .onTapGesture { showGeneration = true }
#endif
    }

    @ViewBuilder
    private func deckMenu(_ deck: FlashcardDeck) -> some View {
        Button {
            beginRename(deck)
        } label: {
            Label(LocalizedStringKey("Rename"), systemImage: "pencil")
        }
        Button(role: .destructive) {
            deletingDeckID = deck.id
        } label: {
            Label(LocalizedStringKey("Delete"), systemImage: "trash")
        }
    }

    private func beginRename(_ deck: FlashcardDeck) {
        renameText = deck.name
        renamingDeckID = deck.id
    }
}

/// Navigation title, generation sheet, rename alert, and delete confirmation —
/// shared by both platform bodies.
private struct FlashcardsHomeChrome: ViewModifier {
    @ObservedObject var store: FlashcardDeckStore
    @Binding var showGeneration: Bool
    @Binding var renamingDeckID: UUID?
    @Binding var renameText: String
    @Binding var deletingDeckID: UUID?
    let chatVM: ChatVM
    let modelManager: AppModelManager

    func body(content: Content) -> some View {
        content
            .navigationTitle(LocalizedStringKey("Flashcards"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .sheet(isPresented: $showGeneration) {
                FlashcardGenerationView()
                    .environmentObject(chatVM)
                    .environmentObject(modelManager)
            }
            .alert(
                Text(LocalizedStringKey("Rename Deck")),
                isPresented: Binding(
                    get: { renamingDeckID != nil },
                    set: { if !$0 { renamingDeckID = nil } }
                )
            ) {
                TextField(LocalizedStringKey("Deck name"), text: $renameText)
                Button(LocalizedStringKey("Save")) {
                    if let id = renamingDeckID {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            store.rename(deckID: id, to: trimmed)
                        }
                    }
                    renamingDeckID = nil
                }
                Button(LocalizedStringKey("Cancel"), role: .cancel) {
                    renamingDeckID = nil
                }
            }
            .alert(
                Text(LocalizedStringKey("Delete Deck?")),
                isPresented: Binding(
                    get: { deletingDeckID != nil },
                    set: { if !$0 { deletingDeckID = nil } }
                )
            ) {
                Button(LocalizedStringKey("Delete"), role: .destructive) {
                    if let id = deletingDeckID {
                        store.delete(deckID: id)
                    }
                    deletingDeckID = nil
                }
                Button(LocalizedStringKey("Cancel"), role: .cancel) {
                    deletingDeckID = nil
                }
            } message: {
                if let id = deletingDeckID, let deck = store.deck(id: id) {
                    Text(String.localizedStringWithFormat(
                        String(localized: "This deletes the deck and its %d cards. This can't be undone."),
                        deck.cards.count
                    ))
                }
            }
    }
}

struct FlashcardDeckRow: View {
    let deck: FlashcardDeck

    private var dueCount: Int {
        FlashcardLeitnerScheduler.dueCount(in: deck)
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.purple.opacity(0.16))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.purple)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: deck.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(String.localizedStringWithFormat(String(localized: "%d cards"), deck.cards.count))
#if os(macOS)
                    .font(.system(size: 11, design: .monospaced))
#else
                    .font(.footnote)
#endif
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if dueCount > 0 {
                IndustrialBadge(
                    verbatim: String.localizedStringWithFormat(String(localized: "%d due"), dueCount),
                    tint: .purple,
                    dot: true
                )
            } else {
                Text(LocalizedStringKey("Up to date"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.primary.opacity(0.35))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Quiet rounded card surface used across the Flashcards screens (the
    /// Benchmarking Center's benchCard recipe).
    func flashcardCard(_ radius: CGFloat = 10) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.flashcardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

extension Color {
    static var flashcardSurface: Color {
#if os(macOS)
        Color(nsColor: .controlBackgroundColor)
#else
        Color(.secondarySystemGroupedBackground)
#endif
    }
}
