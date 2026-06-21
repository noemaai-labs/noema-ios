// DownloadListPopup.swift
import SwiftUI

struct DownloadListPopup: View {
    @EnvironmentObject var controller: DownloadController
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
            && controller.leapItems.isEmpty
            && controller.datasetItems.isEmpty
            && controller.embeddingItems.isEmpty
            && controller.whisperItems.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(controller.items) { item in
                                row(for: item)
                            }
                            ForEach(controller.leapItems) { item in
                                leapRow(for: item)
                            }
                            ForEach(controller.datasetItems) { item in
                                datasetRow(for: item)
                            }
                            ForEach(controller.embeddingItems) { item in
                                embeddingRow(for: item)
                            }
                            ForEach(controller.whisperItems) { item in
                                whisperRow(for: item)
                            }
                            Text(LocalizedStringKey("Downloads continue on iPhone and iPad while Noema remains available in the background. Force-quitting the app stops automatic resume."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                }
            }
            .animation(.default, value: isEmpty)
            .navigationTitle("Downloads")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } } }
        }
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
            percent: percent(item.progress),
            speed: speedText(item.speed),
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
    private func leapRow(for item: DownloadController.LeapItem) -> some View {
        DownloadRowCard(
            title: item.entry.displayName,
            subtitle: item.entry.slug,
            progress: item.progress,
            statusKey: item.status.statusLabelKey,
            percent: percent(item.progress),
            speed: speedText(item.speed),
            bytes: byteLine(written: estimatedWritten(progress: item.progress, expected: item.expectedBytes), expected: item.expectedBytes),
            canResume: item.canResume,
            canPause: item.canPause,
            canSchedule: item.canPause && item.status != .scheduled,
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
            percent: percent(progress),
            speed: speedText(item.speed),
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
            percent: percent(item.progress),
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
            percent: percent(item.progress),
            speed: speedText(item.speed),
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

    private func speedText(_ speed: Double) -> String? {
        guard speed > 0 else { return nil }
        let kb = speed / 1024
        if kb > 1024 { return String(format: "%.1f MB/s", kb / 1024) }
        return String(format: "%.0f KB/s", kb)
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

    private func percent(_ progress: Double) -> Int {
        Int((clamped(progress) * 100).rounded())
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
    let percent: Int
    var speed: String? = nil
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

            ProgressView(value: clampedProgress)
                .tint(.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                if let error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    statusLine
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let bytes {
                    Text(bytes)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if canResume {
                Button(action: resume) {
                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Resume Download"))
            } else if canPause {
                Button(action: pause) {
                    Image(systemName: "pause.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Pause Download"))
            }

            if canSchedule {
                Button(action: schedule) {
                    Image(systemName: "clock.badge.pause")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Schedule Download"))
            }

            Button {
                if requiresStopConfirmation {
                    confirmStop = true
                } else {
                    cancel()
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LocalizedStringKey("Stop Download"))
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
        .foregroundStyle(Color.accentColor)
    }

    /// Confirm before discarding partial data; completed or failed rows can be dismissed directly.
    private var requiresStopConfirmation: Bool {
        error == nil && statusKey != DownloadJobState.completed.statusLabelKey
    }

    private var statusLine: Text {
        var text = Text(LocalizedStringKey(statusKey)) + Text("  \(percent)%")
        if let speed, !speed.isEmpty {
            text = text + Text("  \(speed)")
        }
        return text
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var isScheduled: Bool {
        statusKey == DownloadJobState.scheduled.statusLabelKey
    }
}
