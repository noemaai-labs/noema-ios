import SwiftUI

struct EmbeddingModelsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloadController: DownloadController
    @ObservedObject private var presentationUpdates = DownloadPresentationUpdates.shared
    @EnvironmentObject private var datasetManager: DatasetManager
    @State private var pendingSelection: EmbeddingModelRecord?
    @State private var showSelectionConfirmation = false
    @State private var pendingDeletion: EmbeddingModelRecord?
    @State private var showDeleteConfirmation = false
    @State private var pendingLicenseDownload: EmbeddingModelRecord?
    @State private var showLicenseDownloadConfirmation = false
    @State private var deleteErrorMessage = ""
    @State private var showDeleteError = false
    @State private var refreshToken = UUID()
    @State private var searchText = ""
    // Installed-state is `FileManager.fileExists` (synchronous main-thread disk I/O).
    // Calling it per row on every body eval pegged the main thread at the controller's
    // 5 Hz download cadence — on a disk already busy writing the download, those stat()
    // calls block and the app/VoiceOver freezes and overheats. Snapshot once at init and
    // refresh only when availability actually changes (download completes / model deleted).
    @State private var installedRecordIDs: Set<String> = Set(
        EmbeddingModelCatalog.records.filter(\.isInstalled).map(\.id)
    )
#if os(macOS)
    @State private var selectedDetailRecord: EmbeddingModelRecord?
    @State private var macContentAppeared = false
#endif

    private var activeRecord: EmbeddingModelRecord {
        _ = refreshToken
        return EmbeddingModelCatalog.activeRecord()
    }

    private var activeRecordIsInstalled: Bool {
        installedRecordIDs.contains(activeRecord.id)
    }

    private var filteredRecords: [EmbeddingModelRecord] {
        EmbeddingModelCatalog.filteredRecords(matching: searchText)
    }

    private var installedRecords: [EmbeddingModelRecord] {
        filteredRecords.filter { installedRecordIDs.contains($0.id) }
    }

    private var availableRecords: [EmbeddingModelRecord] {
        filteredRecords.filter { $0.isInstallable && !installedRecordIDs.contains($0.id) }
    }

    private var unavailableRecords: [EmbeddingModelRecord] {
        filteredRecords.filter { !$0.isInstallable }
    }

    /// Re-snapshots installed-state from disk. Called only when availability changes
    /// (download completes / model deleted), never per render.
    private func refreshInstalledRecordIDs() {
        installedRecordIDs = Set(EmbeddingModelCatalog.records.filter(\.isInstalled).map(\.id))
    }

    private var hasVisibleRows: Bool {
        !installedRecords.isEmpty || !availableRecords.isEmpty || !unavailableRecords.isEmpty
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
#if os(macOS)
                macCatalogHeader
                macSearchField
#endif

#if os(macOS)
                // Mount the card list one tick after the push so the submenu
                // animation stays clean, then fade it in.
                if macContentAppeared {
                    Group {
                        if !activeRecordIsInstalled {
                            activeMissingBanner
                        }

                        if hasVisibleRows {
                            modelSection(title: "Downloaded", records: installedRecords)
                            if !installedRecords.isEmpty {
                                indexRebuildNotice
                            }
                            modelSection(title: "Available", records: availableRecords)
                            modelSection(title: "Unavailable", records: unavailableRecords)
                        } else if !trimmedSearchText.isEmpty {
                            emptySearchResults
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.99, anchor: .top)))
                }
#else
                if !activeRecordIsInstalled {
                    activeMissingBanner
                }

                if hasVisibleRows {
                    modelSection(title: "Downloaded", records: installedRecords)
                    if !installedRecords.isEmpty {
                        indexRebuildNotice
                    }
                    modelSection(title: "Available", records: availableRecords)
                    modelSection(title: "Unavailable", records: unavailableRecords)
                } else if !trimmedSearchText.isEmpty {
                    emptySearchResults
                }
#endif
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .background(AppTheme.windowBackground.ignoresSafeArea())
#if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        .task {
            guard !macContentAppeared else { return }
            await Task.yield()
            withAnimation(AppMotion.submenu) { macContentAppeared = true }
        }
        .sheet(item: $selectedDetailRecord) { record in
            EmbeddingModelDetailView(recordID: record.id)
                .environmentObject(downloadController)
                .environmentObject(datasetManager)
        }
#else
        .navigationTitle(LocalizedStringKey("Embedding Models"))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text(LocalizedStringKey("Search embedding models")))
