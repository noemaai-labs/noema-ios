// Logger.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Simple async logger used to capture text messages in a file.
/// Declared as an actor so calls from various tasks remain concurrency-safe.
actor Logger {
    struct ObserverToken: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    /// Singleton instance used throughout the app.
    static let shared = Logger()

    /// URL of the log file on disk. Accessed from UI so marked nonisolated.
    nonisolated let logFileURL: URL

    private var handle: FileHandle?
    private var observers: [ObserverToken: @Sendable (String) -> Void] = [:]

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("noema.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        logFileURL = url
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    /// Appends a line of text to the log file.
    /// - Parameters:
    ///   - message: Text to log.
    ///   - truncateConsole: When true, large console messages are summarized to a preview.
    func log(_ message: String, truncateConsole: Bool = true) {
        if let data = (message + "\n").data(using: .utf8) {
            handle?.write(data)
        }
        for observer in observers.values {
            observer(message)
        }
        let maxConsoleChars = 10000
        if truncateConsole, message.count > maxConsoleChars {
            let preview = message.prefix(maxConsoleChars)
            writeConsoleLine(String(preview) + "… [truncated, len=\(message.count)]")
            return
        }
        if message.count <= maxConsoleChars {
            writeConsoleLine(message)
            return
        }
        writeToConsoleInChunks(message, chunkSize: maxConsoleChars)
    }

    /// Writes a console log without applying truncation.
    func logFull(_ message: String) {
        log(message, truncateConsole: false)
    }

    func addObserver(_ observer: @escaping @Sendable (String) -> Void) -> ObserverToken {
        let token = ObserverToken()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: ObserverToken) {
        observers.removeValue(forKey: token)
    }

    private func writeToConsoleInChunks(_ message: String, chunkSize: Int) {
        var start = message.startIndex
        var chunk = 1
        let total = Int(ceil(Double(message.count) / Double(chunkSize)))
        while start < message.endIndex {
            let end = message.index(start, offsetBy: chunkSize, limitedBy: message.endIndex) ?? message.endIndex
            let slice = message[start..<end]
            if total > 1 {
                writeConsoleLine("[log chunk \(chunk)/\(total)] \(slice)")
            } else {
                writeConsoleLine(String(slice))
            }
            start = end
            chunk += 1
        }
        if total > 1 {
            writeConsoleLine("[log end len=\(message.count)]")
        }
    }

    private func writeConsoleLine(_ message: String) {
        fputs(message + "\n", stderr)
        fflush(stderr)
    }
}

/// Convenience global constant for ease of use.
let logger = Logger.shared
