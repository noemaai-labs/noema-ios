import Foundation

public struct RelayLogEntry: Identifiable, Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case normal
        case lanTransition
    }

    public let id: UUID
    public let timestamp: Date
    public let category: String
    public let message: String
    public let style: Style

    public init(id: UUID = UUID(),
                timestamp: Date = Date(),
                category: String,
                message: String,
                style: Style = .normal) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.style = style
    }

    public var formattedTimestamp: String {
        let formatter = RelayLogDateFormatter.shared
        return formatter.string(from: timestamp)
    }
}

@MainActor
public final class RelayLogStore: ObservableObject {
    public static let shared = RelayLogStore()

    @Published
    public private(set) var entries: [RelayLogEntry] = []

    // Keep the console performant by bounding memory and diff work.
    // Trim in chunks to avoid frequent O(n) front-removals.
    private static let maxEntries = 800
    private static let trimToEntries = 600

    // Batch appends so SwiftUI doesn’t diff/re-layout on every single log line.
    private var pending: [RelayLogEntry] = []
    private var flushTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var isPinnedToBottom: Bool = true

    private static var liveFlushInterval: TimeInterval {
        RelayPerformanceConfig.liveFlushInterval()
    }

    private static var idleFlushInterval: TimeInterval {
        RelayPerformanceConfig.idleFlushInterval()
    }

    private init() {}

    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            flushTask?.cancel()
            flushTask = nil
        } else {
            scheduleFlush(immediate: true)
        }
    }

    public func setPinned(_ pinned: Bool) {
        isPinnedToBottom = pinned
        // No immediate action; next schedule will use new cadence.
    }

    public func append(_ entry: RelayLogEntry) {
        if isPaused {
            pending.append(entry)
            if pending.count > Self.maxEntries {
                let toRemove = pending.count - Self.trimToEntries
                if toRemove > 0 && toRemove <= pending.count {
                    pending.removeFirst(toRemove)
                }
            }
            return
        }
        pending.append(entry)
        if pending.count > Self.maxEntries {
            let toRemove = pending.count - Self.trimToEntries
            if toRemove > 0 && toRemove <= pending.count {
                pending.removeFirst(toRemove)
            }
        }
        scheduleFlush(immediate: false)
    }

    public func appendBatch(_ entries: [RelayLogEntry]) {
        if entries.isEmpty { return }
        if isPaused {
            pending.append(contentsOf: entries)
        } else {
            pending.append(contentsOf: entries)
            scheduleFlush(immediate: false)
        }
        if pending.count > Self.maxEntries {
            let toRemove = pending.count - Self.trimToEntries
            if toRemove > 0 && toRemove <= pending.count {
                pending.removeFirst(toRemove)
            }
        }
    }

    public func clear() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll(keepingCapacity: true)
        entries.removeAll()
    }

    private func scheduleFlush(immediate: Bool) {
        guard flushTask == nil else { return }
        let delay = immediate ? 0 : (isPinnedToBottom ? Self.liveFlushInterval : Self.idleFlushInterval)
        flushTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self.flushPending()
        }
    }

    private func flushPending() async {
        if pending.isEmpty {
            flushTask = nil
            return
        }
        let perFlushLimit = 120
        let slice = Array(pending.prefix(perFlushLimit))
        entries.append(contentsOf: slice)
        pending.removeFirst(slice.count)
        if entries.count > Self.maxEntries {
            let toRemove = entries.count - Self.trimToEntries
            if toRemove > 0 && toRemove <= entries.count {
                entries.removeFirst(toRemove)
            }
        }
        flushTask = nil
        if !pending.isEmpty {
            // Schedule another flush soon to drain the remainder without blocking UI.
            scheduleFlush(immediate: false)
        }
    }
}

@MainActor
public enum RelayConsoleGate {
    // Toggled by the RelayManagementView onAppear/onDisappear
    public static var isActive: Bool = false
}

public enum RelayLog {
    public static func record(category: String,
                               message: String,
                               suppressConsole: Bool = false,
                               style: RelayLogEntry.Style = .normal,
                               storeInUI: Bool = true) {
        if !suppressConsole {
            print("[\(category)] \(message)")
        }
        guard storeInUI, shouldStoreInUI(category: category, style: style) else { return }
        let entry = RelayLogEntry(category: category, message: message, style: style)
        // Offload UI log ingestion to a background buffer that batches
        // and flushes to the main actor at a controlled cadence.
        Task.detached(priority: .utility) {
            await RelayLogBuffer.shared.enqueue(entry)
        }
    }

    public static func recordThrottled(category: String,
                                       key: String,
                                       minInterval: TimeInterval,
                                       message: String,
                                       suppressConsole: Bool = false,
                                       style: RelayLogEntry.Style = .normal,
                                       storeInUI: Bool = true) {
        Task.detached(priority: .utility) {
            let allow = await RelayLogLimiter.shared.shouldLog(key: category + "|" + key, minInterval: minInterval)
            guard allow else { return }
            RelayLog.record(category: category,
                            message: message,
                            suppressConsole: suppressConsole,
                            style: style,
                            storeInUI: storeInUI)
        }
    }

    private static func shouldStoreInUI(category: String,
                                        style: RelayLogEntry.Style) -> Bool {
        // Only surface high-level relay categories in the macOS console.
        // Chatty background systems like CloudKit stay off the SwiftUI log
        // while still printing to stdout when requested.
        switch category {
        case "RelayManagement",
             "RelayServer",
             "RelayServerEngine",
             "RelayHTTPServer":
            return true
        case "CloudKitRelay",
             "RelayCatalogPublisher",
             "RelayCatalogClient":
            return false
        default:
            return true
        }
    }
}

private final class RelayLogDateFormatter: @unchecked Sendable {
    static let shared = RelayLogDateFormatter()

    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        formatter.locale = Locale.autoupdatingCurrent
        return formatter
    }()

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}
