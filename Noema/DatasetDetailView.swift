import SwiftUI

#if os(macOS)
private let datasetFileRowVerticalPadding: CGFloat = 6
#else
private let datasetFileRowVerticalPadding: CGFloat = 12
#endif

struct DatasetDetailView: View, Identifiable {
    let id = UUID()
    let detail: DatasetDetails
    @EnvironmentObject var downloadController: DownloadController
    @ObservedObject private var presentationUpdates = DownloadPresentationUpdates.shared
    @Environment(\.dismiss) private var dismiss
#if os(macOS)
    @Environment(\.macModalDismiss) private var macModalDismiss
#endif
    @Environment(\.locale) private var locale
    @StateObject private var readmeLoader: DatasetReadmeLoader
    @AppStorage("huggingFaceToken") private var huggingFaceToken = ""
    @State private var showRecommendation = false
    @State private var medicalAcknowledged = false

    private var isOTL: Bool { detail.id.hasPrefix("OTL/") }
    private var pack: KnowledgePack? { KnowledgePackCatalog.pack(forID: detail.id) }
    private var isPack: Bool { pack != nil }
    /// Curated sources (OTL textbooks, Knowledge Packs) carry their own
    /// description, so they must NOT fetch a Hugging Face README — for a
    /// "PACK/…" or "OTL/…" id that request 404s.
    private var isCurated: Bool { isOTL || isPack }
    private var requiresMedicalAck: Bool { pack?.disclaimerKey == "medical" }
    private var embeddingModelInstalled: Bool { EmbeddingModelCatalog.activeRecord().isInstalled }
    private var hasSourceInfo: Bool {
        detail.license != nil || detail.attribution != nil || detail.snapshotDate != nil
    }
    private var activeItem: DownloadController.DatasetItem? {
        downloadController.datasetItems.first { $0.detail.id == detail.id }
    }
    
    private var totalSupportedSize: Int64 {
        DatasetFileSupport.totalSupportedSize(files: detail.files)
    }

    init(detail: DatasetDetails) {
        self.detail = detail
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken") ?? ""
        _readmeLoader = StateObject(wrappedValue: DatasetReadmeLoader(repo: detail.id, token: token))
    }

    private func close() {
#if os(macOS)
        macModalDismiss()
#else
        dismiss()
#endif
    }

    private func statusKey(for item: DownloadController.DatasetItem) -> LocalizedStringKey? {
        guard !item.completed else { return nil }
        switch item.status {
        case .paused:
            return "Paused"
        case .retrying, .waitingForConnectivity:
            return "Retrying…"
        case .verifying, .finalizing:
            return "Finishing…"
        default:
            return nil
        }
    }

