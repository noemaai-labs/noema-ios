import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct LocalDatasetDetailView: View {
    let dataset: LocalDataset
    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var datasetManager: DatasetManager
    @EnvironmentObject var chatVM: ChatVM
    @Environment(\.dismiss) private var dismiss
#if os(macOS)
    @Environment(\.macModalDismiss) private var macModalDismiss
#endif
    @Environment(\.locale) private var locale

    @State private var files: [(name: String, size: String)] = []
    @State private var tokenEstimate: String = ""
    @State private var isEstimatingTokens = false
    @State private var compressedMB: String = ""
    @State private var warmingUpEmbed = false
    @State private var embedReady = false
    @State private var embedProgress: Double = 0.0
    @State private var embedStatusMessage = ""
    @State private var embedStatusPhase: EmbedStatusPhase = .idle
    @StateObject private var embedInstaller = EmbedModelInstaller()
    @State private var showStartOnBatteryConfirm = false
    @State private var showConfirmOnBatteryConfirm = false
    @State private var showDisabledUseReason = false
    @State private var disabledUseReason = ""
    @State private var indexReport: DatasetIndexReport?
    @State private var indexMetadata: DatasetIndexMetadata?
    @State private var datasetPendingDeletion: LocalDataset?

    private func close() {
#if os(macOS)
        macModalDismiss()
#else
        dismiss()
#endif
    }

    var body: some View {
        let displayedDataset = liveDataset
        NavigationStack {
            ScrollView {
#if os(macOS)
                macContent(for: displayedDataset)
#else
                VStack(alignment: .leading, spacing: 24) {
                    VStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 42, height: 5)
                            .frame(maxWidth: .infinity)

                        HStack {
                            Button { close() } label: {
                                Image(systemName: "xmark")
                                    .font(.title3.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .frame(width: 52, height: 52)
                                    .background(
                                        Circle()
                                            .fill(closeButtonBackgroundColor)
                                            .shadow(color: Color.black.opacity(0.06), radius: 14, y: 8)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(LocalizedStringKey("Close")))

                            Spacer(minLength: 0)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text(displayedDataset.name)
                                .font(.largeTitle.weight(.bold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.76)

                            Text(displayedDataset.datasetID)
                                .font(.title3.weight(.bold))

                            Text(displayedDataset.source)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 10)

                    VStack(spacing: 16) {
                        let datasetBytes = Int64(displayedDataset.sizeMB * 1_048_576.0)
                        let sizeString = localizedFileSizeString(bytes: datasetBytes, locale: locale)
                        InfoRow(label: String(localized: "Downloaded"), value: formatDate(displayedDataset.downloadDate))
                        Divider()
                        InfoRow(label: String(localized: "Size"), value: sizeString)
                        
                        if !compressedMB.isEmpty {
                            Divider()
                            InfoRow(label: String(localized: "Compressed Text"), value: compressedMB)
                        }
                        
                        if !tokenEstimate.isEmpty || isEstimatingTokens {
                            Divider()
                            HStack {
                                Text(LocalizedStringKey("Approx. Tokens"))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if isEstimatingTokens {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                        Text(tokenEstimate.isEmpty ? "…" : tokenEstimate)
                                    }
                                } else {
                                    Text(tokenEstimate)
                                        .bold()
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(cardBackgroundColor)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )

                    // RAG-upgrade re-embed recommendation (optional, non-blocking).
                    if datasetManager.isRAGIndexOutdated(for: displayedDataset) {
                        ragUpgradeCard(displayedDataset)
                    }

                    if let metadata = indexMetadata, let fingerprint = metadata.embeddingFingerprint {
                        embeddingCard(metadata: metadata, fingerprint: fingerprint)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizedStringKey("Preparation"))
                            .font(.headline)
                            .padding(.bottom, 4)
                        
                        let status = datasetManager.processingStatus[dataset.datasetID]
                        if let s = status, s.stage != .completed {
                            processingView(status: s)
                        } else {
                            readyView()
                        }
                    }
                    .padding(16)
                    .background(cardBackgroundColor)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    
                    if !files.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(LocalizedStringKey("Files"))
                                .font(.headline)
                                .padding(.bottom, 4)
                            
                            ForEach(files, id: \.name) { file in
                                let fileURL = DatasetPathing.destinationURL(for: file.name, in: displayedDataset.url)
                                NavigationLink(destination: DatasetFileViewer(url: fileURL)) {
                                    HStack {
                                        Image(systemName: "doc.text")
                                            .foregroundStyle(.blue)
                                        Text(file.name)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(file.size)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                
                                if file.name != files.last?.name {
                                    Divider()
                                }
                            }
                        }
                        .padding(16)
                        .background(cardBackgroundColor)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                    }
                    
                    VStack(spacing: 12) {
                        let isReady = isDatasetReady
                        
                        if modelManager.activeDataset?.datasetID == displayedDataset.datasetID {
                            Button {
                                chatVM.setDatasetForActiveSession(nil)
                                close()
                            } label: {
                                Text(LocalizedStringKey("Stop Using Dataset"))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        } else {
                            Button {
                                if isReady {
                                    Task { await logger.log("[UI] User tapped Use Dataset for \(displayedDataset.datasetID)") }
                                    chatVM.setDatasetForActiveSession(displayedDataset)
                                    warmingUpEmbed = true
                                    embedProgress = 0.0
                                    Task { await prepareEmbeddingsAndIndex() }
                                } else {
                                    disabledUseReason = disabledUseDatasetReason
                                    showDisabledUseReason = true
                                }
                            } label: {
                                Text(LocalizedStringKey("Use Dataset"))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!isReady)
                        }
                        
                        Button(role: .destructive) {
                            datasetPendingDeletion = displayedDataset
                        } label: {
                            Text(LocalizedStringKey("Delete Dataset"))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .padding(.bottom, 30)
                }
                .padding(.horizontal, 20)
#endif
            }
            .background(windowBackgroundColor)
            .navigationTitle("")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .alert(LocalizedStringKey("Unavailable"), isPresented: $showDisabledUseReason) {
                Button(LocalizedStringKey("OK"), role: .cancel) { disabledUseReason = "" }
            } message: {
                Text(disabledUseReason.isEmpty ? disabledUseDatasetReason : disabledUseReason)
            }
            .alert(
                datasetDeleteConfirmationTitle,
                isPresented: Binding(
                    get: { datasetPendingDeletion != nil },
                    set: { isPresented in
                        if !isPresented {
                            datasetPendingDeletion = nil
                        }
                    }
                )
            ) {
                Button(LocalizedStringKey("Delete"), role: .destructive) {
                    guard let dataset = datasetPendingDeletion else { return }
                    datasetPendingDeletion = nil
                    try? datasetManager.delete(dataset)
                    close()
                }
                Button(LocalizedStringKey("Cancel"), role: .cancel) {
                    datasetPendingDeletion = nil
                }
            } message: {
                Text(LocalizedStringKey("This will remove the dataset and its embeddings from this device."))
            }
            .task {
                // Opening the detail counts as "seen" → hides the row badge. Only
                // record it for datasets that actually carry the notice.
                if datasetManager.isRAGIndexOutdated(for: dataset) {
                    datasetManager.acknowledgeRAGUpgradeNotice(for: dataset.datasetID)
                }
                loadFiles()
                loadIndexReport()
                loadIndexMetadata()
                await computeCompressedSize()
            }
            .onChange(of: liveDataset.isIndexed) { _ in
                loadIndexMetadata()
                loadIndexReport()
            }
        }
    }

    private var datasetDeleteConfirmationTitle: String {
        guard let dataset = datasetPendingDeletion else { return String(localized: "Delete") }
        return String.localizedStringWithFormat(String(localized: "Delete %@?"), dataset.name)
    }

    // MARK: - Subviews

#if os(macOS)
    private func macContent(for displayedDataset: LocalDataset) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            macHeader(for: displayedDataset)

            if datasetManager.isRAGIndexOutdated(for: displayedDataset) {
                ragUpgradeCard(displayedDataset)
            }

            VStack(alignment: .leading, spacing: 12) {
                IndustrialSectionHeader(
                    "Preparation",
                    dotColor: isDatasetReady ? .green : .orange
                )
                let status = datasetManager.processingStatus[dataset.datasetID]
                if let s = status, s.stage != .completed {
                    processingView(status: s)
                } else {
                    readyView()
                }
            }

            if let metadata = indexMetadata, let fingerprint = metadata.embeddingFingerprint {
                VStack(alignment: .leading, spacing: 12) {
                    IndustrialSectionHeader("Embedding")
                    embeddingRows(metadata: metadata, fingerprint: fingerprint)
                }
            }

            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    IndustrialSectionHeader("Files", detail: "\(files.count)")
                    ForEach(files, id: \.name) { file in
                        MacFileRow(
                            name: file.name,
                            size: file.size,
                            url: DatasetPathing.destinationURL(for: file.name, in: displayedDataset.url)
                        )
                    }
                }
            }

            macActionBar(for: displayedDataset)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private func macHeader(for displayedDataset: LocalDataset) -> some View {
        let datasetBytes = Int64(displayedDataset.sizeMB * 1_048_576.0)
        let sizeString = localizedFileSizeString(bytes: datasetBytes, locale: locale)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if isDatasetReady {
                    IndustrialBadge("Indexed", tint: .green)
                }
                IndustrialBadge(verbatim: sizeString)
            }
            HStack(spacing: 14) {
                IndustrialStatPair(label: "Downloaded", value: formatDate(displayedDataset.downloadDate))
                if !compressedMB.isEmpty {
                    IndustrialStatPair(label: "Compressed Text", value: compressedMB)
                }
                if !tokenEstimate.isEmpty {
                    IndustrialStatPair(label: "Approx. Tokens", value: tokenEstimate)
                }
            }
            Text(verbatim: displayedDataset.datasetID)
                .industrialStat()
        }
    }

    private func macActionBar(for displayedDataset: LocalDataset) -> some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                datasetPendingDeletion = displayedDataset
            } label: {
                Text(LocalizedStringKey("Delete Dataset"))
            }
            .buttonStyle(.industrial(.destructive))

            Spacer()

            if modelManager.activeDataset?.datasetID == displayedDataset.datasetID {
                Button {
                    chatVM.setDatasetForActiveSession(nil)
                    close()
                } label: {
                    Text(LocalizedStringKey("Stop Using Dataset"))
                }
                .buttonStyle(.industrial(.quiet))
            } else {
                Button {
                    if isDatasetReady {
                        Task { await logger.log("[UI] User tapped Use Dataset for \(displayedDataset.datasetID)") }
                        chatVM.setDatasetForActiveSession(displayedDataset)
                        warmingUpEmbed = true
                        embedProgress = 0.0
                        Task { await prepareEmbeddingsAndIndex() }
                    } else {
                        disabledUseReason = disabledUseDatasetReason
                        showDisabledUseReason = true
                    }
                } label: {
                    Text(LocalizedStringKey("Use Dataset"))
                }
                .buttonStyle(.industrial(.prominent))
                .keyboardShortcut(.defaultAction)
                .disabled(!isDatasetReady)
            }
        }
        .padding(.top, 4)
    }

    private struct MacFileRow: View {
        let name: String
        let size: String
        let url: URL

        @State private var hovering = false

        var body: some View {
            NavigationLink(destination: DatasetFileViewer(url: url)) {
                HStack(spacing: 9) {
                    Text(name)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(verbatim: size)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.4))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.3))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.045) : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
