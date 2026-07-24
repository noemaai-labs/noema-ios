import Foundation
import os
import NoemaPackages

enum PagedPackageLocator {
    /// Walks up from `url` looking for an enclosing `.noema-paged` directory
    /// that carries a manifest. Mirrors the ANE artifact walk-up: bounded and
    /// guarded against non-shrinking paths.
    static func enclosingPackage(for url: URL) -> URL? {
        var current = url.standardizedFileURL
        for _ in 0..<16 {
            if current.pathExtension == NoemaPagedPackageManifest.packageDirectoryExtension {
                let manifest = current.appendingPathComponent(NoemaPagedPackageManifest.manifestFileName)
                if FileManager.default.fileExists(atPath: manifest.path) {
                    return current
                }
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || parent.path.isEmpty {
                return nil
            }
            current = parent
        }
        return nil
    }

    /// Memoized: NoemaLlamaClient consults this per request as the last-resort
    /// paged-session signal, and the walk-up stats a manifest per ancestor. A
    /// verdict can only change by reinstalling at the same path, which always
    /// goes through a fresh app-visible model URL.
    private static let installCache = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    static func isPagedInstall(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        if let cached = installCache.withLock({ $0[key] }) {
            return cached
        }
        let verdict = enclosingPackage(for: url) != nil
        installCache.withLock { $0[key] = verdict }
        return verdict
    }

    /// The resident GGUF inside a package directory. The conventional name is
    /// guaranteed by both converters, so the hot path is a single stat; the
    /// manifest (which can be many MB for large models) is only decoded when
    /// the convention is broken, and that verdict is memoized — canonicalURL
    /// calls this constantly from list and settings surfaces.
    private static let residentCache = OSAllocatedUnfairLock<[String: URL]>(initialState: [:])

    static func residentGGUF(inPackage directory: URL) -> URL {
        let key = directory.standardizedFileURL.path
        if let cached = residentCache.withLock({ $0[key] }) {
            return cached
        }
        let conventional = directory.appendingPathComponent("resident.gguf")
        let resolved: URL
        if FileManager.default.fileExists(atPath: conventional.path) {
            resolved = conventional
        } else if let package = try? NoemaPagedPackage.load(at: directory) {
            resolved = package.residentGGUFURL
        } else {
            resolved = conventional
        }
        residentCache.withLock { $0[key] = resolved }
        return resolved
    }

    /// Multi-gigabyte expert sidecars must never ride along in device backups.
    /// Idempotent; pattern follows ANEModelResolver.excludeFromBackup.
    static func excludeFromBackupIfNeeded(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Total on-disk footprint of the package (resident + sidecars + manifest).
    /// Summed from directory entries — never decodes the manifest (multi-MB
    /// for large models); registration stores the authoritative figure.
    static func packageTotalBytes(_ directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return items.reduce(Int64(0)) { total, item in
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }
}