#endif
        .onAppear { refreshInstalledRecordIDs() }
        .onReceive(NotificationCenter.default.publisher(for: .embeddingModelAvailabilityChanged)) { _ in
            refreshToken = UUID()
            refreshInstalledRecordIDs()
            datasetManager.reloadFromDisk()
        }
        .confirmationDialog(
            LocalizedStringKey("Change Embedding Model?"),
            isPresented: $showSelectionConfirmation,
            titleVisibility: .visible,
            presenting: pendingSelection
        ) { record in
            Button(LocalizedStringKey("Change and Rebuild Now")) {
                Task { await activate(record, rebuildNow: true) }
            }
            Button(LocalizedStringKey("Change Later")) {
                Task { await activate(record, rebuildNow: false) }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                pendingSelection = nil
            }
        } message: { record in
            Text(String.localizedStringWithFormat(
                String(localized: "Use %@ for future dataset search? Existing dataset indexes will need to be rebuilt. You can rebuild them now or later."),
                record.displayName
            ))
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { (record: EmbeddingModelRecord) in
            Button(LocalizedStringKey("Delete Model"), role: .destructive) {
                Task { await delete(record) }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: { record in
            Text(deleteDialogMessage(for: record))
        }
        .confirmationDialog(
            LocalizedStringKey("Review License Before Downloading"),
            isPresented: $showLicenseDownloadConfirmation,
            titleVisibility: .visible,
            presenting: pendingLicenseDownload
        ) { record in
            Button(LocalizedStringKey("Download Anyway")) {
                downloadController.startEmbedding(recordID: record.id)
                pendingLicenseDownload = nil
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                pendingLicenseDownload = nil
            }
        } message: { record in
            Text(licenseDownloadConfirmationMessage(for: record))
        }
        .alert(LocalizedStringKey("Failed to Delete Embedding Model"), isPresented: $showDeleteError) {
            Button(LocalizedStringKey("OK"), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
    }

#if os(macOS)
    @ViewBuilder
    private var macCatalogHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Embedding Models"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.text)
                Text(LocalizedStringKey("Dataset search quality and indexing"))
                    .industrialStat()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            IndustrialIconButton(systemImage: "xmark", help: LocalizedStringKey("Close")) {
                dismiss()
            }
            .accessibilityLabel(LocalizedStringKey("Close"))
        }
    }

    @ViewBuilder
    private var macSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: catalogSearchIconSize, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 18)

            TextField(LocalizedStringKey("Search embedding models"), text: $searchText)
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Clear"))
            }
        }
        .padding(.horizontal, catalogSearchFieldHorizontalPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: catalogSearchFieldCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: catalogSearchFieldCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(catalogCardStrokeOpacity), lineWidth: 1)
        )
    }
#endif

    // MARK: - Sections

    @ViewBuilder
    private var activeMissingBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Active embedding model is missing"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.text)
                Text(String.localizedStringWithFormat(
                    String(localized: "%@ is selected as active but its files are not installed. Download it again or pick a different model."),
                    activeRecord.displayName
                ))
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: catalogCardCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var emptySearchResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(AppTheme.secondaryText)
            Text(String.localizedStringWithFormat(
                String(localized: "No embedding models found for '%@'"),
                trimmedSearchText
            ))
            .font(FontTheme.body)
            .foregroundStyle(AppTheme.text)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    @ViewBuilder
    private var indexRebuildNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 24)

            Text(LocalizedStringKey("Changing the active embedding model marks existing dataset indexes for rebuild. Existing vectors stay on disk until you rebuild or delete the dataset."))
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: catalogCardCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func modelSection(title: String, records: [EmbeddingModelRecord]) -> some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
#if os(macOS)
                IndustrialSectionHeader(LocalizedStringKey(title), detail: "\(records.count)")
#else
                Text(LocalizedStringKey(title))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 4)
#endif

                ForEach(records) { record in
                    modelCard(for: record)
                }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func modelCard(for record: EmbeddingModelRecord) -> some View {
        let installed = installedRecordIDs.contains(record.id)
        let isActive = record.id == activeRecord.id
        let item = downloadController.embeddingItems.first { $0.id == record.id }
        let state = rowState(record: record, installed: installed, isActive: isActive, item: item)

        Group {
#if os(macOS)
            Button {
                selectedDetailRecord = record
            } label: {
                modelCardContent(record: record, item: item, state: state)
            }
#else
            NavigationLink {
                EmbeddingModelDetailView(recordID: record.id)
            } label: {
                modelCardContent(record: record, item: item, state: state)
            }
#endif
        }
        .buttonStyle(.plain)
        // Express selection on exactly the active+installed model. Not-downloaded
        // models can never be active, so they never read as "Selected."
        .accessibilityAddTraits(installed && isActive ? .isSelected : [])
        .contextMenu {
            contextActions(record: record, installed: installed, isActive: isActive, item: item)
        }
    }

    @ViewBuilder
    private func modelCardContent(
        record: EmbeddingModelRecord,
        item: DownloadController.EmbeddingItem?,
        state: RowState
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 14) {
                    statusIcon(for: state)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.displayName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppTheme.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        statusBadges(record: record, state: state)
                    }
                }

                Text(LocalizedStringKey(record.summary))
                    .font(.system(size: 15))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 42)

                chipRow(items: summaryChips(for: record))
                    .padding(.leading, 42)

                if let item, item.status != .completed {
                    EmbeddingDownloadProgressRow(item: item)
                        .padding(.leading, 42)
                }

                if let reason = record.gatingReason {
                    Label(LocalizedStringKey(reason), systemImage: "lock")
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .padding(.leading, 42)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

#if os(macOS)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.3))
                .padding(.top, 8)
#else
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.22))
                .padding(.top, 32)
#endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: catalogCardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: catalogCardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(catalogCardStrokeOpacity), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(catalogCardShadowOpacity), radius: 12, x: 0, y: 5)
    }

    @ViewBuilder
    private func statusBadges(record: EmbeddingModelRecord, state: RowState) -> some View {
        HStack(spacing: 6) {
            if record.isRecommended {
                badge(String(localized: "Recommended"), color: .green)
            }
            stateBadge(state)
            deviceFitBadge(for: record)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func deviceFitBadge(for record: EmbeddingModelRecord) -> some View {
        if let artifact = record.primaryArtifact, artifact.sizeBytes > 0 {
            ModelRAMAdvisor.badge(
                format: .gguf,
                sizeBytes: artifact.sizeBytes,
                contextLength: max(512, record.runtimeContextTokens),
                layerCount: nil
            )
        }
    }

    @ViewBuilder
    private func statusIcon(for state: RowState) -> some View {
        ZStack {
            switch state {
            case .active:
                Circle()
                    .fill(.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            case .installed:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: catalogStatusIconSize, weight: .medium))
                    .foregroundStyle(.blue)
            case .downloading:
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: catalogStatusIconSize, weight: .medium))
                    .foregroundStyle(.blue)
            case .paused:
                Image(systemName: "pause.circle")
                    .font(.system(size: catalogStatusIconSize, weight: .medium))
                    .foregroundStyle(.orange)
            case .notDownloaded:
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: catalogStatusIconSize, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            case .gated:
                Image(systemName: "lock.circle")
                    .font(.system(size: catalogStatusIconSize, weight: .medium))
                    .foregroundStyle(.orange)
            case .unsupported:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: catalogStatusIconSize, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: catalogStatusIconFrame, height: catalogStatusIconFrame)
    }

    private var cardBackground: Color {
#if os(macOS)
        Color.primary.opacity(0.035)
#else
        Color(uiColor: .secondarySystemGroupedBackground)
#endif
    }

    private func summaryChips(for record: EmbeddingModelRecord) -> [String] {
        var items: [String] = [
            String.localizedStringWithFormat(String(localized: "%d dim"), record.dimension)
        ]
        if let artifact = record.primaryArtifact, artifact.sizeBytes > 0 {
            items.append(formatBytes(artifact.sizeBytes))
        }
        items.append(record.licenseLabel)
        if let quant = record.primaryArtifact?.quantization, !quant.isEmpty {
            items.append(quant)
        }
        return items
    }

    @ViewBuilder
    private func chipRow(items: [String]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    detailChip(label: item)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(Array(items.prefix(2).enumerated()), id: \.offset) { _, item in
                        detailChip(label: item)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(Array(items.dropFirst(2).enumerated()), id: \.offset) { _, item in
                        detailChip(label: item)
                    }
                }
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func contextActions(
        record: EmbeddingModelRecord,
        installed: Bool,
        isActive: Bool,
        item: DownloadController.EmbeddingItem?
    ) -> some View {
        if installed {
            if !isActive {
                Button {
                    pendingSelection = record
                    showSelectionConfirmation = true
                } label: {
                    Label(LocalizedStringKey("Use Model"), systemImage: "checkmark.circle")
                }
            }
            Button(role: .destructive) {
                pendingDeletion = record
                showDeleteConfirmation = true
            } label: {
                Label(LocalizedStringKey("Delete"), systemImage: "trash")
            }
        } else if let item, item.canResume {
            Button {
                downloadController.resume(itemID: item.id)
            } label: {
                Label(LocalizedStringKey("Resume"), systemImage: "play.fill")
            }
            Button {
                downloadController.cancel(itemID: record.id)
            } label: {
                Label(LocalizedStringKey("Cancel"), systemImage: "xmark.circle")
            }
        } else if item != nil {
            Button {
                downloadController.cancel(itemID: record.id)
            } label: {
                Label(LocalizedStringKey("Cancel Download"), systemImage: "xmark.circle")
            }
        } else if record.isInstallable {
            Button {
                requestDownload(record)
            } label: {
                Label(LocalizedStringKey("Download"), systemImage: "arrow.down.circle.fill")
            }
        }
    }

    private func requestDownload(_ record: EmbeddingModelRecord) {
        if record.licenseWarningLevel.requiresDownloadConfirmation {
            pendingLicenseDownload = record
            showLicenseDownloadConfirmation = true
        } else {
            downloadController.startEmbedding(recordID: record.id)
        }
    }

    // MARK: - Row state

    private enum RowState {
        case active
        case installed
        case downloading(progress: Double)
        case paused
        case notDownloaded
        case gated
        case unsupported

    }

    private func rowState(
        record: EmbeddingModelRecord,
        installed: Bool,
        isActive: Bool,
        item: DownloadController.EmbeddingItem?
    ) -> RowState {
        if installed && isActive { return .active }
        if installed { return .installed }
        if let item, item.canResume { return .paused }
        if item != nil { return .downloading(progress: item?.progress ?? 0) }
        switch record.catalogState {
        case .gated: return .gated
        case .unsupported: return .unsupported
        case .installable: return .notDownloaded
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: RowState) -> some View {
        switch state {
        case .active:
            badge(String(localized: "Active"), color: .green)
        case .installed:
            badge(String(localized: "Downloaded"), color: .blue)
        case .downloading(let progress):
            badge(
                String.localizedStringWithFormat(String(localized: "Downloading %d%%"), Int(progress * 100)),
                color: .blue
            )
        case .paused:
            badge(String(localized: "Paused"), color: .orange)
        case .notDownloaded:
            EmptyView()
        case .gated:
            badge(String(localized: "Gated"), color: .orange)
        case .unsupported:
            badge(String(localized: "Unsupported"), color: .orange)
        }
    }

    @ViewBuilder
    private func badge(_ text: String, color: Color) -> some View {
#if os(macOS)
        IndustrialBadge(verbatim: text, tint: color)
#else
        Text(text)
            .font(FontTheme.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
#endif
    }

    @ViewBuilder
    private func detailChip(label: String) -> some View {
#if os(macOS)
        Text(label)
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.primary.opacity(0.5))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
#else
        Text(label)
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
#endif
    }

    // MARK: - Actions

    private func activate(_ record: EmbeddingModelRecord, rebuildNow: Bool) async {
        do {
            try await EmbeddingModel.shared.setActiveModel(recordID: record.id)
            await MainActor.run {
                pendingSelection = nil
                refreshToken = UUID()
                datasetManager.reloadFromDisk()
            }
            if rebuildNow {
                await datasetManager.rebuildDatasetsNeedingReindex()
            }
            await MainActor.run {
                refreshToken = UUID()
                datasetManager.reloadFromDisk()
            }
        } catch {
            await logger.log("[EmbeddingModels] Failed to activate \(record.id): \(error.localizedDescription)")
        }
    }

    private func delete(_ record: EmbeddingModelRecord) async {
        let wasActive = record.id == EmbeddingModelCatalog.activeRecord().id
        await EmbeddingModel.shared.unload()
        do {
            let fm = FileManager.default
            let fileURL = record.installedURL
            if fm.fileExists(atPath: fileURL.path) {
                try fm.removeItem(at: fileURL)
            }
            let directory = EmbeddingModelCatalog.directoryURL(for: record.id)
            if fm.fileExists(atPath: directory.path) {
                try? fm.removeItem(at: directory)
            }
            UserDefaults.standard.removeObject(forKey: "hasInstalledEmbedModel:\(fileURL.path)")

            if wasActive {
                let fallback = fallbackActiveModelID(excluding: record.id)
                if let fallback {
                    EmbeddingModelCatalog.setActiveRecordID(fallback)
                } else {
                    UserDefaults.standard.removeObject(forKey: EmbeddingModelCatalog.activeModelIDKey)
                }
                await DatasetRetriever.shared.clearCache()
            }

            await MainActor.run {
                pendingDeletion = nil
                refreshToken = UUID()
                let nowActive = EmbeddingModelCatalog.activeRecord()
                NotificationCenter.default.post(
                    name: .embeddingModelAvailabilityChanged,
                    object: nil,
                    userInfo: ["available": nowActive.isInstalled, "recordID": record.id]
                )
                datasetManager.reloadFromDisk()
            }
        } catch {
            await MainActor.run {
                pendingDeletion = nil
                deleteErrorMessage = error.localizedDescription
                showDeleteError = true
            }
        }
    }

    /// Pick the best fallback for the active embedding model after a deletion.
    /// Prefers an installed model; falls back to the catalog default if it
    /// still exists in the records list.
    private func fallbackActiveModelID(excluding excludedID: String) -> String? {
        let installed = EmbeddingModelCatalog.records.first { $0.id != excludedID && $0.isInstalled }
        if let installed { return installed.id }
        if let def = EmbeddingModelCatalog.record(for: EmbeddingModelCatalog.defaultModelID),
           def.id != excludedID {
            return def.id
        }
        return nil
    }

    // MARK: - Dialog text

    private var deleteDialogTitle: Text {
        if let record = pendingDeletion {
            let title = String.localizedStringWithFormat(String(localized: "Delete %@?"), record.displayName)
            return Text(title)
        }
        return Text(LocalizedStringKey("Delete Embedding Model?"))
    }

    private func deleteDialogMessage(for record: EmbeddingModelRecord) -> String {
        let isActive = record.id == activeRecord.id
        let size = formatBytes(record.primaryArtifact?.sizeBytes ?? 0)
        if isActive {
            let fallback = fallbackActiveModelID(excluding: record.id)
            let fallbackName = fallback.flatMap { EmbeddingModelCatalog.record(for: $0)?.displayName }
            if let fallbackName {
                return String.localizedStringWithFormat(
                    String(localized: "This model is currently active. Deleting will remove %@ from this device and switch the active model to %@. Existing dataset indexes will need to be rebuilt."),
                    size,
                    fallbackName
                )
            }
            return String.localizedStringWithFormat(
                String(localized: "This model is currently active. Deleting will remove %@ from this device and leave no active embedding model — you will need to download one before using dataset search."),
                size
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "Delete this embedding model from this device? This removes %@."),
            size
        )
    }

    private func licenseDownloadConfirmationMessage(for record: EmbeddingModelRecord) -> String {
        switch record.licenseWarningLevel {
        case .restricted:
            return String.localizedStringWithFormat(
                String(localized: "The license label for %@ is %@. Confirm that your use is allowed before downloading."),
                record.displayName,
                record.licenseLabel
            )
        case .unknown:
            return String.localizedStringWithFormat(
                String(localized: "No clear license was found for %@. Confirm that your use is allowed before downloading."),
                record.displayName
            )
        case .review, .permissive:
            return String.localizedStringWithFormat(
                String(localized: "Review the %@ license for %@ before downloading."),
                record.licenseLabel,
                record.displayName
            )
        }
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes >= 1_000_000_000 ? [.useGB] : [.useMB]
        return formatter.string(fromByteCount: bytes)
    }
}

private struct EmbeddingModelDetailView: View {
    @EnvironmentObject private var downloadController: DownloadController
    @ObservedObject private var presentationUpdates = DownloadPresentationUpdates.shared
    @EnvironmentObject private var datasetManager: DatasetManager
    @Environment(\.dismiss) private var dismiss
    let recordID: String

    @State private var pendingSelection: EmbeddingModelRecord?
    @State private var showSelectionConfirmation = false
    @State private var pendingDeletion: EmbeddingModelRecord?
    @State private var showDeleteConfirmation = false
    @State private var pendingLicenseDownload: EmbeddingModelRecord?
    @State private var showLicenseDownloadConfirmation = false
    @State private var deleteErrorMessage = ""
    @State private var showDeleteError = false
    @State private var refreshToken = UUID()

    private var record: EmbeddingModelRecord {
        _ = refreshToken
        return EmbeddingModelCatalog.record(for: recordID) ?? EmbeddingModelCatalog.activeRecord()
    }

    private var isActive: Bool {
        record.id == EmbeddingModelCatalog.activeRecord().id
    }

    private var item: DownloadController.EmbeddingItem? {
        downloadController.embeddingItems.first { $0.id == record.id }
    }

    var body: some View {
        List {
#if os(macOS)
            Section {
                macDetailHeader
            }
#endif
            Section(LocalizedStringKey("Overview")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(LocalizedStringKey(record.summary))
                        .font(FontTheme.body)
                        .foregroundStyle(AppTheme.text)

                    FlowMetadata(items: metadataItems)

                    if let artifact = record.primaryArtifact, artifact.sizeBytes > 0 {
                        HStack(spacing: 8) {
                            Text(LocalizedStringKey("Device fit"))
                                .font(FontTheme.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                            ModelRAMAdvisor.badge(
                                format: .gguf,
                                sizeBytes: artifact.sizeBytes,
                                contextLength: max(512, record.runtimeContextTokens),
                                layerCount: nil
                            )
                        }
                    }

                    EmbeddingDetailRow(label: String(localized: "Publisher"), value: record.publisher)
                    if record.licenseWarningLevel != .permissive {
                        licenseWarningRow(for: record)
                    }
                    EmbeddingDetailRow(label: String(localized: "Size"), value: formatBytes(record.primaryArtifact?.sizeBytes ?? 0))
                    EmbeddingDetailRow(label: String(localized: "Vector Dimension"), value: "\(record.dimension)")
                    EmbeddingDetailRow(label: String(localized: "Runtime Context"), value: "\(record.runtimeContextTokens)")
                    EmbeddingDetailRow(label: String(localized: "Pooling"), value: poolingLabel(record.defaultPooling))
                    EmbeddingDetailRow(
                        label: String(localized: "Normalized"),
                        value: record.normalize ? String(localized: "Yes") : String(localized: "No")
                    )
                    EmbeddingDetailRow(label: String(localized: "Max Input Tokens"), value: "\(record.maxInputTokens)")
                }
                .padding(.vertical, 4)
            }

            Section {
                TemplateSnippetView(title: String(localized: "Query Template"), template: record.templates.query)
                TemplateSnippetView(title: String(localized: "Document Template"), template: record.templates.document)
            }

            Section {
                DisclosureGroup(LocalizedStringKey("Embedding Advanced")) {
                    VStack(alignment: .leading, spacing: 12) {
                        EmbeddingDetailRow(label: String(localized: "Template Revision"), value: record.templates.revision)
                        EmbeddingDetailRow(label: String(localized: "Model ID"), value: record.id)
                        EmbeddingDetailRow(label: String(localized: "Artifact ID"), value: record.primaryArtifact?.id ?? "--")
                        EmbeddingDetailRow(label: String(localized: "Artifact File"), value: record.primaryArtifact?.filename ?? "--")
                        EmbeddingDetailRow(label: String(localized: "Runtime"), value: record.primaryArtifact?.runtime.rawValue.uppercased() ?? "--")
                        EmbeddingDetailRow(label: String(localized: "Runtime Context"), value: "\(record.runtimeContextTokens)")
                    }
                    .padding(.top, 8)
                }
            }

            if let item, item.status != .completed {
                Section {
                    EmbeddingDownloadProgressRow(item: item)
                }
            }

            Section {
                actionButtons
            }
        }
#if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
#else
        .navigationTitle(record.displayName)
#endif
        .onReceive(NotificationCenter.default.publisher(for: .embeddingModelAvailabilityChanged)) { _ in
            refreshToken = UUID()
            datasetManager.reloadFromDisk()
        }
        .confirmationDialog(
            LocalizedStringKey("Change Embedding Model?"),
            isPresented: $showSelectionConfirmation,
            titleVisibility: .visible,
            presenting: pendingSelection
        ) { record in
            Button(LocalizedStringKey("Change and Rebuild Now")) {
                Task { await activate(record, rebuildNow: true) }
            }
            Button(LocalizedStringKey("Change Later")) {
                Task { await activate(record, rebuildNow: false) }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                pendingSelection = nil
            }
        } message: { record in
            Text(String.localizedStringWithFormat(
                String(localized: "Use %@ for future dataset search? Existing dataset indexes will need to be rebuilt. You can rebuild them now or later."),
                record.displayName
            ))
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { (record: EmbeddingModelRecord) in
            Button(LocalizedStringKey("Delete Model"), role: .destructive) {
                Task { await delete(record) }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: { record in
            Text(deleteDialogMessage(for: record))
        }
        .confirmationDialog(
            LocalizedStringKey("Review License Before Downloading"),
            isPresented: $showLicenseDownloadConfirmation,
            titleVisibility: .visible,
            presenting: pendingLicenseDownload
        ) { record in
            Button(LocalizedStringKey("Download Anyway")) {
                downloadController.startEmbedding(recordID: record.id)
                pendingLicenseDownload = nil
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                pendingLicenseDownload = nil
            }
        } message: { record in
            Text(licenseDownloadConfirmationMessage(for: record))
        }
        .alert(LocalizedStringKey("Failed to Delete Embedding Model"), isPresented: $showDeleteError) {
            Button(LocalizedStringKey("OK"), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
    }

#if os(macOS)
    @ViewBuilder
    private var macDetailHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.text)
                Text(LocalizedStringKey(record.summary))
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            IndustrialIconButton(systemImage: "xmark", help: LocalizedStringKey("Close")) {
                dismiss()
            }
            .accessibilityLabel(LocalizedStringKey("Close"))
        }
    }
#endif

    private var metadataItems: [String] {
        var items = [record.sizeTier, record.licenseLabel]
        if let artifact = record.primaryArtifact, artifact.sizeBytes > 0 {
            items.append(formatBytes(artifact.sizeBytes))
        }
        return items
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            if record.isInstalled {
                if isActive {
                    Label(LocalizedStringKey("In Use"), systemImage: "checkmark.circle.fill")
                        .font(FontTheme.caption)
                        .foregroundStyle(.green)
                } else {
                    Button {
                        pendingSelection = record
                        showSelectionConfirmation = true
                    } label: {
                        Label(LocalizedStringKey("Use Model"), systemImage: "checkmark.circle")
                    }
#if os(macOS)
                    .buttonStyle(.industrial(.tinted))
#else
                    .buttonStyle(GlassButtonStyle())
#endif
                }

                Button(role: .destructive) {
                    pendingDeletion = record
                    showDeleteConfirmation = true
                } label: {
                    Label(LocalizedStringKey("Delete"), systemImage: "trash")
                }
#if os(macOS)
                .buttonStyle(.industrial(.destructive))
#else
                .buttonStyle(.borderless)
                .tint(.red)
#endif
            } else if let item, item.canResume {
                Button {
                    downloadController.resume(itemID: item.id)
                } label: {
                    Label(LocalizedStringKey("Resume"), systemImage: "play.fill")
                }
#if os(macOS)
                .buttonStyle(.industrial(.tinted))
#else
                .buttonStyle(GlassButtonStyle())
#endif

                Button(role: .cancel) {
                    downloadController.cancel(itemID: record.id)
                } label: {
                    Label(LocalizedStringKey("Cancel"), systemImage: "xmark.circle")
                }
#if os(macOS)
                .buttonStyle(.industrial(.quiet))
#else
                .buttonStyle(.borderless)
#endif
            } else if item != nil {
                Button(role: .cancel) {
                    downloadController.cancel(itemID: record.id)
                } label: {
                    Label(LocalizedStringKey("Cancel Download"), systemImage: "xmark.circle")
                }
#if os(macOS)
                .buttonStyle(.industrial(.quiet))
#else
                .buttonStyle(.borderless)
#endif
            } else if record.isInstallable {
                Button {
                    requestDownload(record)
                } label: {
                    Label(LocalizedStringKey("Download"), systemImage: "arrow.down.circle.fill")
                }
#if os(macOS)
                .buttonStyle(.industrial(.prominent))
#else
                .buttonStyle(GlassButtonStyle())
#endif
            } else {
                Text(LocalizedStringKey("Not available in this build"))
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func licenseWarningRow(for record: EmbeddingModelRecord) -> some View {
        let level = record.licenseWarningLevel
        Label {
            Text(licenseWarningSummary(for: level))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.secondaryText)
        } icon: {
            Image(systemName: level == .restricted ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(level == .restricted ? .orange : AppTheme.secondaryText)
        }
    }

    private func licenseWarningSummary(for level: ModelLicenseWarningLevel) -> LocalizedStringKey {
        switch level {
        case .restricted:
            return "Review this model's license before downloading."
        case .unknown:
            return "No clear license was found for this model."
        case .review:
            return "Review this model's license terms."
        case .permissive:
            return "Permissive license"
        }
    }

    private func requestDownload(_ record: EmbeddingModelRecord) {
        if record.licenseWarningLevel.requiresDownloadConfirmation {
            pendingLicenseDownload = record
            showLicenseDownloadConfirmation = true
        } else {
            downloadController.startEmbedding(recordID: record.id)
        }
    }

    private func activate(_ record: EmbeddingModelRecord, rebuildNow: Bool) async {
        do {
            try await EmbeddingModel.shared.setActiveModel(recordID: record.id)
            await MainActor.run {
                pendingSelection = nil
                refreshToken = UUID()
                datasetManager.reloadFromDisk()
            }
            if rebuildNow {
                await datasetManager.rebuildDatasetsNeedingReindex()
            }
            await MainActor.run {
                refreshToken = UUID()
                datasetManager.reloadFromDisk()
            }
        } catch {
            await logger.log("[EmbeddingModels] Failed to activate \(record.id): \(error.localizedDescription)")
        }
    }

    private func delete(_ record: EmbeddingModelRecord) async {
        let wasActive = record.id == EmbeddingModelCatalog.activeRecord().id
        await EmbeddingModel.shared.unload()
        do {
            let fm = FileManager.default
            let fileURL = record.installedURL
            if fm.fileExists(atPath: fileURL.path) {
                try fm.removeItem(at: fileURL)
            }
            let directory = EmbeddingModelCatalog.directoryURL(for: record.id)
            if fm.fileExists(atPath: directory.path) {
                try? fm.removeItem(at: directory)
            }
            UserDefaults.standard.removeObject(forKey: "hasInstalledEmbedModel:\(fileURL.path)")

            if wasActive {
                let fallback = fallbackActiveModelID(excluding: record.id)
                if let fallback {
                    EmbeddingModelCatalog.setActiveRecordID(fallback)
                } else {
                    UserDefaults.standard.removeObject(forKey: EmbeddingModelCatalog.activeModelIDKey)
                }
                await DatasetRetriever.shared.clearCache()
            }

            await MainActor.run {
                pendingDeletion = nil
                refreshToken = UUID()
                let nowActive = EmbeddingModelCatalog.activeRecord()
                NotificationCenter.default.post(
                    name: .embeddingModelAvailabilityChanged,
                    object: nil,
                    userInfo: ["available": nowActive.isInstalled, "recordID": record.id]
                )
                datasetManager.reloadFromDisk()
                dismiss()
            }
        } catch {
            await MainActor.run {
                pendingDeletion = nil
                deleteErrorMessage = error.localizedDescription
                showDeleteError = true
            }
        }
    }

    private func fallbackActiveModelID(excluding excludedID: String) -> String? {
        let installed = EmbeddingModelCatalog.records.first { $0.id != excludedID && $0.isInstalled }
        if let installed { return installed.id }
        if let def = EmbeddingModelCatalog.record(for: EmbeddingModelCatalog.defaultModelID),
           def.id != excludedID {
            return def.id
        }
        return nil
    }

    private var deleteDialogTitle: Text {
        let title = String.localizedStringWithFormat(String(localized: "Delete %@?"), record.displayName)
        return Text(title)
    }

    private func deleteDialogMessage(for record: EmbeddingModelRecord) -> String {
        let size = formatBytes(record.primaryArtifact?.sizeBytes ?? 0)
        if isActive {
            let fallback = fallbackActiveModelID(excluding: record.id)
            let fallbackName = fallback.flatMap { EmbeddingModelCatalog.record(for: $0)?.displayName }
            if let fallbackName {
                return String.localizedStringWithFormat(
                    String(localized: "This model is currently active. Deleting will remove %@ from this device and switch the active model to %@. Existing dataset indexes will need to be rebuilt."),
                    size,
                    fallbackName
                )
            }
            return String.localizedStringWithFormat(
                String(localized: "This model is currently active. Deleting will remove %@ from this device and leave no active embedding model — you will need to download one before using dataset search."),
                size
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "Delete this embedding model from this device? This removes %@."),
            size
        )
    }

    private func licenseDownloadConfirmationMessage(for record: EmbeddingModelRecord) -> String {
        switch record.licenseWarningLevel {
        case .restricted:
            return String.localizedStringWithFormat(
                String(localized: "The license label for %@ is %@. Confirm that your use is allowed before downloading."),
                record.displayName,
                record.licenseLabel
            )
        case .unknown:
            return String.localizedStringWithFormat(
                String(localized: "No clear license was found for %@. Confirm that your use is allowed before downloading."),
                record.displayName
            )
        case .review, .permissive:
            return String.localizedStringWithFormat(
                String(localized: "Review the %@ license for %@ before downloading."),
                record.licenseLabel,
                record.displayName
            )
        }
    }

    private func poolingLabel(_ pooling: EmbeddingPooling) -> String {
        switch pooling {
        case .mean:
            return String(localized: "Mean")
        case .cls:
            return String(localized: "CLS")
        case .lastToken:
            return String(localized: "Last Token")
        case .modelDefault:
            return String(localized: "Model Default")
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes >= 1_000_000_000 ? [.useGB] : [.useMB]
        return formatter.string(fromByteCount: bytes)
    }
}

private struct EmbeddingDownloadProgressRow: View {
    let item: DownloadController.EmbeddingItem

    var body: some View {
        DownloadProgressCluster(
            progress: item.progress,
            speed: item.speed,
            statusKey: item.status == .downloading ? nil : LocalizedStringKey(item.status.statusLabelKey)
        )
    }
}

private struct TemplateSnippetView: View {
    let title: String
    let template: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(FontTheme.body)
                .fontWeight(.semibold)
                .foregroundStyle(AppTheme.text)

            Text(template)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.vertical, 4)
    }
}

private struct EmbeddingDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(FontTheme.body)
                .foregroundStyle(AppTheme.text)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Metadata flow helper

private struct FlowMetadata: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                if item != items.last {
                    Text("·")
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
    }
}

#if os(macOS)
private let catalogCardCornerRadius: CGFloat = 8
private let catalogCardStrokeOpacity: Double = 0.08
private let catalogCardShadowOpacity: Double = 0
private let catalogStatusIconSize: CGFloat = 16
private let catalogStatusIconFrame: CGFloat = 20
private let catalogSearchFieldCornerRadius: CGFloat = 6
private let catalogSearchIconSize: CGFloat = 12
private let catalogSearchFieldHorizontalPadding: CGFloat = 10
#else
private let catalogCardCornerRadius: CGFloat = 22
private let catalogCardStrokeOpacity: Double = 0.04
private let catalogCardShadowOpacity: Double = 0.035
private let catalogStatusIconSize: CGFloat = 27
private let catalogStatusIconFrame: CGFloat = 28
private let catalogSearchFieldCornerRadius: CGFloat = 14
private let catalogSearchIconSize: CGFloat = 15
private let catalogSearchFieldHorizontalPadding: CGFloat = 13
#endif
