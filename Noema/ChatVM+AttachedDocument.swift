import Foundation

extension ChatVM {
    /// Document file extensions accepted by the composer drop-in.
    static let attachedDocumentExtensions: Set<String> = ["pdf", "epub", "txt", "md", "markdown", "json", "jsonl", "csv", "tsv"]

#if os(macOS)
    /// Materialize a resource response before sending it through the existing
    /// document import/indexing pipeline. Provenance is embedded in the snapshot
    /// and a sidecar so the attachment can be refreshed from its MCP origin.
    func attachMCPResourceSnapshot(serverID: String, uri: String, title: String, content: [MCPContent]) throws {
        let directory = MCPConfigurationStore.directory.appendingPathComponent("MCP/ResourceSnapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = title.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = (safeTitle.isEmpty ? "resource" : safeTitle) + "-" + String(MCPAlias.stableHash(serverID + "\u{0}" + uri).prefix(8))
        let snapshotURL = directory.appendingPathComponent(base).appendingPathExtension("md")
        let metadataURL = directory.appendingPathComponent(base).appendingPathExtension("mcp-resource.json")
        let body = content.map { item -> String in
            switch item {
            case .text(let value): value
            case .structured(let value): "```json\n\(value.prettyPrinted)\n```"
            case .image(_, let mime): "[MCP image: \(mime)]"
            case .audio(_, let mime): "[MCP audio: \(mime)]"
            case .embeddedResource(let resourceURI, _, let text, _): text ?? resourceURI
            case .resourceLink(let resourceURI, let name, _, _): "[\(name)](\(resourceURI))"
            }
        }.joined(separator: "\n\n")
        let snapshot = "---\nnoema_mcp_server: \(serverID)\nnoema_mcp_uri: \(uri)\nretrieved_at: \(ISO8601DateFormatter().string(from: Date()))\n---\n\n# \(title)\n\n\(body)\n"
        try Data(snapshot.utf8).write(to: snapshotURL, options: .atomic)
        let metadata: JSONValue = .object([
            "serverID": .string(serverID), "uri": .string(uri), "title": .string(title),
            "snapshot": .string(snapshotURL.path), "retrievedAt": .string(ISO8601DateFormatter().string(from: Date()))
        ])
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        attachDocument(urls: [snapshotURL])
    }
#endif

    /// Attach a document picked from Files: import → embed on the spot → arm for RAG.
    func attachDocument(urls: [URL]) {
        guard let datasetManager else { return }
        let docs = urls.filter { Self.attachedDocumentExtensions.contains($0.pathExtension.lowercased()) }
        guard let first = docs.first else { return }

        let files = docs.map {
            AttachedFile(name: $0.deletingPathExtension().lastPathComponent, isPDF: $0.pathExtension.lowercased() == "pdf")
        }
        let displayName = first.deletingPathExtension().lastPathComponent
        let isPDF = files.contains { $0.isPDF }
        let priorDatasetID = attachedDocument?.datasetID
        let stateID = UUID().uuidString
        attachedDocument = AttachedDocumentState(
            id: stateID,
            name: displayName,
            isPDF: isPDF,
            files: files,
            mode: .embedding,
            phase: .preparing,
            datasetID: nil,
            expiresAt: nil
        )
        refreshPDFToolPresence()

        Task { @MainActor in
            // 1. Copy the picked file(s) into a dataset on disk.
            guard let dataset = await datasetManager.importDocuments(from: docs, suggestedName: displayName) else {
                self.failAttachedDocument(stateID, message: String(localized: "Couldn't read that document.", locale: LocalizationManager.preferredLocale()))
                return
            }
            guard self.attachedDocument?.id == stateID else {
                EphemeralAttachedDocumentStore.removeNow(datasetID: dataset.datasetID)
                return
            }
            self.attachedDocument?.datasetID = dataset.datasetID
            if let priorDatasetID, priorDatasetID != dataset.datasetID {
                EphemeralAttachedDocumentStore.removeNow(datasetID: priorDatasetID)
            }

            // 2. Embed via the standard indexing path (downloads the embedding model
            //    if needed and publishes DatasetProcessingStatus). autoEmbed:true runs
            //    straight through to .completed instead of pausing at the embedding gate,
            //    so the wait loop below actually terminates and the PDF is RAG-ready.
            datasetManager.startIndexing(dataset: dataset, autoEmbed: true)

            // 3. Wait for indexing to terminate. The composer chip shows live progress by
            //    observing DatasetManager directly, so we only read status here to detect
            //    completion/failure — never mirror it into the @Published attachedDocument,
            //    which used to re-render the whole chat at 5Hz (the attached-PDF lag).
            let started = Date()
            var didComplete = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard self.attachedDocument?.id == stateID else {
                    EphemeralAttachedDocumentStore.removeNow(datasetID: dataset.datasetID)
                    return
                }
                if let status = datasetManager.processingStatus[dataset.datasetID] {
                    if status.stage == .completed { didComplete = true; break }
                    if status.stage == .failed {
                        self.failAttachedDocument(stateID, message: status.message ?? String(localized: "Couldn't index that document.", locale: LocalizationManager.preferredLocale()))
                        EphemeralAttachedDocumentStore.removeNow(datasetID: dataset.datasetID)
                        return
                    }
                }
                // Safety net so a stalled pipeline can't poll forever.
                if Date().timeIntervalSince(started) > 30 * 60 {
                    self.failAttachedDocument(stateID, message: String(localized: "Indexing took too long.", locale: LocalizationManager.preferredLocale()))
                    EphemeralAttachedDocumentStore.removeNow(datasetID: dataset.datasetID)
                    return
                }
            }
            guard didComplete, self.attachedDocument?.id == stateID else { return }

            // 4. Track expiry + arm as the chat's retrieval source. Reload from disk FIRST
            //    and arm inside the completion: `.completed` is published from prepare()'s
            //    progress callback, which races ahead of indexing's own (async) reloadFromDisk,
            //    so `datasets` can still be stale here. Looking up `armed` before the reload
            //    applies would return nil and silently leave the PDF un-armed for RAG.
            let record = EphemeralAttachedDocumentStore.register(datasetID: dataset.datasetID, name: displayName)
            datasetManager.reloadFromDisk { [weak self] in
                guard let self, self.attachedDocument?.id == stateID else { return }
                let armed = datasetManager.datasets.first { $0.datasetID == dataset.datasetID && $0.isIndexed }
                self.setToolPermissionForActiveSession(.datasetRetrieval, enabled: true)
                self.setDatasetForActiveSession(armed)
                self.attachedDocument?.phase = .ready
                self.attachedDocument?.expiresAt = record.expiresAt
                self.refreshPDFToolPresence()
                Task { await logger.log("[AttachedDoc] ready dataset=\(dataset.datasetID) armed=\(armed != nil)") }
            }
        }
    }

