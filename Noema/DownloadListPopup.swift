import SwiftUI

struct DownloadListPopup: View {
    @EnvironmentObject var controller: DownloadController
    @ObservedObject private var presentationUpdates = DownloadPresentationUpdates.shared
    @Environment(\.dismiss) private var dismiss

    var onClose: (() -> Void)? = nil

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var isEmpty: Bool {
        controller.items.isEmpty
            && controller.datasetItems.isEmpty
            && controller.embeddingItems.isEmpty
            && controller.whisperItems.isEmpty
    }

    var body: some View {
#if os(macOS)
        // Chrome (title + close) comes from the MacModalHost card.
        content
#else
        NavigationStack {
            content
                .navigationTitle("Downloads")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } } }
        }
#endif
    }

    private var content: some View {
        Group {
            if isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: listSpacing) {
                        listRows
                        footerNote
                    }
                    .padding(.horizontal, listHorizontalPadding)
                    .padding(.vertical, 16)
                }
            }
        }
        .animation(.default, value: isEmpty)
    }

    private var listSpacing: CGFloat {
#if os(macOS)
        0
#else
        12
#endif
    }

    private var listHorizontalPadding: CGFloat {
#if os(macOS)
        24
#else
        20
#endif
    }

    @ViewBuilder
    private var listRows: some View {
#if os(macOS)
        if !controller.items.isEmpty {
            sectionHeader("Models")
        }
#endif
        ForEach(controller.items) { item in
            row(for: item)
        }
#if os(macOS)
        if !controller.datasetItems.isEmpty {
            sectionHeader("Datasets")
        }
#endif
        ForEach(controller.datasetItems) { item in
            datasetRow(for: item)
        }
#if os(macOS)
        if !controller.embeddingItems.isEmpty {
            sectionHeader("Embeddings")
        }
#endif
        ForEach(controller.embeddingItems) { item in
            embeddingRow(for: item)
        }
#if os(macOS)
        if !controller.whisperItems.isEmpty {
            sectionHeader("Speech / ASR")
        }
#endif
        ForEach(controller.whisperItems) { item in
            whisperRow(for: item)
        }
    }

#if os(macOS)
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        IndustrialSectionHeader(title)
            .padding(.top, 10)
    }
