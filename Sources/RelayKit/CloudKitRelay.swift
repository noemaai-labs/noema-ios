import CloudKit
import Foundation

public final class CloudKitRelay: @unchecked Sendable {
    public static let shared = CloudKitRelay()

    private init() {}

    private var container: CKContainer?
    private var db: CKDatabase?
    private var provider: InferenceProvider = EchoProvider()
    private var subscriptionID = "conversation-updates"
    private var fallbackPollTask: Task<Void, Never>?
    private let fallbackPollIntervalNanoseconds: UInt64 = 3_000_000_000 // 3 seconds
    private let pollGate = AsyncSemaphore(value: 1) // serialize CloudKit polls
    private var lastPollingErrorMessage: String?
    private var lastPollingErrorDate: Date?
    private let pollingErrorThrottle: TimeInterval = 30

    // Bounded background processing
    private var workers = AsyncSemaphore(value: RelayPerformanceConfig.workerCount())
    private let inFlight = InFlightTracker<String>()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    deinit {
        fallbackPollTask?.cancel()
    }

    public func configure(containerIdentifier: String, provider: InferenceProvider? = nil) {
        guard !containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        stopServerProcessing()
        let container = CKContainer(identifier: containerIdentifier)
        self.container = container
        db = container.privateCloudDatabase
        if let provider { self.provider = provider }
        log("Configured CloudKit container \(containerIdentifier)")
    }

    public func postFromiOS(_ env: RelayEnvelope) async throws {
        guard let db else { throw InferenceError.notConfigured }
        log("Posting envelope for conversation \(env.conversationID.uuidString) needsResponse=\(env.needsResponse)")
        let recordID = CKRecord.ID(recordName: env.conversationID.uuidString)
        let record = try await fetchOrMakeRecord(id: recordID, database: db)
        record["conversationData"] = try encoder.encode(env) as CKRecordValue
        record["lastUpdated"] = Date() as CKRecordValue
        record["needsResponse"] = NSNumber(value: env.needsResponse ? 1 : 0)
        record["status"] = env.status.rawValue as CKRecordValue
        record["conversationIDString"] = env.conversationID.uuidString as CKRecordValue
        if let updatedAt = env.statusUpdatedAt {
            record["statusUpdatedAt"] = updatedAt as CKRecordValue
        } else {
            record["statusUpdatedAt"] = nil
        }
        if let errorMessage = env.errorMessage {
            record["errorMessage"] = errorMessage as CKRecordValue
        } else {
            record["errorMessage"] = nil
        }
        try await save(record, database: db)
        log("Posted envelope for conversation \(env.conversationID.uuidString)")
    }

    public func fetchEnvelope(conversationID: UUID) async throws -> RelayEnvelope? {
        guard let db else { throw InferenceError.notConfigured }
        let uuidString = conversationID.uuidString
        // Use CKQuery to bypass local CloudKit cache and always fetch from
        // the server. The convenience db.record(for:) can return a stale
        // cached record when another device (the Mac) updated it.
        let predicate = NSPredicate(format: "conversationIDString == %@", uuidString)
        let query = CKQuery(recordType: "Conversation", predicate: predicate)
        do {
            // This runs on a sub-second poll, so only pull the one field we
            // decode and cap to a single record to minimize latency/payload.
            let (matchResults, _) = try await db.records(matching: query,
                                                         desiredKeys: ["conversationData"],
                                                         resultsLimit: 1)
            if let (_, result) = matchResults.first {
                let record = try result.get()
                guard let data = record["conversationData"] as? Data else { return nil }
                let envelope = try decoder.decode(RelayEnvelope.self, from: data)
                log("Fetched envelope for conversation \(uuidString) status=\(envelope.status.rawValue) needsResponse=\(envelope.needsResponse) messages=\(envelope.messages.count)")
                return envelope
            }
            // Query returned no results — the conversationIDString index may
            // not be ready yet (first run). Fall back to a direct record fetch
            // which may be cached but is better than returning nil.
            let recordID = CKRecord.ID(recordName: uuidString)
            let record = try await db.record(for: recordID)
            guard let data = record["conversationData"] as? Data else { return nil }
            let envelope = try decoder.decode(RelayEnvelope.self, from: data)
            log("Fetched envelope (fallback) for conversation \(uuidString) status=\(envelope.status.rawValue) needsResponse=\(envelope.needsResponse) messages=\(envelope.messages.count)")
            return envelope
        } catch let error as CKError where error.code == .unknownItem {
            log("No envelope exists for conversation \(uuidString)")
            return nil
        }
    }

