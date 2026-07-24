import CloudKit
import Foundation

private func canonicalHostDeviceID(_ id: String) -> String {
    id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}

private final class RelayQueryRecordCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CKRecord] = []
    private var firstError: Error?

    func capture(_ result: Result<CKRecord, Error>) {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success(let record):
            records.append(record)
        case .failure(let error):
            if firstError == nil { firstError = error }
        }
    }

    func values() throws -> [CKRecord] {
        lock.lock()
        defer { lock.unlock() }
        if let firstError { throw firstError }
        return records
    }
}

public struct RelayCatalogModelDraft: Sendable {
    public var modelID: String
    public var displayName: String
    public var provider: RelayProviderKind
    public var endpointID: String?
    public var identifier: String
    public var context: Int?
    public var quant: String?
    public var sizeBytes: Int64?
    public var tags: [String]
    public var exposed: Bool
    public var health: RelayModelHealth
    public var lastChecked: Date?
    public var overfitClassification: String?
    public var overfitMeasuredGenerationRate: Double?

    public init(modelID: String,
                displayName: String,
                provider: RelayProviderKind,
                endpointID: String?,
                identifier: String,
                context: Int?,
                quant: String?,
                sizeBytes: Int64?,
                tags: [String],
                exposed: Bool,
                health: RelayModelHealth,
                lastChecked: Date?,
                overfitClassification: String? = nil,
                overfitMeasuredGenerationRate: Double? = nil) {
        self.modelID = modelID
        self.displayName = displayName
        self.provider = provider
        self.endpointID = endpointID
        self.identifier = identifier
        self.context = context
        self.quant = quant
        self.sizeBytes = sizeBytes
        self.tags = tags
        self.exposed = exposed
        self.health = health
        self.lastChecked = lastChecked
        self.overfitClassification = overfitClassification
        self.overfitMeasuredGenerationRate = overfitMeasuredGenerationRate
    }
}

public struct RelayCatalogEndpointDraft: Sendable {
    public var endpointID: String
    public var kind: RelayEndpointKind
    public var baseURL: String
    public var authConfigured: Bool
    public var health: RelayEndpointHealth
    public var exposed: Bool

    public init(endpointID: String,
                kind: RelayEndpointKind,
                baseURL: String,
                authConfigured: Bool,
                health: RelayEndpointHealth,
                exposed: Bool) {
        self.endpointID = endpointID
        self.kind = kind
        self.baseURL = baseURL
        self.authConfigured = authConfigured
        self.health = health
        self.exposed = exposed
    }
}

public struct RelayCatalogSnapshot: Sendable {
    public var device: RelayDeviceRecord?
    public var models: [RelayModelRecord]
    public var endpoints: [RelayEndpointRecord]
    public var hostState: RelayHostStateRecord?
}