#endif

    private struct InfoRow: View {
        let label: String
        let value: String

        var body: some View {
#if os(macOS)
            HStack(spacing: 8) {
                Text(label)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .lineLimit(1)
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
#else
            HStack {
                Text(label)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Text(value)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
#endif
        }
    }
    
    @ViewBuilder
    private func ragUpgradeCard(_ dataset: LocalDataset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text(LocalizedStringKey("Retrieval improvements available"))
                    .font(.headline)
            }
            Text(LocalizedStringKey("This dataset was indexed before Noema's latest retrieval improvements — better text extraction from PDFs, smarter chunking, and more accurate search. It still works as-is, so re-embedding is optional; it just refreshes the index with the improvements."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Tapping starts a full re-embed; this card then disappears (the index
            // is cleared) and the Preparation card below shows live progress.
            Button {
                datasetManager.reembedForRAGUpgrade(datasetID: dataset.datasetID)
            } label: {
                Label(LocalizedStringKey("Re-embed now"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.industrial(.prominent, tint: .orange))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func embeddingCard(metadata: DatasetIndexMetadata, fingerprint: EmbeddingIndexFingerprint) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey("Embedding"))
                .font(.headline)
                .padding(.bottom, 4)

            embeddingRows(metadata: metadata, fingerprint: fingerprint)
        }
        .padding(16)
        .background(cardBackgroundColor)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func embeddingRows(metadata: DatasetIndexMetadata, fingerprint: EmbeddingIndexFingerprint) -> some View {
        let record = EmbeddingModelCatalog.record(for: fingerprint.modelID)
        let modelDisplay = record?.displayName ?? fingerprint.modelID
        let quantization = record?.artifacts.first(where: { $0.id == fingerprint.artifactID })?.quantization
            ?? record?.primaryArtifact?.quantization
#if os(macOS)
        let rowSpacing: CGFloat = 8
#else
        let rowSpacing: CGFloat = 16
#endif

        VStack(spacing: rowSpacing) {
                InfoRow(label: String(localized: "Model"), value: modelDisplay)
                if let publisher = record?.publisher {
                    Divider()
                    InfoRow(label: String(localized: "Publisher"), value: publisher)
                }
                Divider()
                InfoRow(label: String(localized: "Vector Dimension"), value: "\(fingerprint.dimension)")
                Divider()
                InfoRow(label: String(localized: "Pooling"), value: poolingDisplay(fingerprint.pooling))
                Divider()
                InfoRow(
                    label: String(localized: "Normalized"),
                    value: fingerprint.normalized ? String(localized: "Yes") : String(localized: "No")
                )
                if let quantization, !quantization.isEmpty {
                    Divider()
                    InfoRow(label: String(localized: "Quantization"), value: quantization)
                }
                Divider()
                InfoRow(
                    label: String(localized: "Chunk Token Limit"),
                    value: "\(fingerprint.chunkTokenLimit)"
                )
                Divider()
                InfoRow(label: String(localized: "Chunks"), value: "\(metadata.chunkCount)")
                Divider()
                InfoRow(label: String(localized: "Indexed"), value: formatDate(metadata.createdAt))
        }
    }

    private func poolingDisplay(_ raw: String) -> String {
        switch EmbeddingPooling(rawValue: raw) {
        case .mean: return String(localized: "Mean")
        case .cls: return String(localized: "CLS")
        case .lastToken: return String(localized: "Last Token")
        case .modelDefault: return String(localized: "Model Default")
        case .none: return raw
        }
    }

    @ViewBuilder
    private func processingView(status s: DatasetProcessingStatus) -> some View {
        let presentation = DatasetIndexingPresentation.make(for: s, locale: locale)
        preparationPanel(
            PreparationCardState(
                title: presentation.title,
                message: presentation.message,
                progress: s.progress,
                progressText: presentation.progressText,
                systemImage: presentation.systemImage,
                tone: preparationTone(for: presentation.tone),
                showsProgressBar: presentation.showsProgressBar
            )
        ) {
            switch presentation.actionState {
            case .none:
                Color.clear.frame(height: 0)
            case .cancelOnly:
                VStack(alignment: .leading, spacing: 8) {
                    Button(LocalizedStringKey("Stop"), role: .destructive) {
                        datasetManager.cancelProcessingForID(dataset.datasetID)
                    }
                    .buttonStyle(.industrial(.destructive))

                    if s.stage == .embedding {
                        Text(LocalizedStringKey("Keep Noema open while embedding — locking the screen pauses progress."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if s.stage == .extracting || s.stage == .compressing {
                        Text(LocalizedStringKey("You can leave Noema during this step — embedding hasn't started yet."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .startAndCancel:
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        if isPluggedIn() {
                            Task {
                                datasetManager.startEmbeddingForID(dataset.datasetID)
                            }
                        } else {
                            showConfirmOnBatteryConfirm = true
                        }
                    } label: {
                        Text(LocalizedStringKey("Confirm and Start Embedding"))
                            .compactStatusText(minimumScaleFactor: 0.75)
                    }
                    .buttonStyle(.industrial(.prominent))
                    .confirmationDialog(Text(LocalizedStringKey("Proceed on battery power?")), isPresented: $showConfirmOnBatteryConfirm, titleVisibility: .visible) {
                        Button(LocalizedStringKey("Proceed")) {
                            Task {
                                datasetManager.startEmbeddingForID(dataset.datasetID)
                            }
                        }
                        Button(LocalizedStringKey("Cancel"), role: .cancel) {}
                    } message: {
                        Text(LocalizedStringKey("Embedding is resource intensive. For best performance, plug in your device. Do you want to proceed on battery?"))
                    }
                    Text(LocalizedStringKey("For best performance, please plug in your device until this completes."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(LocalizedStringKey("Keep Noema open while embedding — locking the screen pauses progress."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    
    @ViewBuilder
    private func readyView() -> some View {
        let displayedDataset = liveDataset
        let cardState = readyPreparationState(for: displayedDataset)
        let reservesFooterSpace = warmingUpEmbed || cardState.tone == .warning || !isDatasetReady

        VStack(alignment: .leading, spacing: 12) {
            preparationPanel(cardState, reservesFooterSpace: reservesFooterSpace) {
                readyFooter(for: displayedDataset, cardState: cardState)
            }

            if let report = indexReport,
               report.failureReason != nil || !report.skippedFiles.isEmpty || !report.emptyFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if let failureReason = report.failureReason, !failureReason.isEmpty {
                        Text(failureReason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !report.skippedFiles.isEmpty {
                        Text(String.localizedStringWithFormat(
                            String(localized: "%d file(s) were skipped during indexing.", locale: locale),
                            report.skippedFiles.count
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    if !report.emptyFiles.isEmpty {
                        Text(String.localizedStringWithFormat(
                            String(localized: "%d file(s) were empty after extraction.", locale: locale),
                            report.emptyFiles.count
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if !warmingUpEmbed {
                Text(LocalizedStringKey("RAG embeds normalized paragraphs from your PDFs and EPUBs. On each question, the most relevant chunks are retrieved and added to the prompt. Images are ignored."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func preparationPanel<Footer: View>(
        _ state: PreparationCardState,
        reservesFooterSpace: Bool = true,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: state.systemImage)
                    .foregroundStyle(preparationTint(for: state.tone))
                    .applySymbolPulse(isDownloading: state.tone == .active && embedStatusPhase == .downloading)
                    .frame(width: 18, height: 18)

                Text(state.title)
                    .font(.headline)
                    .foregroundStyle(preparationTitleColor(for: state.tone))
                    .compactStatusText(minimumScaleFactor: 0.76)

                Spacer(minLength: 8)

                if !state.progressText.isEmpty {
                    ZStack(alignment: .trailing) {
                        Text("100% · ~88m 88s")
                            .font(.caption2)
                            .monospacedDigit()
                            .hidden()
                        Text(state.progressText)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .compactStatusText(minimumScaleFactor: 0.74)
                    }
                }
            }

            if state.showsProgressBar, let progress = state.progress {
                NotificationProgressBar(value: progress, height: preparationBarHeight)
            } else {
                Capsule()
                    .fill(preparationTrackColor(for: state.tone))
                    .frame(height: preparationBarHeight)
            }

            if !state.message.isEmpty {
                Text(state.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .compactStatusText(minimumScaleFactor: 0.8)
            }

            VStack(alignment: .leading, spacing: 8) {
                footer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: reservesFooterSpace ? 34 : 0, alignment: .topLeading)
        }
    }

    private func readyPreparationState(for displayedDataset: LocalDataset) -> PreparationCardState {
        if warmingUpEmbed {
            let title: String
            let systemImage: String
            switch embedStatusPhase {
            case .downloading:
                title = String(localized: "Preparing Embedding Model")
                systemImage = "arrow.down.circle.fill"
            case .failed:
                title = String(localized: "Failed", locale: locale)
                systemImage = "exclamationmark.triangle.fill"
            case .loading, .indexing, .checking, .idle:
                title = String(localized: "Preparing Embedding Model")
                systemImage = "cpu"
            }

            return PreparationCardState(
                title: title,
                message: embedStatusMessage.isEmpty ? String(localized: "Checking embedding model…", locale: locale) : embedStatusMessage,
                progress: embedProgress,
                progressText: DatasetIndexingPresentation.progressText(
                    for: DatasetProcessingStatus(stage: .embedding, progress: embedProgress, etaSeconds: nil),
                    locale: locale
                ),
                systemImage: systemImage,
                tone: embedStatusPhase == .failed ? .failure : .active,
                showsProgressBar: true
            )
        }

        if embedReady && modelManager.activeDataset?.datasetID == displayedDataset.datasetID {
            return PreparationCardState(
                title: String(localized: "Ready for Use", locale: locale),
                message: "",
                progress: nil,
                progressText: "",
                systemImage: "checkmark.circle.fill",
                tone: .success,
                showsProgressBar: false
            )
        }

        if displayedDataset.requiresReindex {
            return PreparationCardState(
                title: String(localized: "Rebuild Required", locale: locale),
                message: String(localized: "This dataset has an older or incomplete index. Rebuild it before using retrieval.", locale: locale),
                progress: nil,
                progressText: String(localized: "Error", locale: locale),
                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                tone: .warning,
                showsProgressBar: false
            )
        }

        if isDatasetReady {
            return PreparationCardState(
                title: String(localized: "Ready for Use", locale: locale),
                message: "",
                progress: nil,
                progressText: "",
                systemImage: "checkmark.circle.fill",
                tone: .success,
                showsProgressBar: false
            )
        }

        return PreparationCardState(
            title: String(localized: "Preparation", locale: locale),
            message: String(localized: "Ready to compute embeddings. Tap Confirm to start. For best performance, plug in your device.", locale: locale),
            progress: 0.0,
            progressText: DatasetIndexingPresentation.progressText(
                for: DatasetProcessingStatus(stage: .embedding, progress: 0.0, etaSeconds: nil),
                locale: locale
            ),
            systemImage: "sparkles",
            tone: .active,
            showsProgressBar: true
        )
    }

    @ViewBuilder
    private func readyFooter(for displayedDataset: LocalDataset, cardState: PreparationCardState) -> some View {
        if warmingUpEmbed {
            if embedStatusPhase == .downloading {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text(LocalizedStringKey("First-time download from HuggingFace"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Color.clear.frame(height: 0)
            }
        } else if cardState.tone == .warning || !isDatasetReady {
            Button(displayedDataset.requiresReindex ? LocalizedStringKey("Rebuild Dataset Index") : LocalizedStringKey("Start Embedding Process")) {
                if isPluggedIn() {
                    Task {
                        datasetManager.startEmbeddingForID(displayedDataset.datasetID)
                    }
                } else {
                    showStartOnBatteryConfirm = true
                }
            }
            .buttonStyle(.industrial(.prominent))
            .confirmationDialog(Text(LocalizedStringKey("Proceed on battery power?")), isPresented: $showStartOnBatteryConfirm, titleVisibility: .visible) {
                Button(LocalizedStringKey("Proceed")) {
                    Task {
                        datasetManager.startEmbeddingForID(displayedDataset.datasetID)
                    }
                }
                Button(LocalizedStringKey("Cancel"), role: .cancel) {}
            } message: {
                Text(LocalizedStringKey("Embedding is resource intensive. For best performance, plug in your device. Do you want to proceed on battery?"))
            }
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private func preparationTone(for tone: DatasetIndexingPresentation.Tone) -> PreparationCardTone {
        switch tone {
        case .active:
            return .active
        case .success:
            return .success
        case .failure:
            return .failure
        }
    }

    private func preparationTint(for tone: PreparationCardTone) -> Color {
        switch tone {
        case .active:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .failure:
            return .orange
        }
    }

    private func preparationTitleColor(for tone: PreparationCardTone) -> Color {
        switch tone {
        case .active:
            return .primary
        case .success:
            return .green
        case .warning:
            return .orange
        case .failure:
            return .orange
        }
    }

    /// Matches NotificationProgressBar's platform height so the terminal-state
    /// track doesn't jump thickness against the Mac industrial 2pt bar.
    private var preparationBarHeight: CGFloat {
#if os(macOS)
        2
#else
        7
#endif
    }

    private func preparationTrackColor(for tone: PreparationCardTone) -> Color {
        switch tone {
        case .success:
            return .green.opacity(0.22)
        case .warning:
            return .orange.opacity(0.22)
        case .failure:
            return .orange.opacity(0.22)
        case .active:
            return Color.primary.opacity(0.08)
        }
    }

    @MainActor
    private func prepareEmbeddingsAndIndex() async {
        let liveDataset = datasetManager.datasets.first(where: { $0.datasetID == dataset.datasetID }) ?? dataset
        let status = datasetManager.processingStatus[dataset.datasetID]
        let hasValidIndex = DatasetIndexIO.hasValidIndex(at: liveDataset.url)
        let alreadyReady = !liveDataset.requiresReindex && (liveDataset.isIndexed || status?.stage == .completed || hasValidIndex)
        if alreadyReady {
            embedStatusMessage = ""
            embedStatusPhase = .idle
            embedProgress = 1.0
            embedReady = true
            warmingUpEmbed = false
            return
        }

        embedStatusPhase = .checking
        embedStatusMessage = String(localized: "Checking embedding model…")
        embedProgress = 0.05
        // Ensure dirs only (no network)
        await EmbeddingModel.shared.ensureModel()
        if !(await EmbeddingModel.shared.isModelAvailable()) {
            embedStatusPhase = .downloading
            embedStatusMessage = String(localized: "Downloading embedding model…")
            embedProgress = 0.1
            
            // Start a task to monitor download progress
            let progressTask = Task { @MainActor in
                while embedInstaller.state == .downloading || embedInstaller.state == .verifying || embedInstaller.state == .installing {
                    embedProgress = embedInstaller.progress * 0.6 + 0.1 // Scale to 10%-70% range
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                }
            }
            
            await embedInstaller.installIfNeeded()
            progressTask.cancel()
            
            switch embedInstaller.state {
            case .failed(let msg):
                embedStatusPhase = .failed
                embedStatusMessage = String(format: String(localized: "Failed: %@"), msg)
                warmingUpEmbed = false
                return
            case .ready:
                embedProgress = 0.7
                break
            default:
                break
            }
        }
        embedStatusPhase = .loading
        embedStatusMessage = String(localized: "Loading model…")
        embedProgress = 0.7
        await EmbeddingModel.shared.warmUp()
        let ready = await EmbeddingModel.shared.isReady()
        if ready {
            embedStatusPhase = .indexing
            embedStatusMessage = String(localized: "Indexing dataset…")
            embedProgress = 0.85
            datasetManager.ensureIndexedForID(dataset.datasetID)
            embedReady = true
            embedProgress = 1.0
        } else {
            embedStatusPhase = .failed
            embedStatusMessage = String(localized: "Failed to initialize")
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            warmingUpEmbed = false
            embedStatusMessage = ""
            embedStatusPhase = .idle
        }
    }

    private func loadFiles() {
        let dataset = liveDataset
        let fm = FileManager.default
        var items: [(name: String, size: String)] = []
        if let enumerator = fm.enumerator(at: dataset.url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            while let url = enumerator.nextObject() as? URL {
                let relative = DatasetPathing.relativePath(for: url, under: dataset.url)
                if DatasetStorage.isInternalRelativePath(relative) { continue }
                if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   values.isRegularFile == true {
                    let sizeStr = localizedFileSizeString(bytes: Int64(values.fileSize ?? 0), locale: locale)
                    items.append((name: relative, size: sizeStr))
                }
            }
        }
        files = items.sorted(by: { $0.name < $1.name })
    }

    private func loadIndexReport() {
        indexReport = DatasetIndexIO.loadReport(from: liveDataset.url)
    }

    private func loadIndexMetadata() {
        indexMetadata = DatasetIndexIO.loadMetadata(from: liveDataset.url)
    }

    private func estimateTokens() async {
        await MainActor.run { isEstimatingTokens = true }
        let tokens = await DatasetRetriever.shared.estimateTokens(in: liveDataset)
        if tokens > 0 {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            tokenEstimate = formatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
        }
        await MainActor.run { isEstimatingTokens = false }
    }

    private func computeCompressedSize() async {
        let dir = liveDataset.url
        let compact = DatasetIndexIO.compactURL(for: dir)
        let extracted = DatasetIndexIO.extractedURL(for: dir)
        let urlToUse: URL? = FileManager.default.fileExists(atPath: compact.path) ? compact : (FileManager.default.fileExists(atPath: extracted.path) ? extracted : nil)
        if let u = urlToUse,
           let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
           let bytes = attrs[.size] as? NSNumber {
            let formatted = localizedFileSizeString(bytes: bytes.int64Value, locale: locale)
            await MainActor.run {
                compressedMB = String.localizedStringWithFormat(String(localized: "Approx. %@", locale: locale), formatted)
            }
        }
    }
}

// MARK: - Symbol effect compatibility helpers (iOS 17+ / macOS 14+ / visionOS 1+)
private extension View {
    @ViewBuilder
    func applySymbolPulse(isDownloading: Bool) -> some View {
        // Gate usage to platforms/versions that support `symbolEffect`.
        if #available(iOS 17.0, macOS 14.0, visionOS 1.0, *) {
            self.symbolEffect(isDownloading ? .pulse.byLayer : .pulse)
        } else {
            self
        }
    }
}

private enum EmbedStatusPhase {
    case idle
    case checking
    case downloading
    case loading
    case indexing
    case failed
}

private enum PreparationCardTone {
    case active
    case success
    case warning
    case failure
}

private struct PreparationCardState {
    let title: String
    let message: String
    let progress: Double?
    let progressText: String
    let systemImage: String
    let tone: PreparationCardTone
    let showsProgressBar: Bool
}

private func stageLabel(_ s: DatasetProcessingStage) -> String {
    switch s {
    case .extracting: return "Extracting".localized
    case .compressing: return "Compressing".localized
    case .embedding: return "Embedding".localized
    case .completed: return "Ready".localized
    case .failed: return "Failed".localized
    }
}

private extension LocalDatasetDetailView {
    var liveDataset: LocalDataset {
        datasetManager.datasets.first(where: { $0.datasetID == dataset.datasetID }) ?? dataset
    }

    var isDatasetReady: Bool {
        let dataset = liveDataset
        if dataset.requiresReindex {
            return false
        }
        return dataset.isIndexed
            || DatasetIndexIO.hasValidIndex(at: dataset.url)
            || datasetManager.processingStatus[dataset.datasetID]?.stage == .completed
    }

    var disabledUseDatasetReason: String {
        if liveDataset.requiresReindex {
            return "This dataset needs to be rebuilt before it can be used. Start the rebuild above first.".localized
        }
        if datasetManager.indexingDatasetID == dataset.datasetID {
            return "Dataset is currently indexing. You can use it when indexing completes.".localized
        }
        return "This dataset isn’t ready yet. Start the embedding process above first.".localized
    }

    var cardBackgroundColor: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }

    var windowBackgroundColor: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }

    var closeButtonBackgroundColor: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .secondarySystemBackground)
        #endif
    }

    func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

@MainActor
private func isPluggedIn() -> Bool {
#if canImport(UIKit)
    UIDevice.current.isBatteryMonitoringEnabled = true
    let state = UIDevice.current.batteryState
    return state == .charging || state == .full
#else
    return true
#endif
}
