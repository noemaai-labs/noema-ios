import SwiftUI

/// Lightweight recency for the chat dataset picker. Dataset metadata is rebuilt
/// from disk, so keeping the stable IDs in defaults avoids changing that format.
enum ChatDatasetRecents {
    private static let defaultsKey = "recentChatDatasetIDs"
    private static let maximumCount = 5

    static var datasetIDs: [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    static func record(_ datasetID: String) {
        guard !datasetID.isEmpty else { return }
        var ids = datasetIDs.filter { $0 != datasetID }
        ids.insert(datasetID, at: 0)
        UserDefaults.standard.set(Array(ids.prefix(maximumCount)), forKey: defaultsKey)
    }
}

/// A focused chat-level chooser. Stored remains the place for downloading,
/// preparing, inspecting, and deleting datasets.
struct ChatDatasetPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm: ChatVM
    @EnvironmentObject private var datasetManager: DatasetManager
    @EnvironmentObject private var tabRouter: TabRouter
    @State private var searchText = ""
#if os(macOS)
    @State private var hoveredRowID: String?
#endif

    var body: some View {
#if os(macOS)
        macPicker
#else
        touchPicker
#endif
    }

#if os(macOS)
    private var macPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(LocalizedStringKey("Choose Dataset"))
                    .font(.headline)

                Spacer(minLength: 16)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text(LocalizedStringKey("Close")))
                .help(Text(LocalizedStringKey("Close")))
            }
            .padding(.horizontal, 18)
            .frame(height: 52)

            Divider()

            if showsMacSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField(
                        String(localized: "Search datasets"),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    macClearSelectionButton

                    Divider()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)

                    if availableDatasets.isEmpty {
                        Text(LocalizedStringKey("No datasets available yet. Import or download datasets to build your personal library."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                    } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !recentDatasets.isEmpty {
                            macSectionHeader("Recent")
                            ForEach(recentDatasets) { dataset in
                                macDatasetButton(dataset)
                            }
                        }

                        if !otherDatasets.isEmpty {
                            macSectionHeader("Your Datasets")
                            ForEach(otherDatasets) { dataset in
                                macDatasetButton(dataset)
                            }
                        }
                    } else if filteredDatasets.isEmpty {
                        Text(LocalizedStringKey("No matching datasets"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                    } else {
                        macSectionHeader("Your Datasets")
                        ForEach(filteredDatasets) { dataset in
                            macDatasetButton(dataset)
                        }
                    }
                }
                .padding(8)
            }

            Divider()

            Button {
                openStored()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 20)
                        .foregroundStyle(.secondary)

                    Text(LocalizedStringKey("Stored"))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .frame(height: 48)
                .contentShape(Rectangle())
                .background(
                    hoveredRowID == macStoredRowID ? Color.primary.opacity(0.055) : Color.clear
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                updateMacHover(macStoredRowID, isHovering: isHovering)
            }
            .accessibilityIdentifier("chat-dataset-open-stored")
        }
        .frame(width: 430, height: macPickerHeight)
    }

    private var macClearSelectionButton: some View {
        Button(action: clearSelection) {
            HStack(spacing: 10) {
                Image(systemName: "circle.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                    .foregroundStyle(vm.activeSessionDataset == nil ? Color.accentColor : .secondary)

                Text(LocalizedStringKey("No Dataset"))
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                if vm.activeSessionDataset == nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .contentShape(Rectangle())
            .background(
                hoveredRowID == macNoDatasetRowID ? Color.primary.opacity(0.055) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            updateMacHover(macNoDatasetRowID, isHovering: isHovering)
        }
        .accessibilityIdentifier("chat-dataset-none")
    }

    private func macSectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 3)
    }

    private func macDatasetButton(_ dataset: LocalDataset) -> some View {
        Button {
            choose(dataset)
        } label: {
            ChatDatasetPickerRow(
                dataset: dataset,
                isActive: vm.activeSessionDataset?.datasetID == dataset.datasetID,
                isReady: isReady(dataset),
                isProcessing: isProcessing(dataset),
                processingStatus: datasetManager.processingStatus[dataset.datasetID]
            )
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(
                hoveredRowID == dataset.datasetID ? Color.primary.opacity(0.055) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            updateMacHover(dataset.datasetID, isHovering: isHovering)
        }
        .accessibilityIdentifier("chat-dataset-\(dataset.datasetID)")
    }

    private var showsMacSearch: Bool {
        availableDatasets.count > 5 || !searchText.isEmpty
    }

    private var macPickerHeight: CGFloat {
        let searchHeight: CGFloat = showsMacSearch ? 48 : 0
        let rowCount = availableDatasets.count
        let sectionCount = recentDatasets.isEmpty || otherDatasets.isEmpty ? 1 : 2
        let emptyContentHeight: CGFloat = availableDatasets.isEmpty ? 78 : 0
        let listContentHeight = 58
            + emptyContentHeight
            + CGFloat(sectionCount * 28)
            + CGFloat(rowCount * 50)
        return min(max(52 + searchHeight + listContentHeight + 49, 268), 520)
    }

    private var macNoDatasetRowID: String { "__no_dataset__" }
    private var macStoredRowID: String { "__stored__" }

    private func updateMacHover(_ rowID: String, isHovering: Bool) {
        if isHovering {
            hoveredRowID = rowID
        } else if hoveredRowID == rowID {
            hoveredRowID = nil
        }
    }
#else
    private var touchPicker: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: clearSelection) {
                        HStack(spacing: 12) {
                            Image(systemName: "circle.slash")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 24)
                                .foregroundStyle(.secondary)

                            Text(LocalizedStringKey("No Dataset"))
                                .foregroundStyle(.primary)

                            Spacer(minLength: 12)

                            if vm.activeSessionDataset == nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat-dataset-none")
                }

                if availableDatasets.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(LocalizedStringKey("No Dataset"), systemImage: "books.vertical")
                                .font(.headline)
                            Text(LocalizedStringKey("No datasets available yet. Import or download datasets to build your personal library."))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !recentDatasets.isEmpty {
                        Section(LocalizedStringKey("Recent")) {
                            ForEach(recentDatasets) { dataset in
                                datasetButton(dataset)
                            }
                        }
                    }

                    if !otherDatasets.isEmpty {
                        Section(LocalizedStringKey("Your Datasets")) {
                            ForEach(otherDatasets) { dataset in
                                datasetButton(dataset)
                            }
                        }
                    }
                } else {
                    Section(LocalizedStringKey("Your Datasets")) {
                        ForEach(filteredDatasets) { dataset in
                            datasetButton(dataset)
                        }
                    }
                }

                Section {
                    Button {
                        openStored()
                    } label: {
                        Label(LocalizedStringKey("Stored"), systemImage: "externaldrive")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("chat-dataset-open-stored")
                }
            }
