import SwiftUI

struct FlashcardGenerationView: View {
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @ObservedObject private var generation = FlashcardGenerationController.shared
    @Environment(\.dismiss) private var dismiss

    @State private var deckName = ""
    @State private var topic = ""
    @State private var cardCount = 10
    @State private var selectedDatasetID: String?
    @State private var selectedModelPath: String?
    @State private var eligibleModels: [LocalModel] = []
    @State private var datasets: [LocalDataset] = []
    @State private var datasetMissingNotice = false
    @State private var editingCard: Flashcard?
    @AppStorage("flashcards.lastModelPath") private var lastModelPath = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch generation.phase {
                    case .idle:
                        formSections
                    case .failed(let message, let rawOutput, let canFallback):
                        formSections
                        failureSection(message: message, rawOutput: rawOutput, canFallback: canFallback)
                    case .running:
                        runningSection
                    case .preview(let cards):
                        previewSection(cards)
                    }
                }
                .frame(maxWidth: 660, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(pageBackground.ignoresSafeArea())
            .navigationTitle(LocalizedStringKey("New Flashcard Deck"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(closeLabel) { dismiss() }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
#endif
        .onAppear(perform: prepare)
        .sheet(item: $editingCard) { card in
            FlashcardEditorSheet(card: card, showsDelete: true) { updated in
                updatePreviewCard(updated)
            } onDelete: {
                removePreviewCard(id: card.id)
            }
        }
    }

    private var closeLabel: LocalizedStringKey {
        generation.isRunning || generation.hasPendingResult ? "Close" : "Cancel"
    }

    // MARK: Form

    @ViewBuilder
    private var formSections: some View {
        topicSection
        optionsSection
        modelSection
        generateSection
    }

    private var topicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(LocalizedStringKey("Topic"))

            TextField(LocalizedStringKey("Deck name (optional)"), text: $deckName)
#if os(macOS)
                .industrialField()
#else
                .padding(10)
                .flashcardCard()
                .textFieldStyle(.plain)
#endif

            ZStack(alignment: .topLeading) {
                TextEditor(text: $topic)
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if topic.isEmpty {
                    Text(LocalizedStringKey("What should the cards cover? Paste notes or describe a topic."))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .flashcardCard()
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(LocalizedStringKey("Options"))

            IndustrialStepperRow(
                label: "Number of cards",
                display: "\(cardCount)",
                value: $cardCount,
                range: FlashcardGenerationService.minCardCount...FlashcardGenerationService.maxCardCount
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .flashcardCard()

            datasetPicker

            if datasets.isEmpty {
                Text(LocalizedStringKey("Index a dataset in Stored to ground cards in your documents."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if datasetMissingNotice {
                Text(LocalizedStringKey("Dataset no longer available."))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var datasetPicker: some View {
        Menu {
            Button {
                selectedDatasetID = nil
            } label: {
                if selectedDatasetID == nil {
                    Label(LocalizedStringKey("None — model knowledge only"), systemImage: "checkmark")
                } else {
                    Text(LocalizedStringKey("None — model knowledge only"))
                }
            }
            ForEach(datasets) { dataset in
                Button {
                    selectedDatasetID = dataset.datasetID
                    datasetMissingNotice = false
                } label: {
                    if dataset.datasetID == selectedDatasetID {
                        Label(dataset.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: dataset.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let dataset = selectedDataset {
                    Text(verbatim: dataset.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text(LocalizedStringKey("None — model knowledge only"))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .flashcardCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(datasets.isEmpty)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(LocalizedStringKey("Model"))

            if modelManager.downloadedModels.isEmpty {
                Text(LocalizedStringKey("Install a model in Stored to generate flashcards."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .flashcardCard()
            } else if eligibleModels.isEmpty {
                Text(LocalizedStringKey("No tool-capable models installed. Install one in Stored to generate flashcards."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .flashcardCard()
            } else {
                modelPicker

                if let model = selectedModel, model.format != .gguf {
                    Text(LocalizedStringKey("Structured output is most reliable with GGUF models."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let loaded = modelManager.loadedModel,
                   let model = selectedModel,
                   loaded.url != model.url {
                    Text(LocalizedStringKey("Generating will unload your current chat model."))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var modelPicker: some View {
        Menu {
            ForEach(eligibleModels) { model in
                Button {
                    selectedModelPath = model.url.path
                } label: {
                    if model.url.path == selectedModel?.url.path {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(verbatim: model.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                if let model = selectedModel {
                    formatBadge(model.format)
                    Text(verbatim: model.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(verbatim: String(format: "%.1f GB", model.sizeGB))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(LocalizedStringKey("Select a model"))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .flashcardCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                startGeneration(overrideDatasetID: selectedDatasetID)
            } label: {
                Label(LocalizedStringKey("Generate Cards"), systemImage: "sparkles")
                    .industrialCTAWidth()
            }
            .buttonStyle(.industrial(.prominent, tint: .purple))
            .disabled(!canGenerate)

            if chatBusy {
                Text(LocalizedStringKey("Waiting for the current chat response to finish…"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chatBusy: Bool {
        chatVM.isStreaming || chatVM.isStreamingInAnotherSession || chatVM.loading
    }

    private var canGenerate: Bool {
        !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedModel != nil
            && !chatBusy
            && !generation.isRunning
    }

    // MARK: Running

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(LocalizedStringKey("Generating"))

            if let context = generation.context {
                Text(verbatim: context.topic)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 6) {
                IndustrialProgressBar(value: generation.progress, tint: .purple)
                Text(generation.progressDetail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button(role: .cancel) {
                generation.cancel()
            } label: {
                Text(LocalizedStringKey("Cancel"))
            }
            .buttonStyle(.industrial(.quiet))
        }
    }

    // MARK: Failure

    private func failureSection(message: String, rawOutput: String?, canFallback: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: message)
                .font(.footnote)
                .foregroundStyle(.red)

            if canFallback {
                Button {
                    startGeneration(overrideDatasetID: nil)
                } label: {
                    Text(LocalizedStringKey("Generate without dataset"))
                }
                .buttonStyle(.industrial(.tinted, tint: .purple))
            }

            if let rawOutput, !rawOutput.isEmpty {
                DisclosureGroup {
                    Text(verbatim: rawOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .flashcardCard()
                } label: {
                    Text(LocalizedStringKey("Show model output"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Preview

    private func previewSection(_ cards: [Flashcard]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(
                LocalizedStringKey("Preview"),
                detail: String.localizedStringWithFormat(String(localized: "Generated %d cards"), cards.count)
            )

            if let context = generation.context, cards.count < context.cardCount {
                Text(String.localizedStringWithFormat(
                    String(localized: "Generated %1$d of %2$d requested cards."),
                    cards.count, context.cardCount
                ))
                .font(.footnote)
                .foregroundStyle(.orange)
            }
            if let context = generation.context, let datasetName = context.datasetName {
                Text(String.localizedStringWithFormat(
                    String(localized: "Grounded in %@"),
                    datasetName
                ))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { idx, card in
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

                        Button {
                            removePreviewCard(id: card.id)
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

                    if idx < cards.count - 1 {
                        Divider().overlay(Color.primary.opacity(0.06))
                    }
                }
            }
            .flashcardCard()

            HStack(spacing: 10) {
                Button {
                    saveDeck(cards)
                } label: {
                    Label(LocalizedStringKey("Save Deck"), systemImage: "tray.and.arrow.down")
                        .industrialCTAWidth()
                }
                .buttonStyle(.industrial(.prominent, tint: .purple))
                .disabled(cards.isEmpty)

                Button {
                    generation.returnToForm()
                } label: {
                    Text(LocalizedStringKey("Edit Prompt"))
                }
                .buttonStyle(.industrial(.quiet))
            }
        }
    }

    // MARK: Actions

    private func prepare() {
        refreshEligibleModels()
        datasets = DatasetManager.indexedDatasetsForTooling()
        if let context = generation.context {
            deckName = context.deckName
            topic = context.topic
            cardCount = context.cardCount
            selectedDatasetID = context.datasetID
        }
        if selectedModelPath == nil, !lastModelPath.isEmpty,
           eligibleModels.contains(where: { $0.url.path == lastModelPath }) {
            selectedModelPath = lastModelPath
        }
    }

    private func refreshEligibleModels() {
        // isToolCapableLocal can touch disk — compute once, not in body.
        eligibleModels = modelManager.downloadedModels.filter { model in
            model.format != .ane
                && (model.isToolCapable
                    || ToolCapabilityDetector.isToolCapableLocal(url: model.url, format: model.format))
        }
    }

    private var selectedModel: LocalModel? {
        guard let path = selectedModelPath else {
            if let loaded = modelManager.loadedModel,
               eligibleModels.contains(where: { $0.url.path == loaded.url.path }) {
                return eligibleModels.first { $0.url.path == loaded.url.path }
            }
            return eligibleModels.first
        }
        return eligibleModels.first { $0.url.path == path }
    }

    private var selectedDataset: LocalDataset? {
        guard let id = selectedDatasetID else { return nil }
        return datasets.first { $0.datasetID == id }
    }

    private func startGeneration(overrideDatasetID: String?) {
        guard !generation.isRunning, !chatBusy else { return }
        refreshEligibleModels()
        guard let model = selectedModel else { return }
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else { return }

        var dataset: LocalDataset?
        if let datasetID = overrideDatasetID {
            // Re-resolve at tap: the dataset may have been deleted, expired,
            // or newly blocked by enterprise policy since the picker opened.
            datasets = DatasetManager.indexedDatasetsForTooling()
            dataset = datasets.first { $0.datasetID == datasetID }
            if dataset == nil {
                selectedDatasetID = nil
                datasetMissingNotice = true
                return
            }
        } else {
            selectedDatasetID = nil
        }
        datasetMissingNotice = false
        lastModelPath = model.url.path
        selectedModelPath = model.url.path

        let request = FlashcardGenerationRequest(
            topic: trimmedTopic,
            cardCount: cardCount,
            dataset: dataset,
            model: model,
            settings: modelManager.settings(for: model)
        )
        generation.start(request: request, deckName: deckName, vm: chatVM)
    }

    private func updatePreviewCard(_ card: Flashcard) {
        guard case .preview(var cards) = generation.phase else { return }
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
            generation.updatePreview(cards: cards)
        }
    }

    private func removePreviewCard(id: UUID) {
        guard case .preview(var cards) = generation.phase else { return }
        cards.removeAll { $0.id == id }
        generation.updatePreview(cards: cards)
    }

    private func saveDeck(_ cards: [Flashcard]) {
        guard let context = generation.context else { return }
        let trimmedName = deckName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = String(context.topic.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        let deck = FlashcardDeck(
            name: trimmedName.isEmpty ? fallbackName : trimmedName,
            topic: context.topic,
            cards: cards,
            sourceModelName: context.modelName,
            sourceDatasetID: context.datasetID,
            sourceDatasetName: context.datasetName
        )
        FlashcardDeckStore.shared.upsert(deck)
        generation.reset()
        AccessibilityAnnouncer.announceLocalized("Deck saved.")
        dismiss()
    }

    // MARK: Style helpers

    private func formatBadge(_ format: ModelFormat) -> some View {
        Text(format.rawValue)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(formatColor(format))
            )
    }

    private func formatColor(_ format: ModelFormat) -> Color {
        switch format {
        case .gguf: return .blue
        case .mlx: return .orange
        case .et: return .teal
        case .ane: return .green
        case .afm: return .indigo
        case .coreai: return .purple
        }
    }

    private var horizontalPadding: CGFloat {
#if os(macOS)
        return 20
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
