import Foundation

/// Builds a `.noema-paged` package atomically: content is written into a
/// sibling staging directory on the same volume, fully validated, and only
/// then renamed into place. An interrupted build never leaves a partial
/// package at the final path.
public final class AtomicPackageBuilder {
    public let finalURL: URL
    public let stagingURL: URL
    private var finished = false

    public init(finalURL: URL) throws {
        self.finalURL = finalURL
        let parent = finalURL.deletingLastPathComponent()
        self.stagingURL = parent.appendingPathComponent(
            ".\(finalURL.lastPathComponent).building-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    }

    deinit {
        if !finished {
            try? FileManager.default.removeItem(at: stagingURL)
        }
    }

    public func stagedFileURL(for name: String) -> URL {
        stagingURL.appendingPathComponent(name)
    }

    /// Validates the staged package at the requested level and moves it into
    /// place. The final path is replaced atomically when it already exists.
    @discardableResult
    public func commit(validating level: NoemaPagedPackage.ValidationLevel = .full) throws -> NoemaPagedPackage {
        let staged = try NoemaPagedPackage.load(at: stagingURL)
        try staged.validate(level: level)

        let fm = FileManager.default
        if fm.fileExists(atPath: finalURL.path) {
            _ = try fm.replaceItemAt(finalURL, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: finalURL)
        }
        finished = true
        return try NoemaPagedPackage.load(at: finalURL)
    }

    public func abort() {
        finished = true
        try? FileManager.default.removeItem(at: stagingURL)
    }
}