    /// Detach the current document and delete its vectors immediately.
    func removeAttachedDocument() {
        if let id = attachedDocument?.datasetID {
            EphemeralAttachedDocumentStore.removeNow(datasetID: id)
            if modelManager?.activeDataset?.datasetID == id {
                setDatasetForActiveSession(nil)
            }
            datasetManager?.reloadFromDisk()
        }
        attachedDocument = nil
        refreshPDFToolPresence()
    }

    /// Keep the PDF tool scoped to the active indexed chat dataset. A composer attachment
    /// becomes active when indexing completes, while a PDF selected from Stored reaches the
    /// same path directly. PDF navigation remains available when automatic RAG is disabled.
    func refreshPDFToolPresence() {
        let defaults = UserDefaults.standard
        // Once a turn starts, keep its dataset root latched even if the user
        // switches chats while the model is in a grep -> lines continuation.
        // This prevents a global preference update from crossing turn scopes.
        let scopedDataset: LocalDataset? = {
            if let streamSessionIndex,
               sessions.indices.contains(streamSessionIndex) {
                let session = sessions[streamSessionIndex]
                guard let dataset = datasetForSession(session),
                      dataset.isIndexed else { return nil }
                return dataset
            }
            guard let dataset = activeSessionDatasetAny, dataset.isIndexed else { return nil }
            return dataset
        }()
        guard let dataset = scopedDataset else {
            defaults.set(false, forKey: "pdfToolPresent")
            defaults.removeObject(forKey: "pdfToolActiveDatasetRoot")
            defaults.removeObject(forKey: "pdfToolPreferredDocuments")
            return
        }
        let pdfURLs = PDFDatasetAccess.pdfURLs(in: dataset.url)
        let present = !pdfURLs.isEmpty
        defaults.set(present, forKey: "pdfToolPresent")
        if present {
            defaults.set(dataset.url.standardizedFileURL.path, forKey: "pdfToolActiveDatasetRoot")
            defaults.set(
                pdfURLs.map(\.lastPathComponent).joined(separator: "\n"),
                forKey: "pdfToolPreferredDocuments"
            )
        } else {
            defaults.removeObject(forKey: "pdfToolActiveDatasetRoot")
            defaults.removeObject(forKey: "pdfToolPreferredDocuments")
        }
    }

