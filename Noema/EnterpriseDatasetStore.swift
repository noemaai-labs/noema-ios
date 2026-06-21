// EnterpriseDatasetStore.swift
// Governed company datasets live under Documents/LocalLLMDatasets/Enterprise/<id>/ so the
// existing DatasetManager scan and DatasetRetriever path reconstruction work unchanged:
// they surface as LocalDataset values with datasetID "Enterprise/<id>" and source "Enterprise".
// The directory is app-private (no UIFileSharingEnabled), excluded from backup, file-protected,
// and purged whenever the workspace connection ends.
import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted after a sync changes enterprise datasets on disk.
    /// userInfo["downloadedDatasetIDs"]: [String] of LocalDataset IDs that finished downloading.
    static let enterpriseDatasetsDidChange = Notification.Name("EnterpriseDatasetsDidChange")
}

actor EnterpriseDatasetStore {
    static let shared = EnterpriseDatasetStore()
    static let ownerDirectoryName = "Enterprise"
    /// Registered in DatasetStorage.internalFilenames so indexing/retrieval never sees it.
    private static let manifestFileName = DatasetStorage.enterpriseManifestFilename

    private let client: EnterpriseAPIClient

    init(client: EnterpriseAPIClient = .shared) {
        self.client = client
    }

    static var rootDirectory: URL {
        var url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url.appendPathComponent("LocalLLMDatasets", isDirectory: true)
        url.appendPathComponent(ownerDirectoryName, isDirectory: true)
        return url
    }

    private func directory(for manifest: EnterpriseDatasetManifest) -> URL {
        Self.rootDirectory.appendingPathComponent(manifest.enterpriseDatasetID, isDirectory: true)
    }

    private func ensureRoot() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Self.rootDirectory.path) else { return }
        try? fm.createDirectory(
            at: Self.rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var url = Self.rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func installedManifest(at dir: URL) -> EnterpriseDatasetManifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.manifestFileName)) else {
            return nil
        }
        return try? EnterprisePolicy.decoder().decode(EnterpriseDatasetManifest.self, from: data)
    }

    /// Reconcile local enterprise datasets with the server: refresh outdated versions of
    /// datasets the user already saved, and remove ones no longer allowed. New datasets
    /// are never auto-downloaded — saving to Stored is an explicit user action.
    func sync(
        manifests: [EnterpriseDatasetManifest],
        allowedDatasetIDs: Set<String>,
        downloadAllowed: Bool,
        deviceToken: String
    ) async {
        ensureRoot()
        let allowedManifests = manifests.filter { allowedDatasetIDs.contains($0.datasetID) }
        removeDatasets(notIn: Set(allowedManifests.map(\.enterpriseDatasetID)))

        var updatedIDs: [String] = []
        if downloadAllowed {
            for manifest in allowedManifests {
                let dir = directory(for: manifest)
                guard let installed = installedManifest(at: dir) else { continue }
                if installed.version >= manifest.version { continue }
                do {
                    try await download(manifest: manifest, to: dir, deviceToken: deviceToken)
                    updatedIDs.append(manifest.datasetID)
                } catch {
                    Task { await logger.log("[Enterprise] dataset update failed \(manifest.enterpriseDatasetID): \(error.localizedDescription)") }
                }
            }
        }
        await postChange(downloaded: updatedIDs)
    }

    /// Explicit "Save to Stored": download one dataset bundle and surface it to the
    /// existing dataset pipeline (DatasetManager picks it up via the notification and
    /// runs the normal post-download indexing).
    func install(manifest: EnterpriseDatasetManifest, deviceToken: String) async throws {
        ensureRoot()
        try await download(manifest: manifest, to: directory(for: manifest), deviceToken: deviceToken)
        await postChange(downloaded: [manifest.datasetID])
    }

    /// Remove a single saved dataset from this device (it stays available to re-save).
    func remove(enterpriseDatasetID: String) async {
        try? FileManager.default.removeItem(
            at: Self.rootDirectory.appendingPathComponent(enterpriseDatasetID, isDirectory: true)
        )
        await postChange(downloaded: [])
    }

    /// Download one file into a temporary location for QuickLook preview (sha-verified,
    /// never written into the dataset root, so it can't enter the RAG pipeline).
    func previewFile(
        manifest: EnterpriseDatasetManifest,
        file: EnterpriseDatasetFile,
        deviceToken: String
    ) async throws -> URL {
        let data = try await client.downloadDatasetFile(
            deviceToken: deviceToken,
            enterpriseDatasetID: manifest.enterpriseDatasetID,
            relPath: file.relPath
        )
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256.lowercased() else {
            throw EnterpriseAPIError.server(0, "Checksum mismatch for \(file.relPath)")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnterprisePreviews", isDirectory: true)
            .appendingPathComponent(manifest.enterpriseDatasetID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent((file.relPath as NSString).lastPathComponent)
        try data.write(to: url, options: [.atomic])
        return url
    }

    private func postChange(downloaded: [String]) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .enterpriseDatasetsDidChange,
                object: nil,
                userInfo: ["downloadedDatasetIDs": downloaded, "changed": true]
            )
        }
    }

    private func download(manifest: EnterpriseDatasetManifest, to dir: URL, deviceToken: String) async throws {
        let fm = FileManager.default
        // Stage into a temp dir; only swap in after every file verifies.
        let staging = Self.rootDirectory.appendingPathComponent(".staging-\(manifest.enterpriseDatasetID)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let files = try await client.fetchDatasetFiles(
            deviceToken: deviceToken,
            enterpriseDatasetID: manifest.enterpriseDatasetID
        )
        for file in files {
            let data = try await client.downloadDatasetFile(
                deviceToken: deviceToken,
                enterpriseDatasetID: manifest.enterpriseDatasetID,
                relPath: file.relPath
            )
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == file.sha256.lowercased() else {
                throw EnterpriseAPIError.server(0, "Checksum mismatch for \(file.relPath)")
            }
            let safeName = (file.relPath as NSString).lastPathComponent
            try data.write(
                to: staging.appendingPathComponent(safeName),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }

        // Dataset display name for the existing dataset UI (DatasetIndexIO.titleURL).
        let titleURL = DatasetIndexIO.titleURL(for: staging)
        try? manifest.name.data(using: .utf8)?.write(to: titleURL)
        if let manifestData = try? EnterprisePolicy.encoder().encode(manifest) {
            try? manifestData.write(to: staging.appendingPathComponent(Self.manifestFileName), options: [.atomic])
        }

        try? fm.removeItem(at: dir)
        try fm.moveItem(at: staging, to: dir)
    }

    /// Remove enterprise dataset directories whose enterpriseDatasetID is not in `keep`.
    func removeDatasets(notIn keep: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Self.rootDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }
        for entry in entries where !keep.contains(entry.lastPathComponent) {
            try? fm.removeItem(at: entry)
        }
    }

    /// Installed manifest metadata (name/version) for chat grounding and the settings UI.
    func installedManifests() -> [EnterpriseDatasetManifest] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Self.rootDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }
        return entries.compactMap { installedManifest(at: $0) }
    }

    /// "Keep datasets" on leave (dataset-only workspaces): move each saved company
    /// dataset into the Imported owner so it becomes a personal dataset. Index
    /// artifacts live inside the dataset directory, so RAG keeps working; the
    /// governance manifest is stripped.
    func rehomeAllToImported() async {
        let fm = FileManager.default
        var importedBase = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        importedBase.appendPathComponent("LocalLLMDatasets", isDirectory: true)
        importedBase.appendPathComponent("Imported", isDirectory: true)
        try? fm.createDirectory(at: importedBase, withIntermediateDirectories: true)

        if let entries = try? fm.contentsOfDirectory(
            at: Self.rootDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            for entry in entries {
                let manifest = installedManifest(at: entry)
                let baseName = (manifest?.name ?? entry.lastPathComponent)
                    .replacingOccurrences(of: "/", with: "-")
                var destination = importedBase.appendingPathComponent(baseName, isDirectory: true)
                var suffix = 2
                while fm.fileExists(atPath: destination.path) {
                    destination = importedBase.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
                    suffix += 1
                }
                try? fm.removeItem(at: entry.appendingPathComponent(Self.manifestFileName))
                try? fm.moveItem(at: entry, to: destination)
            }
        }
        try? fm.removeItem(at: Self.rootDirectory)
        await postChange(downloaded: [])
    }

    /// Wipe everything on disconnect/revocation.
    func purgeAll() {
        try? FileManager.default.removeItem(at: Self.rootDirectory)
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .enterpriseDatasetsDidChange,
                object: nil,
                userInfo: ["downloadedDatasetIDs": [String](), "changed": true]
            )
        }
    }
}
