import Foundation
import SwiftUI

@MainActor
final class EmbedModelInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading
        case verifying
        case installing
        case ready
        case failed(String)
    }

    @Published var progress: Double = 0
    @Published var state: State = .idle

    // Concurrent installIfNeeded calls (onboarding + DatasetManager auto-install)
    // share one install per destination: a second download racing the first over
    // the same staging path can fail and clean up the winner's freshly installed
    // file. Keyed by destination path; entries clear themselves on completion.
    private static var installsInFlight: [String: Task<Void, Error>] = [:]

    private let recordID: String?

    init(recordID: String? = nil) {
        self.recordID = recordID
        refreshStateFromDisk()
    }

    private var record: EmbeddingModelRecord {
        if let recordID, let record = EmbeddingModelCatalog.record(for: recordID) {
            return record
        }
        return EmbeddingModelCatalog.activeRecord()
    }

    func installIfNeeded() async {
        progress = 0
        state = .idle
        let record = self.record
        guard record.isInstallable,
              let artifact = record.primaryArtifact,
              let remoteURL = artifact.downloadURL else {
            state = .failed(record.gatingReason ?? "Embedding model is not available for download")
            notifyAvailabilityChanged(record.isInstalled)
            return
        }

        let destinationURL = artifact.localURL(recordID: record.id)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            state = .ready
            progress = 1
            notifyAvailabilityChanged(record.id == EmbeddingModelCatalog.activeRecord().id)
            return
        }
        state = .downloading
        let install: Task<Void, Error>
        if let inFlight = Self.installsInFlight[destinationURL.path] {
            install = inFlight
        } else {
            install = Task {
                defer { Self.installsInFlight[destinationURL.path] = nil }
                try await self.performInstall(record: record, artifact: artifact, remoteURL: remoteURL, destinationURL: destinationURL)
            }
            Self.installsInFlight[destinationURL.path] = install
        }
        do {
            try await install.value
            state = .ready
            progress = 1
            notifyAvailabilityChanged(record.id == EmbeddingModelCatalog.activeRecord().id)
        } catch {
            state = .failed(error.localizedDescription)
            notifyAvailabilityChanged(false)
        }
    }

    private func performInstall(record: EmbeddingModelRecord,
                                artifact: EmbeddingModelArtifact,
                                remoteURL: URL,
                                destinationURL: URL) async throws {
        // Stage next to the destination and only move a verified file into place:
        // refreshStateFromDisk treats any file at destinationURL as .ready, so a
        // corrupt download left there would block every future repair attempt.
        let stagingURL = destinationURL.appendingPathExtension("download")
        do {
            try FileManager.default.createDirectory(at: artifact.directoryURL(recordID: record.id), withIntermediateDirectories: true)
            try await BackgroundDownloadManager.shared.download(from: remoteURL, to: stagingURL, expectedSize: nil) { [weak self] p in
                // Progress callback may be non-async; hop to main safely.
                Task { @MainActor in self?.progress = p }
            }
            state = .verifying
            try verifyGGUF(at: stagingURL)
            state = .installing
            try atomicMove(from: stagingURL, to: destinationURL)
            let dest = destinationURL
            Task.detached { await logger.log("[EmbedInstaller] ✅ Embedding model downloaded and installed at: \(dest.path)") }
            UserDefaults.standard.set(true, forKey: "hasInstalledEmbedModel:\(dest.path)")
            Haptics.success()
        } catch {
            // Never touch destinationURL here: only verified files land there, and a
            // concurrent install may have just put one in place.
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Refresh the installer state based on whether the model file exists on disk.
    /// This does not initiate any downloads; it purely reflects current disk state.
    func refreshStateFromDisk() {
        let record = self.record
        if FileManager.default.fileExists(atPath: record.installedURL.path) {
            state = .ready
            progress = 1
            notifyAvailabilityChanged(record.id == EmbeddingModelCatalog.activeRecord().id)
        } else {
            state = .idle
            progress = 0
            notifyAvailabilityChanged(false)
        }
    }

    private func verifyGGUF(at url: URL) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let magic = try fh.read(upToCount: 4) ?? Data()
        guard magic.count == 4, let s = String(data: magic, encoding: .ascii), s == "GGUF" else {
            throw NSError(domain: "Noema", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid GGUF header"])
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? NSNumber, size.intValue < 1_000_000 {
            throw NSError(domain: "Noema", code: 3, userInfo: [NSLocalizedDescriptionKey: "File too small"])
        }
    }

    private func atomicMove(from: URL, to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: to.path) {
            try FileManager.default.removeItem(at: to)
        }
        try FileManager.default.moveItem(at: from, to: to)
    }

    private func notifyAvailabilityChanged(_ available: Bool) {
        NotificationCenter.default.post(
            name: .embeddingModelAvailabilityChanged,
            object: nil,
            userInfo: ["available": available, "recordID": record.id]
        )
    }
}