    public func startServerProcessing() async {
        guard db != nil else { return }
        await ensureSubscription()
        // Start once immediately to catch any queued work, but rely primarily
        // on push notifications and explicit triggers instead of tight polling.
        await requestPoll(reason: "initial-start")
        startFallbackPolls()
    }

    public func handleRemoteNotification() async {
        log("Received CloudKit push notification; triggering poll")
        await requestPoll(reason: "push")
    }

    public func stopServerProcessing() {
        fallbackPollTask?.cancel()
        fallbackPollTask = nil
        log("Stopped CloudKit relay processing")
    }

    /// Reloads performance-related configuration (e.g., worker count) and
    /// restarts the polling loop if it was previously active.
    public func reloadPerformanceConfig() async {
        let wasRunning = fallbackPollTask != nil && !(fallbackPollTask?.isCancelled ?? true)
        stopServerProcessing()
        workers = AsyncSemaphore(value: RelayPerformanceConfig.workerCount())
        if wasRunning {
            await startServerProcessing()
        }
    }

    private func requestPoll(reason: String) async {
        // Serialize CloudKit queries to avoid overlapping fetch storms.
        await pollGate.acquire()
        defer { Task { await pollGate.release() } }
        log("Polling CloudKit (\(reason))")
        await pollAndProcessOnce()
    }