    var body: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.displayName ?? detail.id)
                        .font(.system(size: 20, weight: .semibold))
                    if let summary = detail.summary {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                }

                if hasSourceInfo {
                    VStack(alignment: .leading, spacing: 12) {
                        IndustrialSectionHeader("Source & License")
                        sourceLicenseContent
                    }
                }

                if !isCurated {
                    VStack(alignment: .leading, spacing: 12) {
                        IndustrialSectionHeader("About")

                        ReadmeCollapseView(markdown: readmeLoader.markdown,
                                          loading: readmeLoader.isLoading,
                                          retry: { readmeLoader.load(force: true) })
                            .frame(minHeight: 100)
                    }
                    .onAppear { readmeLoader.load() }
                    .onDisappear {
                        readmeLoader.clearMarkdown()
                        readmeLoader.cancel()
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    IndustrialSectionHeader("Files", detail: "\(detail.files.count)")
                    filesContent
                }

                VStack(alignment: .leading, spacing: 12) {
                    IndustrialHairline()
                    actionsContent
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showRecommendation) {
            DatasetRecommendationView(
                datasetName: detail.displayName ?? detail.id,
                totalSizeBytes: totalSupportedSize
            )
        }
        #else
        NavigationStack {
            List {
                Section(header: Text(detail.displayName ?? detail.id)) {
                    if isCurated {
                        if let summary = detail.summary { Text(summary) }
                    } else {
                        ReadmeCollapseView(markdown: readmeLoader.markdown,
                                          loading: readmeLoader.isLoading,
                                          retry: { readmeLoader.load(force: true) })
                            .onAppear { readmeLoader.load() }
                            .onDisappear {
                                readmeLoader.clearMarkdown()
                                readmeLoader.cancel()
                            }
                    }
                }
                if hasSourceInfo {
                    Section(LocalizedStringKey("Source & License")) {
                        sourceLicenseContent
                    }
                }
                Section(LocalizedStringKey("Files")) {
                    filesContent
                }
                Section {
                    actionsContent
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let item = activeItem {
                        Button(LocalizedStringKey("Done")) { close() }
                            .disabled(!item.completed && !isCurated)
                    } else {
                        Button(LocalizedStringKey("Close")) { close() }
                    }
                }
            }
            .sheet(isPresented: $showRecommendation) {
                DatasetRecommendationView(
                    datasetName: detail.displayName ?? detail.id,
                    totalSizeBytes: totalSupportedSize
                )
            }
        }
        #endif
    }

    @ViewBuilder
    private var sourceLicenseContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let license = detail.license {
                Label(LocalizedStringKey(license), systemImage: "checkmark.seal")
                    .font(.callout)
            }
            if let snapshot = detail.snapshotDate {
                Label(snapshot, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let attribution = detail.attribution {
                Text(attribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var filesContent: some View {
        let hasUsable = detail.files.contains { DatasetFileSupport.isSupported($0) }
        let hasOnlyUnsupported = !detail.files.isEmpty && !hasUsable

        if detail.files.isEmpty {
            Text(LocalizedStringKey("No files listed for this dataset."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(detail.files.enumerated()), id: \.element.id) { index, f in
                    if index > 0 { Divider() }
                    HStack(spacing: 12) {
                        Image(systemName: "doc.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(f.name)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(localizedDatasetFileSizeString(bytes: f.sizeBytes, locale: locale))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, datasetFileRowVerticalPadding)
                }
            }
            
            if hasOnlyUnsupported {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().padding(.vertical, 4)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("This dataset's files are not currently supported for document retrieval."))
                                .font(.callout)
                                .fontWeight(.medium)
                            
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "Supported formats: %@", locale: locale),
                                    "PDF, EPUB, TXT, MD, JSON, JSONL, CSV, TSV"
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if isOTL && !hasUsable {
                Divider().padding(.vertical, 4)
                Text(LocalizedStringKey("This textbook appears to be available only as a web page. Noema can't import it as a dataset."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionsContent: some View {
        let hasUsable = detail.files.contains { DatasetFileSupport.isSupported($0) }
        
        if let item = activeItem, item.status == .failed {
            // P1-E: a failed download (e.g. a 404 on an unpublished pack file) must
            // not leave a frozen "Downloading…" — show the error and offer Retry.
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(LocalizedStringKey("Download failed"))
                        .font(.callout)
                        .fontWeight(.medium)
                }
                if let message = item.error?.localizedDescription, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    downloadController.startDataset(detail: detail)
                } label: {
                    Label(LocalizedStringKey("Retry"), systemImage: "arrow.clockwise")
                        .industrialCTAWidth()
                }
                .buttonStyle(.industrial(.tinted))
                .controlSize(.large)
            }
        } else if let item = activeItem {
            VStack(alignment: .leading, spacing: 12) {
                let progress = item.expectedBytes > 0
                    ? Double(item.downloadedBytes) / Double(item.expectedBytes)
                    : item.progress
                DownloadProgressCluster(
                    progress: progress,
                    speed: item.speed,
                    statusKey: statusKey(for: item)
                )
                if item.completed {
                    Button(LocalizedStringKey("Done")) { close() }
                        .buttonStyle(.industrial(.prominent))
                        .controlSize(.large)
                }
            }
        } else {
            if isOTL && totalSupportedSize > 0 {
                Button {
                    showRecommendation = true
                } label: {
                    Label(LocalizedStringKey("Check Requirements"), systemImage: "info.circle.fill")
                        .industrialCTAWidth()
                }
                .buttonStyle(.industrial(.quiet))
                .controlSize(.large)
                .padding(.bottom, 8)
            }

            // P1-B: medical packs require explicit acknowledgement before download.
            if requiresMedicalAck {
                VStack(alignment: .leading, spacing: 8) {
                    Label(LocalizedStringKey("This pack is reference information only and is not a substitute for professional medical care."), systemImage: "cross.case")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(LocalizedStringKey("I understand this is not medical advice"), isOn: $medicalAcknowledged)
                        .font(.callout)
                }
                .padding(.bottom, 8)
            }

            // P1-F: be honest that indexing may download an embedding model first.
            if hasUsable && !embeddingModelInstalled {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                    Text(LocalizedStringKey("Setup will first download an on-device embedding model."))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            }

            let downloadDisabled = !hasUsable || (requiresMedicalAck && !medicalAcknowledged)
            Button {
                downloadController.startDataset(detail: detail)
            } label: {
                Text(LocalizedStringKey("Download Dataset"))
                    .industrialCTAWidth()
            }
            .buttonStyle(.industrial(.prominent))
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(downloadDisabled)
            .opacity(downloadDisabled ? 0.5 : 1)

            if !hasUsable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "No compatible files found. Supported: %@", locale: locale),
                            "PDF, EPUB, TXT, MD, JSON, JSONL, CSV, TSV"
                        )
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }
        }
    }
}
