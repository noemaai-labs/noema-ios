import SwiftUI

#if canImport(WhisperKit)
import WhisperKit
#endif

@MainActor
final class WhisperModelDownloadStore: ObservableObject {
    @Published var progress: [String: Double] = [:]
    @Published var errors: [String: String] = [:]
    @Published var activeDownloads: Set<String> = []
    private var progressPollTasks: [String: Task<Void, Never>] = [:]

    deinit {
        progressPollTasks.values.forEach { $0.cancel() }
    }

    func download(record: WhisperModelRecord, runtime: WhisperRuntimeFormat) async {
        guard let artifact = record.artifact(for: runtime),
              let remoteURL = artifact.downloadURL else {
            await prepareWhisperKitModel(record: record)
            return
        }

        let dir = record.directoryURL(runtime: runtime)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            errors[record.id] = error.localizedDescription
            return
        }

        let destination = dir.appendingPathComponent(
            URL(fileURLWithPath: artifact.resourcePath).lastPathComponent
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            progress[record.id] = 1
            return
        }

        activeDownloads.insert(record.id)
        errors[record.id] = nil
        progress[record.id] = 0

        do {
            var req = URLRequest(url: remoteURL)
            req.setValue("Noema/1.0 (+https://noema.app)", forHTTPHeaderField: "User-Agent")
            _ = try await BackgroundDownloadManager.shared.download(
                request: req,
                to: destination,
                expectedSize: artifact.sizeBytes,
                progress: { [weak self] p in
                    Task { @MainActor in
                        self?.progress[record.id] = max(0, min(1, p))
                    }
                },
                progressBytes: { _, _ in }
            )
            progress[record.id] = 1
        } catch {
            Task { await logger.log("[WhisperModelDownload] Failed \(record.id): \(error.localizedDescription)") }
            errors[record.id] = userFacingDownloadError(error)
            progress.removeValue(forKey: record.id)
        }
        activeDownloads.remove(record.id)
    }

    func prepareWhisperKitModel(record: WhisperModelRecord) async {
        guard let artifact = record.artifact(for: .whisperKit) else {
            errors[record.id] = String(localized: "No WhisperKit artifact is available for this model.")
            return
        }
        let dir = record.directoryURL(runtime: .whisperKit)
        activeDownloads.insert(record.id)
        errors[record.id] = nil
        progress[record.id] = 0
        startWhisperKitProgressEstimate(record: record, artifact: artifact)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #if canImport(WhisperKit)
            // Route the CoreML package download through the configured HF endpoint.
            let whisperConfig = WhisperKitConfig(
                model: artifact.resourcePath,
                downloadBase: dir,
                modelRepo: artifact.repoID,
                modelEndpoint: HFEndpoint.baseURL?.absoluteString
            )
            _ = try await WhisperKit(whisperConfig)
            guard WhisperModelCatalog.installationState(for: record, runtime: .whisperKit) == .ready else {
                errors[record.id] = String(localized: "Incomplete download. Repair and download again.")
                progress.removeValue(forKey: record.id)
                stopProgressEstimate(for: record.id)
                activeDownloads.remove(record.id)
                return
            }
            stopProgressEstimate(for: record.id)
            progress[record.id] = 1
            #else
            errors[record.id] = String(localized: "WhisperKit is not linked in this build.")
            progress.removeValue(forKey: record.id)
            stopProgressEstimate(for: record.id)
            #endif
        } catch {
            Task { await logger.log("[WhisperModelDownload] Failed \(record.id): \(error.localizedDescription)") }
            errors[record.id] = userFacingDownloadError(error)
            progress.removeValue(forKey: record.id)
            stopProgressEstimate(for: record.id)
        }
        activeDownloads.remove(record.id)
    }

    func repairAndDownload(record: WhisperModelRecord, runtime: WhisperRuntimeFormat) async {
        let dir = record.directoryURL(runtime: runtime)
        try? FileManager.default.removeItem(at: dir)
        progress.removeValue(forKey: record.id)
        errors.removeValue(forKey: record.id)
        await download(record: record, runtime: runtime)
    }

    func delete(record: WhisperModelRecord, runtime: WhisperRuntimeFormat) {
        let dir = record.directoryURL(runtime: runtime)
        try? FileManager.default.removeItem(at: dir)
        if let url = record.installedURL(runtime: runtime) {
            try? FileManager.default.removeItem(at: url)
        }
        switch runtime {
        case .whisperKit:
            if WhisperModelCatalog.activeRecordID(for: .whisperKit) == record.id {
                UserDefaults.standard.removeObject(forKey: TranscriptionSettings.whisperKitActiveModelKey)
            }
        case .ggml:
            if WhisperModelCatalog.activeRecordID(for: .whisperCpp) == record.id {
                UserDefaults.standard.removeObject(forKey: TranscriptionSettings.whisperCppActiveModelKey)
            }
        }
        progress.removeValue(forKey: record.id)
        errors.removeValue(forKey: record.id)
    }

    nonisolated static func estimatedProgress(observedBytes: Int64, expectedBytes: Int64) -> Double? {
        guard observedBytes > 0, expectedBytes > 0 else { return nil }
        return min(0.97, max(0.05, Double(observedBytes) / Double(expectedBytes)))
    }

    private func startWhisperKitProgressEstimate(record: WhisperModelRecord, artifact: WhisperArtifact) {
        stopProgressEstimate(for: record.id)
        let id = record.id
        let dir = record.directoryURL(runtime: .whisperKit)
        let expectedBytes = artifact.sizeBytes
        progressPollTasks[id] = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let observedBytes = Self.directorySize(at: dir)
                if let value = Self.estimatedProgress(observedBytes: observedBytes, expectedBytes: expectedBytes) {
                    await self?.setEstimatedProgress(value, for: id)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopProgressEstimate(for id: String) {
        progressPollTasks[id]?.cancel()
        progressPollTasks[id] = nil
    }

    private func setEstimatedProgress(_ value: Double, for id: String) {
        let clamped = max(0, min(0.97, value))
        if let existing = progress[id], existing >= clamped { return }
        progress[id] = clamped
    }

    nonisolated private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func userFacingDownloadError(_ error: Error) -> String {
        let message = error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("model not found") ||
            lower.contains(".incomplete") ||
            lower.contains("couldn't be moved") ||
            lower.contains("no such file") {
            return String(localized: "Incomplete download. Repair and download again.")
        }
        return String(localized: "Whisper model download failed. Try again.")
    }
}

struct WhisperModelsView: View {
    let engineID: TranscriptionEngineID
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloadController: DownloadController
    @StateObject private var store = WhisperModelDownloadStore()
    @State private var activeRecordID: String = ""
    @State private var runtimeEngineID: TranscriptionEngineID
    @State private var searchText = ""

    init(engineID: TranscriptionEngineID) {
        self.engineID = engineID
        self._runtimeEngineID = State(initialValue: engineID.isLocalWhisper ? engineID : TranscriptionBackendFactory.preferredLocalWhisperEngineID())
    }

    private var runtime: WhisperRuntimeFormat {
        WhisperModelCatalog.runtimeFormat(for: runtimeEngineID) ?? .whisperKit
    }

    private var records: [WhisperModelRecord] {
        WhisperModelCatalog.records
    }

    private var filteredRecords: [WhisperModelRecord] {
        let query = trimmedSearchText.lowercased()
        guard !query.isEmpty else { return records }
        return records.filter { record in
            record.displayName.localizedCaseInsensitiveContains(query) ||
                record.sizeTier.localizedCaseInsensitiveContains(query) ||
                record.summary.localizedCaseInsensitiveContains(query) ||
                record.defaultLocale.localizedCaseInsensitiveContains(query)
        }
    }

    private var downloadedRecords: [WhisperModelRecord] {
        filteredRecords.filter { record in
            WhisperModelCatalog.installationState(for: record, runtime: runtime) == .ready
        }
    }

    private var recommendedRecords: [WhisperModelRecord] {
        filteredRecords.filter { record in
            record.isRecommended &&
                WhisperModelCatalog.installationState(for: record, runtime: runtime) != .ready
        }
    }

    private var availableRecords: [WhisperModelRecord] {
        filteredRecords.filter { record in
            !record.isRecommended &&
                WhisperModelCatalog.installationState(for: record, runtime: runtime) != .ready
        }
    }

    private var hasVisibleRows: Bool {
        !downloadedRecords.isEmpty || !recommendedRecords.isEmpty || !availableRecords.isEmpty
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
#if os(macOS)
                macCatalogHeader
#endif
                runtimeCard
#if os(macOS)
                macSearchField
#endif

                if hasVisibleRows {
                    modelSection(title: "Downloaded", records: downloadedRecords)
                    modelSection(title: "Recommended", records: recommendedRecords)
                    modelSection(title: "Available", records: availableRecords)
                } else if !trimmedSearchText.isEmpty {
                    emptySearchResults
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .background(AppTheme.windowBackground.ignoresSafeArea())
#if !os(macOS)
        .navigationTitle(LocalizedStringKey("Whisper Model"))
        .searchable(text: $searchText, prompt: Text(LocalizedStringKey("Search Whisper models")))
#endif
        .onAppear {
            activeRecordID = WhisperModelCatalog.activeRecordID(for: runtimeEngineID)
        }
#if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
#endif
    }

#if os(macOS)
    @ViewBuilder
    private var macCatalogHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Whisper Model"))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppTheme.text)
                Text(LocalizedStringKey("Choose the local speech model used for on-device transcription."))
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(LocalizedStringKey("Close"))
        }
    }
#endif

    private var localRuntimeOptions: [EngineAvailability] {
        TranscriptionBackendFactory.availableEngines()
            .filter { $0.id.isLocalWhisper }
    }

    @ViewBuilder
    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("Runtime"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.text)
                    Text(engineFootnote)
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if localRuntimeOptions.isEmpty {
                    Text(LocalizedStringKey("No local Whisper runtime is available in this build."))
                        .font(FontTheme.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.trailing)
                } else {
                    Picker(LocalizedStringKey("Whisper Runtime"), selection: $runtimeEngineID) {
                        ForEach(localRuntimeOptions) { entry in
                            Text(entry.id.displayName)
                                .tag(entry.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: runtimeEngineID) { _, newValue in
                        UserDefaults.standard.set(newValue.rawValue, forKey: TranscriptionSettings.engineIDKey)
                        activeRecordID = WhisperModelCatalog.activeRecordID(for: newValue)
                    }
                }
            }

            if let reason = TranscriptionBackendFactory.unavailableReason(for: runtimeEngineID) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(FontTheme.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
        )
    }

#if os(macOS)
    @ViewBuilder
    private var macSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 18)

            TextField(LocalizedStringKey("Search Whisper models"), text: $searchText)
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
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
        )
    }
