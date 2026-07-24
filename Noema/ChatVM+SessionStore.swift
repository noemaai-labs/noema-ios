import SwiftUI
import Foundation
import RelayKit
import Combine
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import NoemaPackages
#if canImport(MLX)
import MLX
#endif

#if canImport(UIKit) || os(macOS)
extension ChatVM {
    static func sessionsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions.json")
    }

    private static let attachmentCleanupLastRunKey = "chatAttachmentCleanupLastRun"

    static func attachmentStorageDirectory() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatAttachments", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func legacyTemporaryAttachmentDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("noema_images", isDirectory: true)
    }

    @discardableResult
    func migrateLegacyAttachmentPathsIfNeeded() -> Bool {
        let fm = FileManager.default
        let legacyDir = Self.legacyTemporaryAttachmentDirectory().standardizedFileURL.path
        let persistentDirURL = Self.attachmentStorageDirectory().standardizedFileURL
        let legacyPrefix = legacyDir.hasSuffix("/") ? legacyDir : (legacyDir + "/")

        var updatedSessions = sessions
        var changed = false

        for sIdx in updatedSessions.indices {
            for mIdx in updatedSessions[sIdx].messages.indices {
                guard var paths = updatedSessions[sIdx].messages[mIdx].imagePaths, !paths.isEmpty else { continue }
                var messageChanged = false

                for pIdx in paths.indices {
                    let sourceURL = URL(fileURLWithPath: paths[pIdx]).standardizedFileURL
                    let sourcePath = sourceURL.path
                    guard sourcePath == legacyDir || sourcePath.hasPrefix(legacyPrefix) else { continue }

                    let destinationURL = persistentDirURL.appendingPathComponent(sourceURL.lastPathComponent)
                    let destinationPath = destinationURL.path
                    guard sourcePath != destinationPath else { continue }

                    if fm.fileExists(atPath: sourcePath) {
                        if !fm.fileExists(atPath: destinationPath) {
                            do {
                                try fm.copyItem(at: sourceURL, to: destinationURL)
                            } catch {
                                continue
                            }
                        }
                        paths[pIdx] = destinationPath
                        messageChanged = true
                    } else if fm.fileExists(atPath: destinationPath) {
                        paths[pIdx] = destinationPath
                        messageChanged = true
                    }
                }

                if messageChanged {
                    updatedSessions[sIdx].messages[mIdx].imagePaths = paths
                    changed = true
                }
            }
        }

        guard changed else { return false }
        sessions = updatedSessions
        return true
    }

    private var attachmentCleanupPolicy: ChatAttachmentCleanupPolicy {
        ChatAttachmentCleanupPolicy.from(attachmentCleanupPolicyRaw)
    }

    private static func normalizedAttachmentPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func isPath(_ path: String, inside directory: URL) -> Bool {
        let normalizedPath = normalizedAttachmentPath(path)
        let normalizedDirectory = directory.standardizedFileURL.path
        let prefix = normalizedDirectory.hasSuffix("/") ? normalizedDirectory : (normalizedDirectory + "/")
        return normalizedPath == normalizedDirectory || normalizedPath.hasPrefix(prefix)
    }

    private static func isManagedAttachmentPath(_ path: String) -> Bool {
        isPath(path, inside: attachmentStorageDirectory()) || isPath(path, inside: legacyTemporaryAttachmentDirectory())
    }

    private func referencedAttachmentPaths(excludingSessionID: Session.ID? = nil) -> Set<String> {
        var refs = Set<String>()
        for session in sessions {
            if let excludingSessionID, session.id == excludingSessionID { continue }
            for message in session.messages {
                for path in message.imagePaths ?? [] {
                    refs.insert(Self.normalizedAttachmentPath(path))
                }
                for attachment in message.mediaAttachments ?? [] {
                    refs.insert(Self.normalizedAttachmentPath(attachment.storedPath))
                    if let sidecar = attachment.transcriptSidecarPath {
                        refs.insert(Self.normalizedAttachmentPath(sidecar))
                    }
                }
            }
        }
        return refs
    }

    @discardableResult
    private func deleteAttachmentFiles(atPaths paths: Set<String>, reason: String) -> Int {
        let fm = FileManager.default
        var removed = 0

        for rawPath in paths {
            let path = Self.normalizedAttachmentPath(rawPath)
            guard Self.isManagedAttachmentPath(path) else { continue }
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: path) else { continue }
            do {
                try fm.removeItem(at: url)
                pendingImageURLs.removeAll { Self.normalizedAttachmentPath($0.path) == path }
                pendingMediaAttachments.removeAll { attachment in
                    Self.normalizedAttachmentPath(attachment.storedPath) == path
                        || attachment.transcriptSidecarPath.map { Self.normalizedAttachmentPath($0) == path } == true
                }
                pendingThumbnails = pendingThumbnails.filter { Self.normalizedAttachmentPath($0.key.path) != path }
                ImageThumbnailCache.shared.clear(for: path)
                removed += 1
            } catch {
                continue
            }
        }

        if removed > 0 {
            Task { await logger.log("[Images][Cleanup] removed=\(removed) reason=\(reason)") }
        }
        return removed
    }

    private func periodicAttachmentCleanupInterval(for policy: ChatAttachmentCleanupPolicy) -> TimeInterval? {
        switch policy {
        case .immediate, .daily:
            return 60 * 60 * 24
        case .weekly:
            return 60 * 60 * 24 * 7
        case .never:
            return nil
        }
    }

    @discardableResult
    func garbageCollectAttachmentFilesIfNeeded(force: Bool) -> Int {
        let policy = attachmentCleanupPolicy
        guard force || policy != .never else { return 0 }

        if !force {
            guard let interval = periodicAttachmentCleanupInterval(for: policy) else { return 0 }
            if let lastRun = UserDefaults.standard.object(forKey: Self.attachmentCleanupLastRunKey) as? Date,
               Date().timeIntervalSince(lastRun) < interval {
                return 0
            }
        }

        let fm = FileManager.default
        let referenced = referencedAttachmentPaths()
        let directories = [Self.attachmentStorageDirectory(), Self.legacyTemporaryAttachmentDirectory()]
        var candidates = Set<String>()

        for directory in directories {
            guard fm.fileExists(atPath: directory.path) else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files {
                let isRegular = (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? true
                guard isRegular else { continue }
                let path = Self.normalizedAttachmentPath(file.path)
                if !referenced.contains(path) {
                    candidates.insert(path)
                }
            }
        }

        let removed = deleteAttachmentFiles(atPaths: candidates, reason: "periodic-gc:\(policy.rawValue)")
        UserDefaults.standard.set(Date(), forKey: Self.attachmentCleanupLastRunKey)
        return removed
    }

    func runAttachmentGarbageCollectionNow() {
        _ = garbageCollectAttachmentFilesIfNeeded(force: true)
    }

    /// Debounce state for `saveSessions`. The `sessions` `didSet` fires on every mutation,
    /// including the ~10 Hz streaming checkpoint, and the persist path encodes the *entire*
    /// session history and writes it to disk synchronously on the MainActor (plus rebuilds the
    /// Spotlight index over all sessions). At 10 Hz during generation this was a measurable
    /// source of UI hitching that grew with history size.
    private static let sessionsSaveMinInterval: Duration = .milliseconds(750)

    func saveSessions() {
        // Coalesce rapid mutations into at most one encode+write per `sessionsSaveMinInterval`.
        // A trailing flush guarantees the final state is always persisted.
        let now = ContinuousClock().now
        if let last = lastSessionsSaveAt, now - last < Self.sessionsSaveMinInterval {
            guard !pendingSessionsSave else { return }
            pendingSessionsSave = true
            let delay = Self.sessionsSaveMinInterval - (now - last)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self else { return }
                self.pendingSessionsSave = false
                self.flushSaveSessions()
            }
            return
        }
        flushSaveSessions()
    }

    func flushSaveSessions() {
        lastSessionsSaveAt = ContinuousClock().now
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: Self.sessionsURL(), options: .atomic)
        }
        scheduleSpotlightChatTitleIndex()
    }

    /// Persist the latest session state immediately, bypassing the coalescing delay.
    /// Call on scene-phase `.background` / termination so a mutation made within the
    /// coalescing window isn't lost if the app is suspended or killed before the
    /// trailing delayed save fires.
    func flushPendingSessionSavesNow() {
        pendingSessionsSave = false
        flushSaveSessions()
    }

    func persistRollingThoughtsNow() {
        let keys = Array(rollingThoughtViewModels.keys)
        UserDefaults.standard.set(keys, forKey: "RollingThought.Keys")
        for (key, vm) in rollingThoughtViewModels {
            vm.saveState(forKey: "RollingThought." + key)
        }
    }

    func scheduleSpotlightChatTitleIndex() {
        let records = sessions.map { session in
            let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmedTitle.isEmpty ? String(localized: "New chat") : trimmedTitle
            return NoemaSpotlightIndexRecord(
                uniqueIdentifier: NoemaSpotlightIndexingService.chatIdentifier(for: session.id),
                title: title,
                contentDescription: String(localized: "Noema chat"),
                keywords: ["Noema", "chat"]
            )
        }
        NoemaSpotlightIndexingService.shared.scheduleChatTitleIndex(records: records)
    }

    func syncModelManagerDatasetForActiveSession() {
        guard let modelManager else { return }
        let target = activeSessionDatasetAny
        if modelManager.activeDataset?.datasetID != target?.datasetID {
            modelManager.setActiveDataset(target)
        }
        currentDocumentAccessStrategy = target == nil ? .none : .context
        refreshPDFToolPresence()
        if target != nil {
            AutopilotAFMBrain.prewarmForLikelyUse()
        } else {
            AutopilotAFMBrain.syncWarmState(armed: modelManager.autoRoutingArmed)
        }
    }

    func refreshSystemPromptForActiveSession(historyOverride: [Msg]? = nil) {
        // The system prompt is changing, so the cached context-meter overhead
        // (which is derived from it) is no longer valid.
        promptOverheadCache = nil
        guard let idx = activeIndex, sessions.indices.contains(idx) else {
            memoryPromptBudgetStatus = .inactive
            return
        }
        let context = resolvedSystemPromptContext(
            using: activeSessionPromptDataset,
            history: historyOverride ?? sessions[idx].messages
        )
        memoryPromptBudgetStatus = context.memoryPlan.status
        if let firstSystemIndex = sessions[idx].messages.firstIndex(where: { $0.role.lowercased() == "system" }) {
            sessions[idx].messages[firstSystemIndex].text = context.text
        } else {
            sessions[idx].messages.insert(Msg(role: "system", text: context.text, timestamp: Date()), at: 0)
        }
    }

    func setDatasetForActiveSession(_ ds: LocalDataset?) {
        modelManager?.setActiveDataset(ds)
        if let idx = activeIndex, sessions.indices.contains(idx) {
            sessions[idx].datasetID = ds?.datasetID ?? ""
        }
        if let ds {
            ChatDatasetRecents.record(ds.datasetID)
            // Choosing a dataset is an intent to use it. Avoid the confusing state
            // where the dataset appears active while retrieval remains disabled.
            if !activeToolPermissions.datasetRetrieval {
                setToolPermissionForActiveSession(.datasetRetrieval, enabled: true)
            }
        }
        if ds == nil {
            currentInjectedTokenOverhead = 0
        }
        currentDocumentAccessStrategy = ds == nil ? .none : .context
        refreshPDFToolPresence()
        if ds != nil {
            AutopilotAFMBrain.prewarmForLikelyUse()
        } else {
            AutopilotAFMBrain.syncWarmState(armed: modelManager?.autoRoutingArmed)
        }
        refreshSystemPromptForActiveSession()
    }

    static func defaultTitle(date: Date = .now) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
    var activeIndex: Int? {
        guard let id = activeSessionID else { return nil }
        return sessions.firstIndex { $0.id == id }
    }

    /// The active conversation's start date (set once at creation, never bumped), used
    /// to freeze the system prompt's date line so it stays byte-identical across turns
    /// and the leading prompt prefix remains reusable by the KV cache. A fresh chat with
    /// no active session falls back to today.
    var conversationStartDate: Date {
        if let idx = activeIndex, sessions.indices.contains(idx) {
            return sessions[idx].date
        }
        return Date()
    }

    var activeToolPermissions: ChatToolPermissions {
        guard let idx = activeIndex, sessions.indices.contains(idx) else {
            return .allEnabled
        }
        return sessions[idx].toolPermissions ?? .allEnabled
    }

    var activeScratchpad: String {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return "" }
        return sessions[idx].scratchpad ?? ""
    }

    var activeChatInstructions: String {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return "" }
        return sessions[idx].chatInstructions ?? ""
    }

    var activeChatMode: ChatMode {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return .general }
        return sessions[idx].chatMode ?? .general
    }

    var activeAnswerStyle: AnswerStyle {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return .natural }
        return sessions[idx].answerStyle ?? .natural
    }


    func select(_ session: Session) {
        if session.id != activeSessionID, autoRoutingStage == .deciding {
            stop()
        }
        activeSessionID = session.id
        // Opportunistically clean up any expired on-the-spot attached documents.
        purgeExpiredAttachedDocuments()
    }

    func focus(onMessageWithID id: UUID) {
        spotlightMessageID = id
    }

    @discardableResult
    func branchSession(fromMessageID messageID: UUID) -> Session? {
        guard let sourceIndex = activeIndex,
              sessions.indices.contains(sourceIndex),
              let messageIndex = sessions[sourceIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }

        if autoRoutingStage == .deciding {
            stop()
        } else {
            cancelAutoRoutingTask(invalidateRun: true)
        }
        currentStreamTask?.cancel()
        cancelTurnScopedEscalationAndContinuation()
        gemmaAutoTemplated = false

        let source = sessions[sourceIndex]
        var branchedMessages = Array(source.messages.prefix(messageIndex + 1))
        if !branchedMessages.contains(where: { $0.role.lowercased() == "system" }) {
            branchedMessages.insert(Msg(role: "system", text: baselineSystemPromptText, timestamp: Date()), at: 0)
        }
        for index in branchedMessages.indices {
            branchedMessages[index].streaming = false
            branchedMessages[index].promptProcessing = nil
            branchedMessages[index].postToolWaiting = false
        }

        let sourceTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = Self.defaultTitle()
        let branchTitle = String.localizedStringWithFormat(
            String(localized: "Branch: %@"),
            sourceTitle.isEmpty ? fallbackTitle : sourceTitle
        )
        let branch = Session(
            title: branchTitle,
            messages: branchedMessages,
            date: Date(),
            datasetID: source.datasetID,
            toolPermissions: source.toolPermissions,
            scratchpad: source.scratchpad,
            chatMode: source.chatMode,
            answerStyle: source.answerStyle,
            chatInstructions: source.chatInstructions
        )

        sessions.insert(branch, at: 0)
        activeSessionID = branch.id
        injectionStage = .none
        injectionMethod = nil
        refreshSystemPromptForActiveSession()
        return branch
    }

    /// Starts a new chat while preserving an explicitly active dataset by default.
    /// The dataset still belongs to the new session; this only removes the repeated
    /// trip through Stored for consecutive chats about the same source.
    func startNewSession(carryingActiveDataset: Bool = true) {
        let inheritedDatasetID = carryingActiveDataset
            ? (activeSessionDatasetAny?.datasetID ?? "")
            : ""
        if autoRoutingStage == .deciding {
            stop()
        } else {
            cancelAutoRoutingTask(invalidateRun: true)
        }
        currentStreamTask?.cancel()
        cancelTurnScopedEscalationAndContinuation()
        gemmaAutoTemplated = false
        let system = Msg(role: "system", text: baselineSystemPromptText, timestamp: Date())
        let new = Session(
            title: "New chat",
            messages: [system],
            date: Date(),
            datasetID: inheritedDatasetID
        )
        sessions.insert(new, at: 0)
        activeSessionID = new.id
        injectionStage = .none
        injectionMethod = nil

        // Randomize the request-scoped seed per session without persisting it.
        sessionGenerationSeed = nil
        if let model = modelManager?.loadedModel {
            let settings = modelManager?.settings(for: model) ?? ModelSettings.default(for: model.format)
            if modelLoaded, model.format == .gguf {
                if let explicitSeed = settings.seed, explicitSeed != 0 {
                    sessionGenerationSeed = explicitSeed
                } else {
                    sessionGenerationSeed = Int.random(in: 1...999_999)
                }
            }
        }
    }

    func delete(_ session: Session) {
        if autoRoutingStage == .deciding {
            stop()
        } else {
            cancelAutoRoutingTask(invalidateRun: true)
        }
        currentStreamTask?.cancel()
        cancelTurnScopedEscalationAndContinuation()
        let deletedSessionPaths: Set<String> = Set(
            session.messages
                .compactMap(\.imagePaths)
                .flatMap { $0.map(Self.normalizedAttachmentPath) }
        )
        sessions.removeAll { $0.id == session.id }
        var banners = contextOverflowBanners
        banners.removeValue(forKey: session.id)
        contextOverflowBanners = banners
        conversationCompactionFailureNotices.removeValue(forKey: session.id)
        conversationCompactionFailureRecords.removeValue(forKey: session.id)
        conversationCompactionAttemptIDs.removeValue(forKey: session.id)
        if conversationCompactionInProgressSessionID == session.id {
            conversationCompactionInProgressSessionID = nil
        }
        if attachmentCleanupPolicy == .immediate {
            let stillReferenced = referencedAttachmentPaths()
            let orphaned = deletedSessionPaths.subtracting(stillReferenced)
            _ = deleteAttachmentFiles(atPaths: orphaned, reason: "chat-delete")
        }
        _ = garbageCollectAttachmentFilesIfNeeded(force: false)
        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
        }
    }

    func clearChatHistory() {
        if autoRoutingStage == .deciding {
            stop()
        } else {
            cancelAutoRoutingTask(invalidateRun: true)
        }
        currentStreamTask?.cancel()
        cancelTurnScopedEscalationAndContinuation()
        let existing = sessions
        for session in existing {
            delete(session)
        }
        if sessions.isEmpty {
            startNewSession(carryingActiveDataset: false)
        }
    }

    func toggleFavorite(_ session: Session) {
        guard let idx = sessions.firstIndex(of: session) else { return }
        sessions[idx].isFavorite.toggle()
    }
}
#endif