    private func startFallbackPolls() {
        fallbackPollTask?.cancel()
        fallbackPollTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.fallbackPollIntervalNanoseconds)
                await self.requestPoll(reason: "fallback")
            }
        }
    }

    private func pollAndProcessOnce() async {
        guard let db else { return }
        let predicate = NSPredicate(format: "needsResponse == 1")
        let query = CKQuery(recordType: "Conversation", predicate: predicate)
        do {
            let (matchResults, _) = try await db.records(matching: query)
            if matchResults.isEmpty {
                return
            }
            // Avoid spamming the console with identical messages when polling rapidly.
            RelayLog.recordThrottled(category: "CloudKitRelay",
                                     key: "pending-count",
                                     minInterval: 1.0,
                                     message: "Found \(matchResults.count) pending conversation(s)")
            for (recordID, result) in matchResults {
                switch result {
                case .success(let record):
                    let key = recordID.recordName
                    // Skip if already being processed by another overlapping poll.
                    if await inFlight.tryInsert(key) {
                        log("Scheduling processing for pending record \(key)")
                        // Acquire a worker slot, then process on a detached background task.
                        Task.detached(priority: .utility) { [weak self] in
                            guard let self else { return }
                            await self.workers.acquire()
                            defer {
                                Task { await self.workers.release() }
                                // Keep the key in-flight for 30 seconds after
                                // processing completes.  CloudKit queries can
                                // return stale needsResponse==1 results right
                                // after a save; the cooldown prevents the Mac
                                // from re-processing the same conversation.
                                Task {
                                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                                    await self.inFlight.remove(key)
                                }
                            }
                            await self.process(record: record, database: db)
                        }
                    } else {
                        log("Record \(key) is already in-flight; skipping duplicate")
                    }
                case .failure(let error):
                    log("Failed to fetch record \(recordID.recordName): \(error.localizedDescription)")
                }
            }
        } catch {
            if isMissingConversationRecordType(error) {
                logPollingError("Polling skipped – CloudKit conversation record type missing. Waiting for first message…")
                return
            }
            logPollingError("Polling failed: \(error.localizedDescription)")
        }
    }

    private func process(record: CKRecord, database: CKDatabase) async {
        let recordName = record.recordID.recordName
        do {
            var envelope = try envelope(from: record)
            log("Generating reply for conversation \(envelope.conversationID.uuidString)")

            envelope = try await updateStatus(.acknowledged, for: record, database: database)
            envelope = try await updateStatus(.processing, for: record, database: database)

            let processingEnvelope = envelope
            // Stream incremental progress back to the client so the Cloud Relay
            // UI fills in as tokens are produced instead of staying frozen until
            // the whole reply lands. Partial writes are throttled and best-effort.
            let partialWriter = PartialReplyWriter(record: record,
                                                   database: database,
                                                   base: processingEnvelope)
            let reply = try await provider.generateReplyStreaming(for: processingEnvelope) { partial in
                await partialWriter.write(partial: partial)
            }
            await partialWriter.seal()
            let visibleReply = RelayMessage.visibleText(from: reply)
            let responseText = visibleReply.isEmpty ? reply : visibleReply
            let response = RelayMessage(
                conversationID: processingEnvelope.conversationID,
                role: "assistant",
                text: responseText,
                fullText: reply
            )

            try await update(record: record, database: database) { updatedRecord in
                let latestEnvelope: RelayEnvelope
                if let latestData = updatedRecord["conversationData"] as? Data,
                   let decoded = try? self.decoder.decode(RelayEnvelope.self, from: latestData) {
                    latestEnvelope = decoded
                } else {
                    latestEnvelope = processingEnvelope
                }

                let baseMessages = processingEnvelope.messages
                var mergedMessages = baseMessages + [response]
                var suffixMessages: [RelayMessage] = []
                let finalParameters = latestEnvelope.parameters

                var seenIdentifiers = Set(baseMessages.map { $0.id })
                seenIdentifiers.insert(response.id)

                // Only genuinely new *inbound* turns (e.g. a user message that
                // arrived mid-generation) count as a suffix. Streaming partial
                // assistant writes share the record and must not be re-appended
                // after the final reply.
                suffixMessages = latestEnvelope.messages.filter {
                    !seenIdentifiers.contains($0.id) && $0.role.lowercased() != "assistant"
                }
                if !suffixMessages.isEmpty {
                    mergedMessages.append(contentsOf: suffixMessages)
                }

                let finalNeedsResponse: Bool
                let finalStatus: RelayStatus
                if suffixMessages.isEmpty {
                    finalNeedsResponse = false
                    finalStatus = .completed
                } else {
                    finalNeedsResponse = latestEnvelope.needsResponse
                    finalStatus = finalNeedsResponse ? .pending : .completed
                }

                let mergedEnvelope = RelayEnvelope(
                    conversationID: processingEnvelope.conversationID,
                    messages: mergedMessages,
                    needsResponse: finalNeedsResponse,
                    parameters: finalParameters,
                    status: finalStatus,
                    statusUpdatedAt: Date(),
                    errorMessage: nil
                )

                updatedRecord["conversationData"] = try self.encoder.encode(mergedEnvelope) as CKRecordValue
                updatedRecord["lastUpdated"] = Date() as CKRecordValue
                updatedRecord["needsResponse"] = NSNumber(value: finalNeedsResponse ? 1 : 0)
                updatedRecord["status"] = mergedEnvelope.status.rawValue as CKRecordValue
                updatedRecord["conversationIDString"] = mergedEnvelope.conversationID.uuidString as CKRecordValue
                if let updatedAt = mergedEnvelope.statusUpdatedAt {
                    updatedRecord["statusUpdatedAt"] = updatedAt as CKRecordValue
                } else {
                    updatedRecord["statusUpdatedAt"] = nil
                }
                if let errorMessage = mergedEnvelope.errorMessage {
                    updatedRecord["errorMessage"] = errorMessage as CKRecordValue
                } else {
                    updatedRecord["errorMessage"] = nil
                }
                return (updatedRecord, ())
            }
            log("Saved response for conversation \(processingEnvelope.conversationID.uuidString)")
        } catch {
            log("Error processing record \(recordName): \(error.localizedDescription)")
            do {
                _ = try await updateEnvelope(record: record, database: database) { envelope in
                    RelayEnvelope(
                        conversationID: envelope.conversationID,
                        messages: envelope.messages,
                        needsResponse: false,
                        parameters: envelope.parameters,
                        status: .failed,
                        statusUpdatedAt: Date(),
                        errorMessage: error.localizedDescription
                    )
                }
            } catch {
                log("Failed to mark record \(recordName) as failed: \(error.localizedDescription)")
            }
        }
    }

    private func updateStatus(
        _ status: RelayStatus,
        for record: CKRecord,
        database: CKDatabase,
        errorMessage: String? = nil
    ) async throws -> RelayEnvelope {
        try await updateEnvelope(record: record, database: database) { envelope in
            RelayEnvelope(
                conversationID: envelope.conversationID,
                messages: envelope.messages,
                needsResponse: envelope.needsResponse,
                parameters: envelope.parameters,
                status: status,
                statusUpdatedAt: Date(),
                errorMessage: errorMessage
            )
        }
    }

    @discardableResult
    private func updateEnvelope(
        record: CKRecord,
        database: CKDatabase,
        mutate: @Sendable (RelayEnvelope) throws -> RelayEnvelope
    ) async throws -> RelayEnvelope {
        try await update(record: record, database: database) { workingRecord in
            let baseEnvelope = try envelope(from: workingRecord)
            let mutatedEnvelope = try mutate(baseEnvelope)
            workingRecord["conversationData"] = try self.encoder.encode(mutatedEnvelope) as CKRecordValue
            workingRecord["lastUpdated"] = Date() as CKRecordValue
            workingRecord["needsResponse"] = NSNumber(value: mutatedEnvelope.needsResponse ? 1 : 0)
            workingRecord["status"] = mutatedEnvelope.status.rawValue as CKRecordValue
            workingRecord["conversationIDString"] = mutatedEnvelope.conversationID.uuidString as CKRecordValue
            if let updatedAt = mutatedEnvelope.statusUpdatedAt {
                workingRecord["statusUpdatedAt"] = updatedAt as CKRecordValue
            } else {
                workingRecord["statusUpdatedAt"] = nil
            }
            if let errorMessage = mutatedEnvelope.errorMessage {
                workingRecord["errorMessage"] = errorMessage as CKRecordValue
            } else {
                workingRecord["errorMessage"] = nil
            }
            return (workingRecord, mutatedEnvelope)
        }
    }

    private func envelope(from record: CKRecord) throws -> RelayEnvelope {
        guard let data = record["conversationData"] as? Data else {
            throw InferenceError.decode
        }
        return try decoder.decode(RelayEnvelope.self, from: data)
    }

    private func ensureSubscription() async {
        guard let db else { return }
        let subscription = CKQuerySubscription(
            recordType: "Conversation",
            predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordUpdate, .firesOnRecordCreation]
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        do {
            try await db.save(subscription)
            log("Subscription \(subscriptionID) created")
        } catch {
            // It is fine if the subscription already exists.
            log("Subscription \(subscriptionID) save failed or already exists: \(error.localizedDescription)")
        }
    }

    private func update<T>(
        record: CKRecord,
        database: CKDatabase,
        mutate: @Sendable (CKRecord) throws -> (CKRecord, T)
    ) async throws -> T {
        var attempt = 0
        var lastError: Error?
        while attempt < 3 {
            let workingRecord: CKRecord
            do {
                workingRecord = try await database.record(for: record.recordID)
            } catch let error as CKError where error.code == .unknownItem {
                workingRecord = record
            }
            let (mutatedRecord, result) = try mutate(workingRecord)
            do {
                _ = try await database.save(mutatedRecord)
                return result
            } catch let error as CKError where error.code == .serverRecordChanged {
                lastError = error
                attempt += 1
                continue
            } catch {
                lastError = error
                break
            }
        }
        if let lastError {
            throw lastError
        }
        throw InferenceError.other("Unknown CloudKit update failure")
    }

    private func fetchOrMakeRecord(id: CKRecord.ID, database: CKDatabase) async throws -> CKRecord {
        do {
            log("Fetching conversation record \(id.recordName)")
            return try await database.record(for: id)
        } catch {
            log("Creating new conversation record \(id.recordName)")
            return CKRecord(recordType: "Conversation", recordID: id)
        }
    }

    private func save(_ record: CKRecord, database: CKDatabase) async throws {
        log("Saving record \(record.recordID.recordName)")
        _ = try await database.save(record)
        log("Saved record \(record.recordID.recordName)")
    }

    private func log(_ message: String) {
        RelayLog.record(category: "CloudKitRelay", message: message)
    }

    private func logPollingError(_ message: String) {
        let now = Date()
        if let lastMessage = lastPollingErrorMessage,
           lastMessage == message,
           let lastDate = lastPollingErrorDate,
           now.timeIntervalSince(lastDate) < pollingErrorThrottle {
            RelayLog.record(category: "CloudKitRelay", message: message, suppressConsole: true)
            return
        }
        lastPollingErrorMessage = message
        lastPollingErrorDate = now
        RelayLog.record(category: "CloudKitRelay", message: message)
    }

    private func isMissingConversationRecordType(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .unknownItem, .serverRejectedRequest, .zoneNotFound:
            return containsMissingRecordTypeMessage(error)
        case .partialFailure:
            if let partials = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                return partials.values.contains(where: containsMissingRecordTypeMessage)
            }
            return false
        default:
            return false
        }
    }

    private func containsMissingRecordTypeMessage(_ error: Error) -> Bool {
        let nsError = error as NSError
        let messages = [
            nsError.userInfo[NSLocalizedDescriptionKey] as? String,
            nsError.userInfo["CKErrorLocalizedDescriptionKey"] as? String,
            nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String
        ]
        return messages
            .compactMap { $0?.lowercased() }
            .contains { message in
                guard message.contains("record type") else { return false }
                if message.contains("conversation") { return true }
                return message.contains("'conversation'")
            }
    }
}