    /// Capability snapshot used by the universal deterministic fallback and the
    /// optional AFM planner. No document content is included.
    func documentAccessContext(autopilotConfig: AutopilotConfig? = nil) -> DocumentAccessContext {
        guard let dataset = activeSessionDatasetAny, dataset.isIndexed else { return .none }
        let pdfNames = PDFDatasetAccess.pdfURLs(in: dataset.url).map(\.lastPathComponent)
        let defaults = UserDefaults.standard
        let masterEnabled = defaults.object(forKey: "pdfToolEnabled") as? Bool ?? true
        let policyAllows = EnterprisePolicyGate.allowsTool("noema.pdf.read")
        let pdfNavigationAvailable = !pdfNames.isEmpty && masterEnabled && policyAllows
        let currentSessionIsRemote = remoteService != nil || modelManager?.activeRemoteSession != nil
        let residentCanCallTools = currentSessionIsRemote
            || (supportsToolsFlag && loadedFormat != .afm)
        let localCanNavigate = pdfNavigationAvailable && residentCanCallTools
        let escalationCanNavigate: Bool = {
            guard pdfNavigationAvailable, let config = autopilotConfig else { return false }
            // Remote escalations receive the app's native tool specs. The second-local-model
            // escalation path is deliberately tool-free today.
            return config.escalationTarget == .remote
        }()
        return DocumentAccessContext(
            hasActiveDataset: true,
            datasetTitle: dataset.name,
            pdfNames: pdfNames,
            pdfNavigationAvailable: pdfNavigationAvailable,
            localCanNavigate: localCanNavigate,
            escalationCanNavigate: escalationCanNavigate,
            automaticContextAvailable: activeToolPermissions.datasetRetrieval
        )
    }

    /// Delete expired attached documents and unbind any session still pointing at one.
    /// Safe to call on launch / when opening a chat.
    func purgeExpiredAttachedDocuments() {
        let removed = EphemeralAttachedDocumentStore.purgeExpired()
        guard !removed.isEmpty else { return }
        if let active = modelManager?.activeDataset?.datasetID, removed.contains(active) {
            setDatasetForActiveSession(nil)
        }
        if let attached = attachedDocument?.datasetID, removed.contains(attached) {
            attachedDocument = nil
        }
        refreshPDFToolPresence()
        datasetManager?.reloadFromDisk()
    }

    private func failAttachedDocument(_ stateID: String, message: String) {
        guard attachedDocument?.id == stateID else { return }
        attachedDocument?.phase = .failed(message)
        refreshPDFToolPresence()
    }
}