#endif

    private var footerNote: some View {
        Group {
#if os(macOS)
            Text("Downloads continue while Noema is running. Quitting the app pauses them; they resume on next launch.")
#elseif os(visionOS)
            Text("Downloads continue on Apple Vision Pro while Noema remains available in the background. Force-quitting the app stops automatic resume.")
#else
            Text("Downloads continue on iPhone and iPad while Noema remains available in the background. Force-quitting the app stops automatic resume.")
#endif
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(LocalizedStringKey("No Active Downloads"))
                .font(.headline)
            Text(LocalizedStringKey("Models and datasets you download will appear here."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: – Row view
    @ViewBuilder
    private func row(for item: DownloadController.Item) -> some View {
        let totalWritten = item.mainBytesWritten + item.mmprojBytesWritten + item.imatrixBytesWritten
        let totalExpected = item.mainExpectedBytes + item.mmprojSize + item.imatrixSize
        DownloadRowCard(
            title: prettyName(item.detail.id),
            subtitle: item.quant.label,
            progress: item.progress,
            statusKey: item.status.statusLabelKey,
            speed: item.speed,
            bytes: byteLine(written: totalWritten, expected: totalExpected),
            error: item.error?.localizedDescription,
            canResume: item.canResume,
            canPause: item.canPause && item.error == nil,
            canSchedule: item.canPause && item.error == nil && item.status != .scheduled,
            resume: { controller.resume(itemID: item.id) },
            pause: { controller.pause(itemID: item.id) },
            schedule: { controller.schedule(itemID: item.id) },
            cancel: { controller.cancel(itemID: item.id) }
        )
    }

    @ViewBuilder
    private func datasetRow(for item: DownloadController.DatasetItem) -> some View {
        let progress = item.expectedBytes > 0
            ? Double(item.downloadedBytes) / Double(item.expectedBytes)
            : item.progress
        DownloadRowCard(
            title: prettyName(item.detail.id),
            subtitle: item.detail.id,
            progress: progress,
            statusKey: item.status.statusLabelKey,
            speed: item.speed,
            bytes: byteLine(written: item.downloadedBytes, expected: item.expectedBytes),
            error: item.error?.localizedDescription,
            canResume: item.canResume,
            canPause: item.canPause,
            canSchedule: item.canPause && item.error == nil && item.status != .scheduled,
            resume: { controller.resume(itemID: item.id) },
            pause: { controller.pause(itemID: item.id) },
            schedule: { controller.schedule(itemID: item.id) },
            cancel: { controller.cancel(itemID: item.id) }
        )
    }

    @ViewBuilder
    private func embeddingRow(for item: DownloadController.EmbeddingItem) -> some View {
        DownloadRowCard(
            title: item.displayName,
            subtitle: item.repoID,
            progress: item.progress,
            statusKey: item.status.statusLabelKey,
            bytes: byteLine(written: estimatedWritten(progress: item.progress, expected: item.expectedBytes), expected: item.expectedBytes),
            error: item.error?.localizedDescription,
            canResume: item.canResume,
            canPause: item.canPause,
            canSchedule: item.canPause && item.error == nil && item.status != .scheduled,
            resume: { controller.resume(itemID: item.id) },
            pause: { controller.pause(itemID: item.id) },
            schedule: { controller.schedule(itemID: item.id) },
            cancel: { controller.cancel(itemID: item.id) }
        )
    }

    @ViewBuilder
    private func whisperRow(for item: DownloadController.WhisperItem) -> some View {
        DownloadRowCard(
            title: item.displayName,
            subtitle: item.repoID,
            progress: item.progress,
            statusKey: item.status.statusLabelKey,
            speed: item.speed,
            bytes: byteLine(written: item.downloadedBytes, expected: item.expectedBytes),
            error: item.error?.localizedDescription,
            canResume: item.canResume,
            canPause: item.canPause,
            canSchedule: item.canPause && item.error == nil && item.status != .scheduled,
            resume: { controller.resume(itemID: item.id) },
            pause: { controller.pause(itemID: item.id) },
            schedule: { controller.schedule(itemID: item.id) },
            cancel: { controller.cancel(itemID: item.id) }
        )
    }

    private func byteLine(written: Int64, expected: Int64) -> String? {
        guard written > 0 || expected > 0 else { return nil }
        let writtenText = ByteCountFormatter.string(fromByteCount: max(0, written), countStyle: .file)
        let expectedText = expected > 0
            ? ByteCountFormatter.string(fromByteCount: max(0, expected), countStyle: .file)
            : "--"
        return "\(writtenText) / \(expectedText)"
    }

    private func estimatedWritten(progress: Double, expected: Int64) -> Int64 {
        guard expected > 0 else { return 0 }
        return Int64(Double(expected) * clamped(progress))
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func prettyName(_ id: String) -> String {
        let base = id.split(separator: "/").last.map(String.init) ?? id
        var cleaned = base.replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?i)gguf", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?i)ggml", with: "", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }
}

private struct DownloadRowCard: View {
    let title: String
    let subtitle: String?
    let progress: Double
    let statusKey: String
    var speed: Double? = nil
    var bytes: String? = nil
    var error: String? = nil
    let canResume: Bool
    let canPause: Bool
    let canSchedule: Bool
    let resume: () -> Void
    let pause: () -> Void
    let schedule: () -> Void
    let cancel: () -> Void

    @State private var confirmStop = false

    var body: some View {
#if os(macOS)
        VStack(spacing: 0) {
            IndustrialHoverRow {
                rowContent
                    .padding(.vertical, 10)
            }
            IndustrialHairline()
        }
#else
        rowContent
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
#endif
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 0)
                controls
            }

            DownloadProgressCluster(
                progress: progress,
                speed: speed,
                statusKey: clusterStatusKey
            )

            if hasDetails {
                detailLines
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let bytes {
#if os(macOS)
                Text(bytes)
                    .industrialStat()
#else
                Text(bytes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
#endif
            }

            if isScheduled {
                Label(LocalizedStringKey("Starts overnight on Wi-Fi while charging."), systemImage: "moon.zzz.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasDetails: Bool {
        (error?.isEmpty == false) || bytes != nil || isScheduled
    }

    private var controls: some View {
        DownloadActionCluster(
            onResume: canResume ? resume : nil,
            onPause: (!canResume && canPause) ? pause : nil,
            onSchedule: canSchedule ? schedule : nil,
            onCancel: {
                if requiresStopConfirmation {
                    confirmStop = true
                } else {
                    cancel()
                }
            }
        )
        .confirmationDialog(
            Text(LocalizedStringKey("Stop this download?")),
            isPresented: $confirmStop,
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("Stop Download"), role: .destructive) { cancel() }
            Button(LocalizedStringKey("Keep Downloading"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("Partially downloaded data will be deleted."))
        }
    }

    /// Confirm before discarding partial data; completed or failed rows can be dismissed directly.
    private var requiresStopConfirmation: Bool {
        error == nil && statusKey != DownloadJobState.completed.statusLabelKey
    }

    private var clusterStatusKey: LocalizedStringKey? {
        statusKey == DownloadJobState.downloading.statusLabelKey
            ? nil
            : LocalizedStringKey(statusKey)
    }

    private var isScheduled: Bool {
        statusKey == DownloadJobState.scheduled.statusLabelKey
    }
}
