import SwiftUI

struct DatasetHealthSummaryContent: View {
    @ObservedObject var datasetManager: DatasetManager
    let openDashboard: () -> Void

    private struct Summary: Equatable, Sendable {
        var ready = 0
        var issues = 0
    }
    @State private var summary = Summary()

    private var datasetCount: Int { datasetManager.datasets.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: summary.issues == 0 ? "checkmark.seal.fill" : "cross.case.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(summary.issues == 0 ? Color.green : Color.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Dataset Health"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(summaryText)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openDashboard) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Dataset Health"))
            }

            HStack(spacing: 8) {
                DatasetHealthPill(title: LocalizedStringKey("Datasets"), value: "\(datasetCount)")
                DatasetHealthPill(title: LocalizedStringKey("Ready"), value: "\(summary.ready)")
                DatasetHealthPill(title: LocalizedStringKey("Issues"), value: "\(summary.issues)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openDashboard)
        .task(id: datasetSignature) { await refresh() }
    }

    private var datasetSignature: String {
        datasetManager.datasets.map(\.datasetID).joined(separator: "|")
    }

    // Building the health snapshots walks every dataset's directory tree and
    // reads its index files; do that off the main thread so scrolling stays smooth.
    @MainActor
    private func refresh() async {
        let datasets = datasetManager.datasets
        let statuses = datasetManager.processingStatus
        let computed = await Task.detached(priority: .utility) { () -> Summary in
            let snapshots = DatasetHealthSnapshot.snapshots(for: datasets, statuses: statuses)
            var result = Summary()
            result.ready = snapshots.filter { $0.state == .ready }.count
            result.issues = snapshots.reduce(0) { $0 + $1.issues.count }
            return result
        }.value
        guard !Task.isCancelled else { return }
        summary = computed
    }

    private var summaryText: String {
        guard datasetCount > 0 else {
            return String(localized: "No local datasets installed.")
        }
        if summary.issues == 0 {
            return String(localized: "Indexes, files, and embedding metadata look healthy.")
        }
        return String.localizedStringWithFormat(
            String(localized: "%d dataset health issues found"),
            summary.issues
        )
    }
}

struct DatasetHealthDashboardView: View {
    @EnvironmentObject private var datasetManager: DatasetManager
    @State private var searchText = ""

    private var snapshots: [DatasetHealthSnapshot] {
        DatasetHealthSnapshot.snapshots(for: datasetManager.datasets, statuses: datasetManager.processingStatus)
    }