public actor RelayCatalogPublisher {
    public static let shared = RelayCatalogPublisher()

    private var container: CKContainer?
    private var database: CKDatabase?
    private var hostDeviceID: String?
    private var catalogVersion: Int = 0
    private var stateVersion: Int = 0
    private var cachedModels: [String: RelayModelRecord] = [:]
    private var cachedEndpoints: [String: RelayEndpointRecord] = [:]

    private let encoder = JSONEncoder()
    @discardableResult
    public func configure(containerIdentifier: String, hostDeviceID: String) -> Bool {
        let identifier = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let container = RelayCloudKitAccess.containerIfAvailable(identifier) else {
            container = nil
            database = nil
            self.hostDeviceID = nil
            log("CloudKit is unavailable for container \(identifier)")
            return false
        }
        self.container = container
        self.database = container.privateCloudDatabase
        let normalizedHost = canonicalHostDeviceID(hostDeviceID)
        self.hostDeviceID = normalizedHost
        catalogVersion = 0
        stateVersion = 0
        cachedModels.removeAll()
        cachedEndpoints.removeAll()
        log("Configured container: \(identifier), host: \(normalizedHost)")
        return true
    }

    /// Ensure a silent-push query subscription exists for relay commands targeting this host.
    /// This lets the Mac wake promptly when iOS enqueues a model-load or catalog command.
    public func ensureCommandSubscription() async {
        guard let db = try? ensureDatabase(),
              let hostID = try? requireHostDeviceID() else { return }
        let subscriptionID = "command-updates-\(hostID)"
        let predicate = NSPredicate(format: "hostDeviceID == %@", hostID)
        let subscription = CKQuerySubscription(
            recordType: RelayCatalogRecordType.command.rawValue,
            predicate: predicate,
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await db.save(subscription)
            log("Command subscription \(subscriptionID) created")
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Likely already exists; ignore quietly.
            log("Command subscription \(subscriptionID) already exists or rejected: \(error.localizedDescription)", suppressConsole: true, suppressUI: true)
        } catch {
            log("Failed to save command subscription \(subscriptionID): \(error.localizedDescription)")
        }
    }

    @discardableResult
    public func updateCatalog(deviceName: String,
                              capabilities: [String: String],
                              status: RelayHostStatus,
                              models: [RelayCatalogModelDraft],
                              endpoints: [RelayCatalogEndpointDraft]) async throws -> Int {
        let db = try ensureDatabase()
        let hostID = try requireHostDeviceID()
        log("Updating catalog for host: \(hostID) device: \(deviceName) models: \(models.count) endpoints: \(endpoints.count)")
        let deviceRecordID = recordID(for: .device, identifier: hostID)
        let deviceCK = try await fetchOrCreate(recordType: .device, recordID: deviceRecordID, database: db)
        if catalogVersion == 0, let existing = RelayDeviceRecord(record: deviceCK) {
            catalogVersion = existing.catalogVersion
        }
        let nextVersion = catalogVersion + 1
        let activeRef = try await currentActiveModelReference(database: db)
        let deviceRecord = RelayDeviceRecord(
            recordID: deviceRecordID,
            hostDeviceID: hostID,
            name: deviceName,
            lastSeen: Date(),
            capabilities: capabilities,
            catalogVersion: nextVersion,
            activeModelReference: activeRef,
            status: status
        )
        try deviceRecord.apply(to: deviceCK)

        var recordsToSave: [CKRecord] = [deviceCK]

        if cachedModels.isEmpty {
            log("Loading cached models from CloudKit")
            let predicate = NSPredicate(format: "hostDeviceID == %@", hostID)
            let records = try await fetchAllRecords(of: .model, predicate: predicate, database: db)
            for record in records {
                if let model = RelayModelRecord(record: record) {
                    cachedModels[model.modelID] = model
                }
            }
            log("Cached \(cachedModels.count) existing models")
        }

        var newModelIDs = Set<String>()
        for draft in models {
            newModelIDs.insert(draft.modelID)
            let recordID = recordID(for: .model, identifier: draft.modelID)
            let ck = try await fetchOrCreate(recordType: .model, recordID: recordID, database: db)
            log("Upserting model \(draft.modelID) exposed=\(draft.exposed) provider=\(draft.provider) endpoint=\(draft.endpointID ?? "nil")")
            let modelRecord = RelayModelRecord(
                recordID: recordID,
                modelID: draft.modelID,
                hostDeviceID: hostID,
                displayName: draft.displayName,
                provider: draft.provider,
                endpointID: draft.endpointID,
                identifier: draft.identifier,
                context: draft.context,
                quant: draft.quant,
                sizeBytes: draft.sizeBytes,
                tags: draft.tags,
                exposed: draft.exposed,
                health: draft.health,
                lastChecked: draft.lastChecked,
                version: nextVersion,
                overfitClassification: draft.overfitClassification,
                overfitMeasuredGenerationRate: draft.overfitMeasuredGenerationRate
            )
            modelRecord.apply(to: ck)
            recordsToSave.append(ck)
            cachedModels[draft.modelID] = modelRecord
        }

        let retiredModels = cachedModels.values.filter { !newModelIDs.contains($0.modelID) }
        for model in retiredModels {
            let recordID = recordID(for: .model, identifier: model.modelID)
            let ck = try await fetchOrCreate(recordType: .model, recordID: recordID, database: db)
            var retired = model
            retired.exposed = false
            retired.version = nextVersion
            retired.apply(to: ck)
            recordsToSave.append(ck)
            cachedModels[model.modelID] = retired
            log("Retiring model \(model.modelID)")
        }

        if cachedEndpoints.isEmpty {
            log("Loading cached endpoints from CloudKit")
            let predicate = NSPredicate(format: "hostDeviceID == %@", hostID)
            let records = try await fetchAllRecords(of: .endpoint, predicate: predicate, database: db)
            for record in records {
                if let endpoint = RelayEndpointRecord(record: record) {
                    cachedEndpoints[endpoint.endpointID] = endpoint
                }
            }
            log("Cached \(cachedEndpoints.count) existing endpoints")
        }

        var newEndpointIDs = Set<String>()
        for draft in endpoints {
            newEndpointIDs.insert(draft.endpointID)
            let recordID = recordID(for: .endpoint, identifier: draft.endpointID)
            let ck = try await fetchOrCreate(recordType: .endpoint, recordID: recordID, database: db)
            log("Upserting endpoint \(draft.endpointID) kind=\(draft.kind) baseURL=\(draft.baseURL) exposed=\(draft.exposed)")
            let endpointRecord = RelayEndpointRecord(
                recordID: recordID,
                endpointID: draft.endpointID,
                hostDeviceID: hostID,
                kind: draft.kind,
                baseURL: draft.baseURL,
                authConfigured: draft.authConfigured,
                health: draft.health,
                exposed: draft.exposed
            )
            endpointRecord.apply(to: ck)
            recordsToSave.append(ck)
            cachedEndpoints[draft.endpointID] = endpointRecord
        }

        let retiredEndpoints = cachedEndpoints.values.filter { !newEndpointIDs.contains($0.endpointID) }
        for endpoint in retiredEndpoints {
            let recordID = recordID(for: .endpoint, identifier: endpoint.endpointID)
            let ck = try await fetchOrCreate(recordType: .endpoint, recordID: recordID, database: db)
            var retired = endpoint
            retired.exposed = false
            retired.apply(to: ck)
            recordsToSave.append(ck)
            cachedEndpoints[endpoint.endpointID] = retired
            log("Retiring endpoint \(endpoint.endpointID)")
        }

        log("Saving \(recordsToSave.count) records for catalog version \(nextVersion)")
        try await save(recordsToSave, database: db)
        catalogVersion = nextVersion
        log("Catalog update succeeded. New version \(catalogVersion)")
        return catalogVersion
    }

    @discardableResult
    public func updateHostState(status: RelayHostStatus,
                                activeModelID: String?,
                                tokensPerSecond: Double?,
                                context: Int?,
                                changedBy: String) async throws -> RelayHostStateRecord {
        let db = try ensureDatabase()
        let hostID = try requireHostDeviceID()
        log("Updating host state for \(hostID) status=\(status) activeModel=\(activeModelID ?? "nil")")
        let hostStateRecordID = recordID(for: .hostState, identifier: hostID)
        let ck = try await fetchOrCreate(recordType: .hostState, recordID: hostStateRecordID, database: db)
        if stateVersion == 0, let existing = RelayHostStateRecord(record: ck) {
            stateVersion = existing.stateVersion
        }
        let nextVersion = stateVersion + 1
        let reference: CKRecord.Reference?
        if let activeModelID {
            let modelID = recordID(for: .model, identifier: activeModelID)
            reference = CKRecord.Reference(recordID: modelID, action: .none)
        } else {
            reference = nil
        }
        let hostState = RelayHostStateRecord(
            recordID: hostStateRecordID,
            hostDeviceID: hostID,
            activeModelReference: reference,
            status: status,
            tokensPerSecond: tokensPerSecond,
            context: context,
            stateVersion: nextVersion,
            lastChangedBy: changedBy,
            lastUpdated: Date()
        )
        hostState.apply(to: ck)
        try await save([ck], database: db)
        stateVersion = nextVersion
        log("Host state update succeeded. New version \(stateVersion)")
        return hostState
    }

    public func fetchQueuedCommands(limit: Int = 20) async throws -> [RelayCommandRecord] {
        guard limit > 0 else { return [] }
        let db = try ensureDatabase()
        let hostID = try requireHostDeviceID()
        // Suppress this very chatty polling message from the UI console; keep it out of stdout too
        log("Fetching up to \(limit) queued commands for host \(hostID)", suppressConsole: true, suppressUI: true)
        let predicate = NSPredicate(format: "hostDeviceID == %@ AND state == %@", hostID, RelayCommandState.queued.rawValue)
        let query = CKQuery(recordType: RelayCatalogRecordType.command.rawValue, predicate: predicate)
        let operation = CKQueryOperation(query: query)
        operation.resultsLimit = limit
        let collector = RelayQueryRecordCollector()
        operation.recordMatchedBlock = { _, result in
            collector.capture(result)
        }
        do {
            _ = try await runQuery(operation, database: db)
            let records = try collector.values().compactMap(RelayCommandRecord.init(record:))
            for command in records {
                log("Fetched queued command \(command.recordID.recordName) verb=\(command.verb) path=\(command.path)")
            }
            log("Fetched \(records.count) queued commands")
            return records
        } catch {
            if isMissingRecordTypeError(error, expected: .command) {
                log("Command record type missing; treating as no queued commands")
                return []
            }
            log("Failed to fetch queued commands: \(error.localizedDescription)")
            throw error
        }
    }

    public func claim(command: RelayCommandRecord,
                      leaseOwner: String,
                      leaseDuration: TimeInterval = 30) async throws -> RelayCommandRecord? {
        let db = try ensureDatabase()
        log("Attempting to claim command \(command.recordID.recordName) for \(leaseOwner)")
        let ck = try await fetchOrCreate(recordType: .command, recordID: command.recordID, database: db, allowCreate: false)
        guard let current = RelayCommandRecord(record: ck), current.state == .queued else {
            log("Command \(command.recordID.recordName) is no longer queued")
            return nil
        }
        let leaseUntil = Date().addingTimeInterval(leaseDuration)
        ck["state"] = RelayCommandState.running.rawValue as CKRecordValue
        ck["leaseOwner"] = leaseOwner as CKRecordValue
        ck["leaseUntil"] = leaseUntil as CKRecordValue
        ck["updatedAt"] = Date() as CKRecordValue
        try await save([ck], database: db)
        log("Command \(command.recordID.recordName) claimed until \(leaseUntil)")
        return RelayCommandRecord(record: ck)
    }

    public func complete(commandID: CKRecord.ID,
                         state: RelayCommandState,
                         statusCode: Int?,
                         result: Data?,
                         errorMessage: String?) async throws {
        let db = try ensureDatabase()
        log("Completing command \(commandID.recordName) state=\(state) statusCode=\(statusCode?.description ?? "nil")")
        let ck = try await fetchOrCreate(recordType: .command, recordID: commandID, database: db, allowCreate: false)
        ck["state"] = state.rawValue as CKRecordValue
        if let statusCode {
            ck["statusCode"] = NSNumber(value: statusCode)
        } else {
            ck["statusCode"] = nil
        }
        if let result {
            ck["result"] = result as CKRecordValue
        } else {
            ck["result"] = nil
        }
        ck["updatedAt"] = Date() as CKRecordValue
        if let errorMessage {
            let payload = try? encoder.encode(["error": errorMessage])
            ck["result"] = payload as CKRecordValue?
            log("Attached error payload for command \(commandID.recordName): \(errorMessage)")
        }
        ck["leaseOwner"] = nil
        ck["leaseUntil"] = nil
        try await save([ck], database: db)
        log("Command \(commandID.recordName) completion saved")
    }

    public func currentCatalogVersion() -> Int { catalogVersion }
    public func currentStateVersion() -> Int { stateVersion }

    private func ensureDatabase() throws -> CKDatabase {
        if let database { return database }
        throw RelayError.notConfigured
    }

    private func requireHostDeviceID() throws -> String {
        if let hostDeviceID { return hostDeviceID }
        throw RelayError.notConfigured
    }

    private func currentActiveModelReference(database: CKDatabase) async throws -> CKRecord.Reference? {
        let hostID = try requireHostDeviceID()
        let recordID = recordID(for: .hostState, identifier: hostID)
        do {
            log("Fetching current active model reference for host \(hostID)")
            let record = try await database.record(for: recordID)
            return record["activeModelRef"] as? CKRecord.Reference
        } catch {
            log("No active model reference found: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchOrCreate(recordType: RelayCatalogRecordType,
                                recordID: CKRecord.ID,
                                database: CKDatabase,
                                allowCreate: Bool = true) async throws -> CKRecord {
        do {
            log("Fetching \(recordType.rawValue) record \(recordID.recordName)")
            return try await database.record(for: recordID)
        } catch {
            log("Missing \(recordType.rawValue) record \(recordID.recordName); creating new: \(!allowCreate ? "no" : "yes")")
            if allowCreate {
                return CKRecord(recordType: recordType.rawValue, recordID: recordID)
            }
            throw error
        }
    }

    private func save(_ records: [CKRecord], database: CKDatabase) async throws {
        guard !records.isEmpty else { return }
        log("Saving batch of \(records.count) record(s)")
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .changedKeys
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    self.log("Successfully saved \(records.count) record(s)")
                    continuation.resume()
                case .failure(let error):
                    self.log("Failed to save records: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func runQuery(_ operation: CKQueryOperation, database: CKDatabase) async throws -> CKQueryOperation.Cursor? {
        try await withCheckedThrowingContinuation { continuation in
            // Run CloudKit work at a utility/background priority so it never
            // competes with UI rendering on the main thread.
            operation.queuePriority = .normal
            operation.qualityOfService = .utility
            operation.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    continuation.resume(returning: cursor)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func fetchAllRecords(of type: RelayCatalogRecordType,
                                 predicate: NSPredicate,
                                 database: CKDatabase) async throws -> [CKRecord] {
        var results: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let operation: CKQueryOperation
            if let existingCursor = cursor {
                operation = CKQueryOperation(cursor: existingCursor)
            } else {
                let query = CKQuery(recordType: type.rawValue, predicate: predicate)
                operation = CKQueryOperation(query: query)
            }
            let collector = RelayQueryRecordCollector()
            operation.recordMatchedBlock = { _, result in
                collector.capture(result)
            }
            log("Executing query for \(type.rawValue) records")
            cursor = try await runQuery(operation, database: database)
            results.append(contentsOf: try collector.values())
        } while cursor != nil
        log("Fetched \(results.count) \(type.rawValue) record(s)")
        return results
    }

    private func recordID(for type: RelayCatalogRecordType, identifier: String) -> CKRecord.ID {
        switch type {
        case .device:
            return CKRecord.ID(recordName: "device-\(canonicalHostDeviceID(identifier))")
        case .model:
            return CKRecord.ID(recordName: "model-\(identifier)")
        case .endpoint:
            return CKRecord.ID(recordName: "endpoint-\(identifier)")
        case .hostState:
            return CKRecord.ID(recordName: "hoststate-\(canonicalHostDeviceID(identifier))")
        case .command:
            return CKRecord.ID(recordName: identifier)
        }
    }

    nonisolated private func log(_ message: String, suppressConsole: Bool = true, suppressUI: Bool = false) {
        RelayLog.record(category: "RelayCatalogPublisher", message: message, suppressConsole: suppressConsole, storeInUI: !suppressUI)
    }

    nonisolated private func isMissingRecordTypeError(_ error: Error, expected: RelayCatalogRecordType) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .unknownItem, .serverRejectedRequest, .zoneNotFound:
            return containsMissingRecordTypeMessage(error, expected: expected)
        case .partialFailure:
            if let partials = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                return partials.values.contains { containsMissingRecordTypeMessage($0, expected: expected) }
            }
            return false
        default:
            return false
        }
    }

    nonisolated private func containsMissingRecordTypeMessage(_ error: Error,
                                                              expected: RelayCatalogRecordType) -> Bool {
        let nsError = error as NSError
        let lowercasedNeedle = expected.rawValue.lowercased()
        let messages = [
            nsError.userInfo[NSLocalizedDescriptionKey] as? String,
            nsError.userInfo["CKErrorLocalizedDescriptionKey"] as? String,
            nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String
        ]
        return messages
            .compactMap { $0?.lowercased() }
            .contains { message in
                guard message.contains("record type") else { return false }
                if message.contains(lowercasedNeedle) { return true }
                return message.contains("'\(lowercasedNeedle)'")
            }
    }
}

public actor RelayCatalogClient {
    public static let shared = RelayCatalogClient()

    private var containers: [String: CKContainer] = [:]

    public func fetchCatalog(containerIdentifier: String, hostDeviceID: String) async throws -> RelayCatalogSnapshot {
        let database = try await database(for: containerIdentifier)
        let normalizedHostID = canonicalHostDeviceID(hostDeviceID)
        log("Fetching catalog for host \(normalizedHostID) container \(containerIdentifier)")
        let deviceRecord = try? await database.record(for: recordID(for: .device, identifier: normalizedHostID))
        let device = deviceRecord.flatMap(RelayDeviceRecord.init(record:))

        let modelPredicate = NSPredicate(format: "hostDeviceID == %@ AND exposed == 1", normalizedHostID)
        let modelRecords = try await queryAllIfRecordTypeExists(
            database: database,
            recordType: .model,
            predicate: modelPredicate
        )
        log("Fetched \(modelRecords.count) model record(s)")
        let models = modelRecords.compactMap(RelayModelRecord.init(record:))

        let endpointPredicate = NSPredicate(format: "hostDeviceID == %@ AND exposed == 1", normalizedHostID)
        let endpointRecords = try await queryAllIfRecordTypeExists(
            database: database,
            recordType: .endpoint,
            predicate: endpointPredicate
        )
        log("Fetched \(endpointRecords.count) endpoint record(s)")
        let endpoints = endpointRecords.compactMap(RelayEndpointRecord.init(record:))

        let hostStateRecord = try? await database.record(for: recordID(for: .hostState, identifier: normalizedHostID))
        let hostState = hostStateRecord.flatMap(RelayHostStateRecord.init(record:))

        if let hostState {
            log("Fetched host state version \(hostState.stateVersion) status=\(hostState.status)")
        } else {
            log("No host state record found")
        }

        return RelayCatalogSnapshot(device: device, models: models, endpoints: endpoints, hostState: hostState)
    }

    public func createCommand(containerIdentifier: String,
                               hostDeviceID: String,
                               verb: String,
                               path: String,
                               body: Data?,
                               idempotencyKey: String? = nil) async throws -> RelayCommandRecord {
        let database = try await database(for: containerIdentifier)
        let normalizedHostID = canonicalHostDeviceID(hostDeviceID)
        log("Creating command verb=\(verb) path=\(path) host=\(normalizedHostID)")
        let recordID = CKRecord.ID(recordName: UUID().uuidString)
        let record = CKRecord(recordType: RelayCatalogRecordType.command.rawValue, recordID: recordID)
        record["hostDeviceID"] = normalizedHostID as CKRecordValue
        record["verb"] = verb as CKRecordValue
        record["path"] = path as CKRecordValue
        record["state"] = RelayCommandState.queued.rawValue as CKRecordValue
        record["body"] = body as CKRecordValue?
        record["createdAt"] = Date() as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        record["idempotencyKey"] = idempotencyKey as CKRecordValue?
        try await withCheckedThrowingContinuation { continuation in
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.savePolicy = .allKeys
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    self.log("Command \(recordID.recordName) saved")
                    continuation.resume()
                case .failure(let error):
                    self.log("Failed to save command \(recordID.recordName): \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
            database.add(op)
        }
        guard let command = RelayCommandRecord(record: record) else {
            throw RelayError.decodingFailed
        }
        log("Command \(command.recordID.recordName) created successfully")
        return command
    }

    public func waitForCommand(containerIdentifier: String,
                                commandID: CKRecord.ID,
                                timeout: TimeInterval = 60) async throws -> RelayCommandRecord {
        let database = try await database(for: containerIdentifier)
        let deadline = Date().addingTimeInterval(timeout)
        log("Waiting for command \(commandID.recordName) completion with timeout \(timeout)s")
        while Date() < deadline {
            let record = try await database.record(for: commandID)
            if let command = RelayCommandRecord(record: record), command.state != .queued, command.state != .running {
                log("Command \(commandID.recordName) completed with state \(command.state)")
                return command
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        log("Timed out waiting for command \(commandID.recordName)")
        throw RelayError.timeout
    }

    private func database(for containerIdentifier: String) async throws -> CKDatabase {
        let identifier = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let container = RelayCloudKitAccess.containerIfAvailable(identifier) else {
            log("CloudKit is unavailable for container \(identifier)")
            throw RelayError.notConfigured
        }
        if let container = containers[identifier] {
            log("Reusing cached container \(identifier)")
            return container.privateCloudDatabase
        }
        log("Creating container \(identifier)")
        containers[identifier] = container
        return container.privateCloudDatabase
    }

    private func queryAll(database: CKDatabase, query: CKQuery) async throws -> [CKRecord] {
        var results: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let operation: CKQueryOperation
            if let cursor {
                operation = CKQueryOperation(cursor: cursor)
            } else {
                operation = CKQueryOperation(query: query)
            }
            let collector = RelayQueryRecordCollector()
            operation.recordMatchedBlock = { _, result in
                collector.capture(result)
            }
            log("Executing query with \(results.count) accumulated result(s)")
            cursor = try await runQuery(operation, database: database)
            results.append(contentsOf: try collector.values())
        } while cursor != nil
        log("Query finished with \(results.count) record(s)")
        return results
    }

    private func runQuery(_ operation: CKQueryOperation, database: CKDatabase) async throws -> CKQueryOperation.Cursor? {
        try await withCheckedThrowingContinuation { continuation in
            operation.queuePriority = .high
            operation.qualityOfService = .userInitiated
            operation.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    self.log("Query succeeded; cursor=\(cursor == nil ? "nil" : "present")")
                    continuation.resume(returning: cursor)
                case .failure(let error):
                    self.log("Query failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func queryAllIfRecordTypeExists(database: CKDatabase,
                                            recordType: RelayCatalogRecordType,
                                            predicate: NSPredicate) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType.rawValue, predicate: predicate)
        do {
            let records = try await queryAll(database: database, query: query)
            log("Fetched \(records.count) records for type \(recordType.rawValue)")
            return records
        } catch {
            if isMissingRecordTypeError(error, expected: recordType) {
                log("Record type \(recordType.rawValue) missing; returning empty result")
                return []
            }
            log("Query for \(recordType.rawValue) failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func isMissingRecordTypeError(_ error: Error, expected: RelayCatalogRecordType) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .unknownItem, .serverRejectedRequest, .zoneNotFound:
            return containsMissingRecordTypeMessage(ckError, expected: expected)
        case .partialFailure:
            if let partials = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                return partials.values.contains { isMissingRecordTypeError($0, expected: expected) }
            }
            return false
        default:
            return false
        }
    }

    private func containsMissingRecordTypeMessage(_ error: Error,
                                                  expected: RelayCatalogRecordType) -> Bool {
        let nsError = error as NSError
        let lowercasedNeedle = expected.rawValue.lowercased()
        let messages = [
            nsError.userInfo[NSLocalizedDescriptionKey] as? String,
            nsError.userInfo["CKErrorLocalizedDescriptionKey"] as? String,
            nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String
        ]
        return messages
            .compactMap { $0?.lowercased() }
            .contains { message in
                guard message.contains("record type") else { return false }
                let colonNeedle = "record type: \(lowercasedNeedle)"
                let spacedNeedle = "record type \(lowercasedNeedle)"
                let quotedNeedle = "record type '\(lowercasedNeedle)'"
                if message.contains("did not find record type") { return true }
                if message.contains(colonNeedle) { return true }
                if message.contains(spacedNeedle) { return true }
                return message.contains(quotedNeedle)
            }
    }

    private func recordID(for type: RelayCatalogRecordType, identifier: String) -> CKRecord.ID {
        switch type {
        case .device:
            return CKRecord.ID(recordName: "device-\(canonicalHostDeviceID(identifier))")
        case .model:
            return CKRecord.ID(recordName: "model-\(identifier)")
        case .endpoint:
            return CKRecord.ID(recordName: "endpoint-\(identifier)")
        case .hostState:
            return CKRecord.ID(recordName: "hoststate-\(canonicalHostDeviceID(identifier))")
        case .command:
            return CKRecord.ID(recordName: identifier)
        }
    }

    nonisolated private func log(_ message: String) {
        RelayLog.record(category: "RelayCatalogClient", message: message, suppressConsole: true)
    }
}

public enum RelayError: Error {
    case notConfigured
    case timeout
    case decodingFailed
}