/// Serializes and throttles incremental "assistant is typing" writes for a
/// single conversation while the host generates a reply. Each write replaces
/// the conversation's last assistant message with the latest accumulated text.
/// Writes are best-effort: conflicts (the optimistic save retry of the final
/// reply, or another partial) are tolerated and simply skipped.
private actor PartialReplyWriter {
    private var record: CKRecord
    private let database: CKDatabase
    private let base: RelayEnvelope
    private let conversationID: UUID
    private let throttle: TimeInterval
    private let encoder = JSONEncoder()
    private var lastWrite = Date.distantPast
    private var lastLength = 0
    private var sealed = false

    init(record: CKRecord, database: CKDatabase, base: RelayEnvelope, throttle: TimeInterval = 1.0) {
        self.record = record
        self.database = database
        self.base = base
        self.conversationID = base.conversationID
        self.throttle = throttle
    }

    /// Stop accepting partials. Called right before the authoritative final
    /// write so a late partial can't revert the conversation to "processing".
    func seal() { sealed = true }

    func write(partial: String) async {
        guard !sealed else { return }
        let length = partial.count
        guard length > lastLength else { return }
        let now = Date()
        guard now.timeIntervalSince(lastWrite) >= throttle else { return }
        lastWrite = now
        lastLength = length

        let visible = RelayMessage.visibleText(from: partial)
        let assistant = RelayMessage(conversationID: conversationID,
                                     role: "assistant",
                                     text: visible,
                                     fullText: partial)
        let envelope = RelayEnvelope(
            conversationID: conversationID,
            messages: base.messages + [assistant],
            needsResponse: true,
            parameters: base.parameters,
            status: .processing,
            statusUpdatedAt: now,
            errorMessage: nil
        )
        guard let data = try? encoder.encode(envelope) else { return }
        record["conversationData"] = data as CKRecordValue
        record["lastUpdated"] = now as CKRecordValue
        record["needsResponse"] = NSNumber(value: 1)
        record["status"] = RelayStatus.processing.rawValue as CKRecordValue
        record["conversationIDString"] = conversationID.uuidString as CKRecordValue
        record["statusUpdatedAt"] = now as CKRecordValue
        do {
            record = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Another writer advanced the record; adopt the server copy so the
            // next partial builds on the latest change tag.
            if let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                record = server
            }
        } catch {
            // Best-effort streaming; drop this partial silently.
        }
    }
}