    private var filteredSnapshots: [DatasetHealthSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return snapshots }
        return snapshots.filter { snapshot in
            "\(snapshot.dataset.name) \(snapshot.dataset.datasetID) \(snapshot.dataset.source) \(snapshot.issues.map(\.title).joined(separator: " "))"
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var staleSnapshots: [DatasetHealthSnapshot] {
        snapshots.filter(\.canRebuild)
    }

    private var issueCount: Int {
        snapshots.reduce(0) { $0 + $1.issues.count }
    }

    var body: some View {
        Form {
            Section(LocalizedStringKey("Dataset Health")) {
                HStack(spacing: 8) {
                    DatasetHealthPill(title: LocalizedStringKey("Datasets"), value: "\(snapshots.count)")
                    DatasetHealthPill(title: LocalizedStringKey("Issues"), value: "\(issueCount)")
                    DatasetHealthPill(title: LocalizedStringKey("Rebuildable"), value: "\(staleSnapshots.count)")
                }

                TextField(LocalizedStringKey("Search datasets"), text: $searchText)
#if !os(macOS)
                    .textInputAutocapitalization(.never)
#endif
                    .autocorrectionDisabled()

                Button {
                    datasetManager.reloadFromDisk()
                } label: {
                    Label(LocalizedStringKey("Refresh Health Checks"), systemImage: "arrow.clockwise")
                }

                Button {
                    rebuildAllStaleDatasets()
                } label: {
                    Label(LocalizedStringKey("Rebuild Stale Indexes"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(staleSnapshots.isEmpty)
            }

            if snapshots.isEmpty {
                Section {
                    ContentUnavailableView(
                        LocalizedStringKey("No local datasets installed."),
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
            } else if filteredSnapshots.isEmpty {
                Section {
                    ContentUnavailableView(
                        LocalizedStringKey("No matching datasets"),
                        systemImage: "magnifyingglass"
                    )
                }
            } else {
                Section(LocalizedStringKey("Dataset Checks")) {
                    ForEach(filteredSnapshots) { snapshot in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                DatasetHealthMetricsView(snapshot: snapshot)

                                if snapshot.issues.isEmpty {
                                    DatasetHealthIssueRow(
                                        issue: DatasetHealthIssue(
                                            title: String(localized: "Healthy"),
                                            detail: String(localized: "Index metadata, vectors, and source files are consistent."),
                                            severity: .ready
                                        )
                                    )
                                } else {
                                    ForEach(snapshot.issues) { issue in
                                        DatasetHealthIssueRow(issue: issue)
                                    }
                                }

                                if snapshot.canRebuild {
                                    Button {
                                        datasetManager.startIndexing(dataset: snapshot.dataset)
                                    } label: {
                                        Label(LocalizedStringKey("Rebuild Dataset Index"), systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 8)
                        } label: {
                            DatasetHealthDatasetLabel(snapshot: snapshot)
                        }
                    }
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Dataset Health"))
    }

    private func rebuildAllStaleDatasets() {
        for snapshot in staleSnapshots {
            datasetManager.startIndexing(dataset: snapshot.dataset)
        }
    }
}

private struct DatasetHealthSnapshot: Identifiable {
    let id: String
    let dataset: LocalDataset
    let status: DatasetProcessingStatus?
    let report: DatasetIndexReport?
    let metadata: DatasetIndexMetadata?
    let userFileCount: Int
    let supportedFileCount: Int
    let unsupportedFileCount: Int
    let vectorDimension: Int?
    let issues: [DatasetHealthIssue]

    var state: DatasetHealthState {
        if status?.stage == .failed || issues.contains(where: { $0.severity == .failed }) {
            return .failed
        }
        if status?.stage == .embedding || status?.stage == .extracting || status?.stage == .compressing {
            return .indexing
        }
        if !issues.isEmpty {
            return .warning
        }
        return .ready
    }

    var canRebuild: Bool {
        guard state != .indexing else { return false }
        return dataset.requiresReindex ||
            !dataset.isIndexed ||
            issues.contains { issue in
                issue.kind == .staleIndex ||
                    issue.kind == .failedIndex ||
                    issue.kind == .emptyIndex ||
                    issue.kind == .missingVectors
            }
    }

    static func snapshots(for datasets: [LocalDataset], statuses: [String: DatasetProcessingStatus]) -> [Self] {
        datasets
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { dataset in
                DatasetHealthSnapshot(dataset: dataset, status: statuses[dataset.datasetID])
            }
    }

    init(dataset: LocalDataset, status: DatasetProcessingStatus?) {
        self.id = dataset.datasetID
        self.dataset = dataset
        self.status = status
        self.report = DatasetIndexIO.loadReport(from: dataset.url)
        self.metadata = DatasetIndexIO.loadMetadata(from: dataset.url)
        self.vectorDimension = DatasetIndexIO.firstVectorDimension(at: dataset.url)

        let fileSummary = Self.fileSummary(for: dataset)
        self.userFileCount = fileSummary.total
        self.supportedFileCount = fileSummary.supported
        self.unsupportedFileCount = fileSummary.unsupported

        self.issues = Self.issues(
            dataset: dataset,
            status: status,
            report: report,
            metadata: metadata,
            vectorDimension: vectorDimension,
            fileSummary: fileSummary
        )
    }

    private static func fileSummary(for dataset: LocalDataset) -> (total: Int, supported: Int, unsupported: Int) {
        let fm = FileManager.default
        var total = 0
        var supported = 0
        var unsupported = 0

        if let enumerator = fm.enumerator(at: dataset.url, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let url = enumerator.nextObject() as? URL {
                let relativePath = DatasetPathing.relativePath(for: url, under: dataset.url)
                if DatasetStorage.isInternalRelativePath(relativePath) { continue }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else {
                    continue
                }
                total += 1
                if DatasetFileSupport.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    supported += 1
                } else {
                    unsupported += 1
                }
            }
        }

        return (total, supported, unsupported)
    }

    private static func issues(
        dataset: LocalDataset,
        status: DatasetProcessingStatus?,
        report: DatasetIndexReport?,
        metadata: DatasetIndexMetadata?,
        vectorDimension: Int?,
        fileSummary: (total: Int, supported: Int, unsupported: Int)
    ) -> [DatasetHealthIssue] {
        var issues: [DatasetHealthIssue] = []
        let hasArtifacts = DatasetIndexIO.hasIndexArtifacts(at: dataset.url)
        let hasValidIndex = DatasetIndexIO.hasValidIndex(at: dataset.url)
        let expectedFingerprint = EmbeddingModelCatalog.currentIndexFingerprint()

        if status?.stage == .failed {
            issues.append(
                DatasetHealthIssue(
                    title: String(localized: "Indexing Failed"),
                    detail: status?.message ?? String(localized: "The latest indexing run failed."),
                    severity: .failed,
                    kind: .failedIndex
                )
            )
        }

        if let reason = report?.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            issues.append(
                DatasetHealthIssue(
                    title: String(localized: "Indexer Failure Reported"),
                    detail: reason,
                    severity: .failed,
                    kind: .failedIndex
                )
            )
        }

        if dataset.requiresReindex || (hasArtifacts && !hasValidIndex) {
            issues.append(
                DatasetHealthIssue(
                    title: String(localized: "Stale Embedding Index"),
                    detail: String(localized: "Existing vectors do not match the active embedding model or current index schema."),
                    severity: .warning,
                    kind: .staleIndex
                )
            )
        } else if !dataset.isIndexed && !hasArtifacts {
            issues.append(
                DatasetHealthIssue(
                    title: String(localized: "Not Indexed"),
                    detail: String(localized: "Build an embedding index before using semantic retrieval."),
                    severity: .warning,
                    kind: .missingVectors
                )
            )
        }

        if fileSummary.supported == 0 {
            issues.append(
                DatasetHealthIssue(
                    title: String(localized: "No Supported Source Files"),
                    detail: String(localized: "Add PDF, EPUB, text, Markdown, JSON, CSV, or TSV files."),
                    severity: .failed,
                    kind: .emptyIndex
                )
            )
        }

        if fileSummary.unsupported > 0 {
            issues.append(
                DatasetHealthIssue(
                    title: String(localized: "Unsupported Files Present"),
                    detail: String.localizedStringWithFormat(
                        String(localized: "%d files will be skipped by the indexer."),
                        fileSummary.unsupported
                    ),
                    severity: .warning,
                    kind: .unsupportedFiles
                )
            )
        }

        if let skipped = report?.skippedFiles.count, skipped > 0 {
            issues.append(
                DatasetHealthIssue(
                    title: String(localized: "Files Skipped During Indexing"),
                    detail: String.localizedStringWithFormat(
                        String(localized: "%d supported files were skipped in the latest report."),
                        skipped
                    ),
                    severity: .warning,
                    kind: .skippedFiles
                )
            )
        }

        if let empty = report?.emptyFiles.count, empty > 0 {
            issues.append(
                DatasetHealthIssue(
                    title: String(localized: "Empty Extracted Files"),
                    detail: String.localizedStringWithFormat(
                        String(localized: "%d files produced no retrievable text."),
                        empty
                    ),
                    severity: .warning,
                    kind: .emptyFiles
                )
            )
        }

        if let metadata {
            if metadata.schemaVersion != DatasetIndexMetadata.currentSchemaVersion {
                issues.append(
                    DatasetHealthIssue(
                        title: String(localized: "Old Index Schema"),
                        detail: String.localizedStringWithFormat(
                            String(localized: "Schema %@ should be rebuilt to %@."),
                            "\(metadata.schemaVersion)",
                            "\(DatasetIndexMetadata.currentSchemaVersion)"
                        ),
                        severity: .warning,
                        kind: .staleIndex
                    )
                )
            }
            if let indexFingerprint = metadata.embeddingFingerprint,
               indexFingerprint != expectedFingerprint {
                issues.append(
                    DatasetHealthIssue(
                        title: String(localized: "Embedding Model Changed"),
                        detail: String(localized: "Vectors were built with a different embedding model."),
                        severity: .warning,
                        kind: .staleIndex
                    )
                )
            }
        }

        if let vectorDimension, vectorDimension != expectedFingerprint.dimension {
            issues.append(
                DatasetHealthIssue(
                    title: String(localized: "Vector Dimension Mismatch"),
                    detail: String.localizedStringWithFormat(
                        String(localized: "Vectors are %d dimensions; active embedding model expects %d."),
                        vectorDimension,
                        expectedFingerprint.dimension
                    ),
                    severity: .failed,
                    kind: .staleIndex
                )
            )
        }

        return issues
    }
}

private struct DatasetHealthIssue: Identifiable {
    enum Kind: Equatable {
        case general
        case staleIndex
        case failedIndex
        case emptyIndex
        case missingVectors
        case unsupportedFiles
        case skippedFiles
        case emptyFiles
    }

    let id = UUID()
    let title: String
    let detail: String
    let severity: DatasetHealthSeverity
    var kind: Kind = .general
}

private enum DatasetHealthState: Equatable {
    case ready
    case warning
    case failed
    case indexing

    var title: LocalizedStringKey {
        switch self {
        case .ready: return "Ready"
        case .warning: return "Warning"
        case .failed: return "Failed"
        case .indexing: return "Indexing"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .warning: return .orange
        case .failed: return .red
        case .indexing: return .blue
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .indexing: return "arrow.triangle.2.circlepath"
        }
    }
}

private enum DatasetHealthSeverity: Equatable {
    case ready
    case warning
    case failed

    var tint: Color {
        switch self {
        case .ready: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

private struct DatasetHealthDatasetLabel: View {
    let snapshot: DatasetHealthSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: snapshot.state.systemImage)
                .foregroundStyle(snapshot.state.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: snapshot.dataset.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: "\(snapshot.dataset.source) · \(snapshot.supportedFileCount)/\(snapshot.userFileCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(snapshot.state.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(snapshot.state.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(snapshot.state.tint.opacity(0.12), in: Capsule())
        }
    }
}

private struct DatasetHealthMetricsView: View {
    let snapshot: DatasetHealthSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DatasetHealthPill(title: LocalizedStringKey("Files"), value: "\(snapshot.userFileCount)")
                DatasetHealthPill(title: LocalizedStringKey("Supported"), value: "\(snapshot.supportedFileCount)")
                DatasetHealthPill(title: LocalizedStringKey("Unsupported"), value: "\(snapshot.unsupportedFileCount)")
            }
            HStack(spacing: 8) {
                DatasetHealthPill(title: LocalizedStringKey("Chunks"), value: "\(snapshot.metadata?.chunkCount ?? 0)")
                DatasetHealthPill(title: LocalizedStringKey("Schema"), value: "\(snapshot.metadata?.schemaVersion ?? 0)")
                DatasetHealthPill(title: LocalizedStringKey("Vector Dim"), value: "\(snapshot.vectorDimension ?? 0)")
            }
        }
    }
}

private struct DatasetHealthIssueRow: View {
    let issue: DatasetHealthIssue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.severity.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(issue.severity.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: issue.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(verbatim: issue.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DatasetHealthPill: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}
