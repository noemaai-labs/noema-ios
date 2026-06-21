import Foundation
import SwiftUI

enum SupportModelState: Equatable, Sendable {
    case ready
    case missing
    case downloading
    case paused
    case failed
    case incomplete

    var titleKey: String {
        switch self {
        case .ready: return "Ready"
        case .missing: return "Not Downloaded"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .failed: return "Failed"
        case .incomplete: return "Incomplete Download"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .missing: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .incomplete: return "wrench.and.screwdriver.fill"
        }
    }
}

struct SupportModelInventoryItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case speech
        case embedding
    }

    let id: String
    let kind: Kind
    let titleKey: String
    let displayName: String
    let detail: String
    let state: SupportModelState
    let progress: Double?
    let sizeBytes: Int64?
}

enum SupportModelInventory {
    static func speechItem(
        selectedEngineID: TranscriptionEngineID = TranscriptionSettings.selectedEngineID,
        whisperItems: [DownloadController.WhisperItem]
    ) -> SupportModelInventoryItem {
        let runtimeEngine = selectedEngineID.isLocalWhisper
            ? selectedEngineID
            : TranscriptionBackendFactory.preferredLocalWhisperEngineID()
        let runtime = WhisperModelCatalog.runtimeFormat(for: runtimeEngine) ?? .whisperKit
        let record = WhisperModelCatalog.activeRecord(for: runtimeEngine)
            ?? WhisperModelCatalog.record(for: "whisper-tiny")
        let downloadID = record.map {
            DownloadController.whisperExternalID(recordID: $0.id, runtime: runtime)
        }
        let downloadItem = downloadID.flatMap { id in whisperItems.first { $0.id == id } }
        let state = supportState(
            downloadState: downloadItem?.status,
            installState: record.map { WhisperModelCatalog.installationState(for: $0, runtime: runtime) } ?? .missing
        )
        let progress = downloadItem.map(\.progress)
        let sizeBytes = record?.artifact(for: runtime)?.sizeBytes
        let runtimeName = runtimeEngine.displayName
        return SupportModelInventoryItem(
            id: "support:speech",
            kind: .speech,
            titleKey: "Speech / ASR",
            displayName: record?.displayName ?? String(localized: "Local Whisper"),
            detail: runtimeName,
            state: state,
            progress: progress,
            sizeBytes: sizeBytes
        )
    }

    static func embeddingItem(
        embeddingItems: [DownloadController.EmbeddingItem]
    ) -> SupportModelInventoryItem {
        let record = EmbeddingModelCatalog.activeRecord()
        let downloadItem = embeddingItems.first { $0.id == record.id || $0.repoID == record.primaryArtifact?.repoID }
        let state = supportState(
            downloadState: downloadItem?.status,
            installed: record.isInstalled
        )
        return SupportModelInventoryItem(
            id: "support:embedding",
            kind: .embedding,
            titleKey: "Embeddings",
            displayName: record.displayName,
            detail: record.primaryArtifact?.quantization ?? record.sizeTier,
            state: state,
            progress: downloadItem.map(\.progress),
            sizeBytes: record.primaryArtifact?.sizeBytes
        )
    }

    static func supportState(
        downloadState: DownloadJobState?,
        installState: WhisperModelInstallState
    ) -> SupportModelState {
        if downloadState == .completed {
            switch installState {
            case .ready: return .ready
            case .missing: return .missing
            case .incomplete: return .incomplete
            }
        }
        if let mapped = supportState(for: downloadState) {
            return mapped
        }
        switch installState {
        case .ready: return .ready
        case .missing: return .missing
        case .incomplete: return .incomplete
        }
    }

    static func supportState(
        downloadState: DownloadJobState?,
        installed: Bool
    ) -> SupportModelState {
        if downloadState == .completed {
            return installed ? .ready : .missing
        }
        if let mapped = supportState(for: downloadState) {
            return mapped
        }
        return installed ? .ready : .missing
    }

    private static func supportState(for downloadState: DownloadJobState?) -> SupportModelState? {
        guard let downloadState else { return nil }
        switch downloadState {
        case .queued, .preparing, .downloading, .waitingForConnectivity, .retrying, .verifying, .finalizing:
            return .downloading
        case .scheduled, .paused:
            return .paused
        case .failed, .cancelled:
            return .failed
        case .completed:
            return .ready
        }
    }
}