#endif

    private var engineFootnote: String {
        switch runtimeEngineID {
        case .whisperKit:
            return String(localized: "WhisperKit downloads a Core ML package on first use; use the button below to prefetch.")
        case .whisperCpp:
            return String(localized: "whisper.cpp loads a ggml .bin file. Download before going offline.")
        default:
            return ""
        }
    }

    @ViewBuilder
    private var emptySearchResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(AppTheme.secondaryText)
            Text(String.localizedStringWithFormat(
                String(localized: "No Whisper models found for '%@'"),
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
    private func modelSection(title: String, records: [WhisperModelRecord]) -> some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 4)

                ForEach(records) { record in
                    modelCard(for: record)
                }
            }
        }
    }

    @ViewBuilder
    private func modelCard(for record: WhisperModelRecord) -> some View {
        let controllerItem = downloadController.whisperItems.first {
            $0.id == DownloadController.whisperExternalID(recordID: record.id, runtime: runtime)
        }
        let installState = WhisperModelCatalog.installationState(for: record, runtime: runtime)
        let state = SupportModelInventory.supportState(
            downloadState: store.activeDownloads.contains(record.id) ? .downloading : controllerItem?.status,
            installState: installState
        )
        let installed = state == .ready
        let isActive = record.id == activeRecordID
        let isDownloading = state == .downloading
        let progressValue = controllerItem?.progress ?? store.progress[record.id] ?? 0
        let hasDeterminateProgress = progressValue > 0

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                statusIcon(for: state, isActive: isActive)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.displayName)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(AppTheme.text)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                            statusBadges(record: record, state: state, isActive: isActive)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let artifact = record.artifact(for: runtime), artifact.sizeBytes > 0 {
                            ModelRAMAdvisor.badge(
                                format: .gguf,
                                sizeBytes: artifact.sizeBytes,
                                contextLength: 2048,
                                layerCount: nil
                            )
                            .padding(.top, 1)
                        }
                    }

                    Text(LocalizedStringKey(record.summary))
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    chipRow(items: summaryChips(for: record))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isDownloading {
                downloadProgressView(
                    state: state,
                    progressValue: progressValue,
                    hasDeterminateProgress: hasDeterminateProgress
                )
                .padding(.leading, 42)
            }

            if let error = store.errors[record.id] ?? controllerItem?.error?.localizedDescription {
                Text(error)
                    .font(FontTheme.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 42)
            }

            HStack {
                Spacer(minLength: 42)
                cardActions(
                    record: record,
                    controllerItem: controllerItem,
                    state: state,
                    installed: installed,
                    isActive: isActive,
                    isDownloading: isDownloading
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 5)
        .contextMenu {
            contextActions(
                record: record,
                controllerItem: controllerItem,
                state: state,
                installed: installed,
                isActive: isActive,
                isDownloading: isDownloading
            )
        }
    }

    private func retry(record: WhisperModelRecord, controllerItem: DownloadController.WhisperItem?) {
        if let controllerItem {
            downloadController.resume(itemID: controllerItem.id)
            return
        }
        if record.artifact(for: runtime)?.downloadURL != nil {
            downloadController.startWhisper(recordID: record.id, runtime: runtime)
        } else {
            Task { await store.download(record: record, runtime: runtime) }
        }
    }

    @ViewBuilder
    private func cardActions(
        record: WhisperModelRecord,
        controllerItem: DownloadController.WhisperItem?,
        state: SupportModelState,
        installed: Bool,
        isActive: Bool,
        isDownloading: Bool
    ) -> some View {
        HStack(spacing: 10) {
            if installed {
                if isActive {
                    Label(LocalizedStringKey("In Use"), systemImage: "checkmark.circle.fill")
                        .font(FontTheme.caption)
                        .foregroundStyle(.green)
                } else {
                    Button(LocalizedStringKey("Use Model")) {
                        WhisperModelCatalog.setActiveRecordID(record.id, for: runtimeEngineID)
                        activeRecordID = record.id
                    }
                    .buttonStyle(.bordered)
                }

                Button(LocalizedStringKey("Delete"), role: .destructive) {
                    store.delete(record: record, runtime: runtime)
                }
                .buttonStyle(.borderless)
            } else if state == .incomplete {
                Button(LocalizedStringKey("Repair")) {
                    Task { await store.repairAndDownload(record: record, runtime: runtime) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading)
            } else if state == .failed || state == .paused {
                Button(LocalizedStringKey("Retry")) {
                    retry(record: record, controllerItem: controllerItem)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading)
            } else {
                Button(LocalizedStringKey("Download")) {
                    download(record: record)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading)
            }
        }
    }

    @ViewBuilder
    private func contextActions(
        record: WhisperModelRecord,
        controllerItem: DownloadController.WhisperItem?,
        state: SupportModelState,
        installed: Bool,
        isActive: Bool,
        isDownloading: Bool
    ) -> some View {
        if installed {
            if !isActive {
                Button {
                    WhisperModelCatalog.setActiveRecordID(record.id, for: runtimeEngineID)
                    activeRecordID = record.id
                } label: {
                    Label(LocalizedStringKey("Use Model"), systemImage: "checkmark.circle")
                }
            }
            Button(role: .destructive) {
                store.delete(record: record, runtime: runtime)
            } label: {
                Label(LocalizedStringKey("Delete"), systemImage: "trash")
            }
        } else if state == .incomplete {
            Button {
                Task { await store.repairAndDownload(record: record, runtime: runtime) }
            } label: {
                Label(LocalizedStringKey("Repair"), systemImage: "wrench.and.screwdriver")
            }
            .disabled(isDownloading)
        } else if state == .failed || state == .paused {
            Button {
                retry(record: record, controllerItem: controllerItem)
            } label: {
                Label(LocalizedStringKey("Retry"), systemImage: "arrow.clockwise")
            }
            .disabled(isDownloading)
        } else {
            Button {
                download(record: record)
            } label: {
                Label(LocalizedStringKey("Download"), systemImage: "arrow.down.circle.fill")
            }
            .disabled(isDownloading)
        }
    }

    @ViewBuilder
    private func statusBadges(record: WhisperModelRecord, state: SupportModelState, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            if record.isRecommended {
                badge(String(localized: "Recommended"), color: .green)
            }
            if isActive {
                badge(String(localized: "Active"), color: .green)
            } else if state != .missing {
                stateBadge(state)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func stateBadge(_ state: SupportModelState) -> some View {
        badge(stateTitle(state), color: statusColor(state))
    }

    @ViewBuilder
    private func statusIcon(for state: SupportModelState, isActive: Bool) -> some View {
        ZStack {
            if isActive {
                Circle()
                    .fill(.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: state.systemImage)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(statusColor(state))
            }
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private func downloadProgressView(
        state: SupportModelState,
        progressValue: Double,
        hasDeterminateProgress: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasDeterminateProgress {
                ProgressView(value: progressValue)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 8) {
                Text(LocalizedStringKey(state.titleKey))
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                if hasDeterminateProgress {
                    Text("\(Int((progressValue * 100).rounded()))%")
                        .font(FontTheme.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
    }

    private func download(record: WhisperModelRecord) {
        if record.artifact(for: runtime)?.downloadURL != nil {
            downloadController.startWhisper(recordID: record.id, runtime: runtime)
        } else {
            Task { await store.download(record: record, runtime: runtime) }
        }
    }

    private func statusColor(_ state: SupportModelState) -> Color {
        switch state {
        case .ready: return .green
        case .missing: return .secondary
        case .downloading: return .blue
        case .paused: return .orange
        case .failed, .incomplete: return .red
        }
    }

    private func stateTitle(_ state: SupportModelState) -> String {
        switch state {
        case .ready: return String(localized: "Ready")
        case .missing: return String(localized: "Not Downloaded")
        case .downloading: return String(localized: "Downloading")
        case .paused: return String(localized: "Paused")
        case .failed: return String(localized: "Failed")
        case .incomplete: return String(localized: "Incomplete Download")
        }
    }

    private var cardBackground: Color {
#if os(macOS)
        Color(nsColor: .controlBackgroundColor)
#else
        Color(uiColor: .secondarySystemGroupedBackground)
#endif
    }

    private func summaryChips(for record: WhisperModelRecord) -> [String] {
        var items = [
            record.sizeTier,
            record.multilingual ? String(localized: "Multilingual") : String(localized: "English only")
        ]
        if let artifact = record.artifact(for: runtime), artifact.sizeBytes > 0 {
            items.append(formatBytes(artifact.sizeBytes))
        }
        items.append(runtimeEngineID.displayName)
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
    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(FontTheme.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func detailChip(label: String) -> some View {
        Text(label)
            .font(FontTheme.caption)
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes >= 1_000_000_000 ? [.useGB] : [.useMB]
        return formatter.string(fromByteCount: bytes)
    }
}