#if os(macOS)
            .listStyle(.inset)
#else
            .listStyle(.insetGrouped)
#endif
            .searchable(text: $searchText, prompt: Text(LocalizedStringKey("Search datasets")))
            .navigationTitle(LocalizedStringKey("Choose Dataset"))
#if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("Close")) { dismiss() }
                }
            }
        }
    }
#endif

    private var availableDatasets: [LocalDataset] {
        datasetManager.datasets
            .filter { EnterprisePolicyGate.allowsDataset(datasetID: $0.datasetID) }
            .sorted { lhs, rhs in
                if isReady(lhs) != isReady(rhs) { return isReady(lhs) }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var recentDatasets: [LocalDataset] {
        let byID = Dictionary(uniqueKeysWithValues: availableDatasets.map { ($0.datasetID, $0) })
        return ChatDatasetRecents.datasetIDs.compactMap { byID[$0] }
    }

    private var otherDatasets: [LocalDataset] {
        let recentIDs = Set(recentDatasets.map(\.datasetID))
        return availableDatasets.filter { !recentIDs.contains($0.datasetID) }
    }

    private var filteredDatasets: [LocalDataset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availableDatasets }
        return availableDatasets.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.source.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func datasetButton(_ dataset: LocalDataset) -> some View {
        Button {
            choose(dataset)
        } label: {
            ChatDatasetPickerRow(
                dataset: dataset,
                isActive: vm.activeSessionDataset?.datasetID == dataset.datasetID,
                isReady: isReady(dataset),
                isProcessing: isProcessing(dataset),
                processingStatus: datasetManager.processingStatus[dataset.datasetID]
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-dataset-\(dataset.datasetID)")
    }

    private func isReady(_ dataset: LocalDataset) -> Bool {
        guard !dataset.requiresReindex else { return false }
        return dataset.isIndexed
            || DatasetIndexIO.hasValidIndex(at: dataset.url)
            || datasetManager.processingStatus[dataset.datasetID]?.stage == .completed
    }

    private func isProcessing(_ dataset: LocalDataset) -> Bool {
        if datasetManager.indexingDatasetID == dataset.datasetID { return true }
        guard let status = datasetManager.processingStatus[dataset.datasetID] else { return false }
        return status.stage != .completed && status.stage != .failed
    }

    private func choose(_ dataset: LocalDataset) {
        guard isReady(dataset) else {
            openStored(datasetID: dataset.datasetID)
            return
        }
        vm.setDatasetForActiveSession(dataset)
        dismiss()
    }

    private func clearSelection() {
        vm.setDatasetForActiveSession(nil)
        dismiss()
    }

    private func openStored(datasetID: String? = nil) {
        if let datasetID {
            tabRouter.pendingStoredDatasetID = datasetID
        }
        dismiss()
        Task { @MainActor in
            await Task.yield()
            tabRouter.selection = .stored
        }
    }
}

private struct ChatDatasetPickerRow: View {
    let dataset: LocalDataset
    let isActive: Bool
    let isReady: Bool
    let isProcessing: Bool
    let processingStatus: DatasetProcessingStatus?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: dataset.source == "Enterprise" ? "building.2.fill" : "doc.richtext")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 24)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(dataset.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(dataset.source == "Enterprise" ? String(localized: "Company") : dataset.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            status
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var status: some View {
        if isActive && isReady {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        } else if isProcessing {
            if let processingStatus {
                ProgressView(value: max(0, min(1, processingStatus.progress)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        } else if isReady {
            Text(LocalizedStringKey("Ready"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 5) {
                Text(LocalizedStringKey(dataset.requiresReindex ? "Rebuild Required" : "Not Ready"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.orange)
        }
    }
}
