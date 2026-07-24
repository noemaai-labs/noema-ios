import Foundation

public enum PagedPackageError: LocalizedError, Equatable {
    case manifestMissing
    case manifestTooLarge
    case manifestUndecodable(String)
    case unsupportedFormatVersion(Int)
    case invalidGeometry(String)
    case unsafeFileName(String)
    case duplicateFileName(String)
    case recordOutOfBounds(String)
    case recordMisaligned(String)
    case recordsOverlap(String)
    case duplicateRecord(String)
    case incompleteCoverage(String)
    case inconsistentFamilies(String)
    case missingFile(String)
    case fileSizeMismatch(String)
    case fingerprintMismatch
    case checksumMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing: return "The paged package has no manifest.json."
        case .manifestTooLarge: return "The paged package manifest is unreasonably large."
        case .manifestUndecodable(let detail): return "The paged package manifest is unreadable: \(detail)"
        case .unsupportedFormatVersion(let v): return "Unsupported paged package format version \(v)."
        case .invalidGeometry(let detail): return "The paged package declares invalid geometry: \(detail)"
        case .unsafeFileName(let name): return "The paged package names an unsafe file '\(name)'."
        case .duplicateFileName(let name): return "The paged package names '\(name)' more than once."
        case .recordOutOfBounds(let detail): return "An expert record exceeds its payload file: \(detail)"
        case .recordMisaligned(let detail): return "An expert record violates package alignment: \(detail)"
        case .recordsOverlap(let detail): return "Expert records overlap: \(detail)"
        case .duplicateRecord(let detail): return "Duplicate expert record: \(detail)"
        case .incompleteCoverage(let detail): return "The paged package is missing expert records: \(detail)"
        case .inconsistentFamilies(let detail): return "Expert families are inconsistent: \(detail)"
        case .missingFile(let name): return "The paged package is missing '\(name)'."
        case .fileSizeMismatch(let name): return "The size of '\(name)' disagrees with the manifest."
        case .fingerprintMismatch: return "The paged package fingerprint does not match its contents."
        case .checksumMismatch(let detail): return "Expert data failed verification: \(detail)"
        }
    }
}

/// A structurally validated `.noema-paged` package on disk.
///
/// `load(at:)` performs every structural check (geometry, bounds, alignment,
/// overlap, coverage, safe names, file presence and sizes, fingerprint
/// recomputation). `validate(level:)` adds content verification. The native
/// runtime re-validates independently at launch; this type is the app-side
/// authority for install, download, and UI decisions.
public struct NoemaPagedPackage: Sendable {
    public enum ValidationLevel: Sendable {
        /// Everything `load(at:)` already guaranteed; no payload reads.
        case structural
        /// XXH64-verifies a deterministic sample of expert records.
        case spotCheck
        /// XXH64-verifies every record and SHA-256-verifies every file.
        case full
    }

    public let directoryURL: URL
    public let manifest: NoemaPagedPackageManifest

    public var manifestURL: URL {
        directoryURL.appendingPathComponent(NoemaPagedPackageManifest.manifestFileName)
    }
    public var residentGGUFURL: URL {
        directoryURL.appendingPathComponent(manifest.resident.path)
    }
    public var totalSizeBytes: UInt64 {
        manifest.resident.sizeBytes
            + manifest.expertFiles.reduce(0) { $0 + $1.sizeBytes }
            + (Self.fileSize(atPath: manifestURL.path) ?? 0)
    }

    private static func fileSize(atPath path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attributes[.size] as? NSNumber else {
            return nil
        }
        return number.uint64Value
    }

    private static let maxManifestBytes = 256 * 1024 * 1024
    private static let maxExperts: UInt32 = 1024
    private static let maxLayers: UInt32 = 4096
    private static let spotCheckSampleCount = 32

    /// Architectures the paged runtime currently whitelists. Loading a
    /// well-formed package for another architecture succeeds; launching it
    /// does not.
    public static let supportedArchitectures: Set<String> = ["qwen3moe", "qwen35moe", "gemma4"]

    public var isArchitectureSupported: Bool {
        Self.supportedArchitectures.contains(manifest.model.architecture)
    }

    public static func load(at directoryURL: URL) throws -> NoemaPagedPackage {
        let fm = FileManager.default
        let manifestURL = directoryURL.appendingPathComponent(NoemaPagedPackageManifest.manifestFileName)
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw PagedPackageError.manifestMissing
        }
        if let size = Self.fileSize(atPath: manifestURL.path), size > UInt64(maxManifestBytes) {
            throw PagedPackageError.manifestTooLarge
        }
        let data: Data
        let manifest: NoemaPagedPackageManifest
        do {
            data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(NoemaPagedPackageManifest.self, from: data)
        } catch let error as PagedPackageError {
            throw error
        } catch {
            throw PagedPackageError.manifestUndecodable(String(describing: error))
        }

        let package = NoemaPagedPackage(directoryURL: directoryURL, manifest: manifest)
        try package.validateStructure()
        return package
    }

    // MARK: - Structural validation

    private static func isSafeFlatName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255, !name.hasPrefix(".") else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("\0"), !name.contains("..") else { return false }
        return true
    }

    private func validateStructure() throws {
        let mf = manifest
        guard mf.formatVersion == NoemaPagedPackageManifest.currentFormatVersion else {
            throw PagedPackageError.unsupportedFormatVersion(mf.formatVersion)
        }
        guard mf.model.expertCount > 0, mf.model.expertCount <= Self.maxExperts else {
            throw PagedPackageError.invalidGeometry("expertCount \(mf.model.expertCount)")
        }
        guard mf.model.expertsUsedDefault > 0, mf.model.expertsUsedDefault <= mf.model.expertCount else {
            throw PagedPackageError.invalidGeometry("expertsUsedDefault \(mf.model.expertsUsedDefault)")
        }
        guard mf.model.totalLayerCount > 0, mf.model.totalLayerCount <= Self.maxLayers,
              mf.model.moeLayerCount > 0, mf.model.moeLayerCount <= mf.model.totalLayerCount else {
            throw PagedPackageError.invalidGeometry("layer counts")
        }
        guard mf.alignment >= 8, mf.alignment <= (1 << 24), (mf.alignment & (mf.alignment - 1)) == 0 else {
            throw PagedPackageError.invalidGeometry("alignment \(mf.alignment)")
        }
        guard !mf.fingerprint.isEmpty, mf.fingerprint.count <= 128 else {
            throw PagedPackageError.invalidGeometry("fingerprint")
        }
        guard !mf.expertFiles.isEmpty else {
            throw PagedPackageError.invalidGeometry("no expert files")
        }

        var names: Set<String> = [NoemaPagedPackageManifest.manifestFileName]
        for entry in [mf.resident] + mf.expertFiles {
            guard Self.isSafeFlatName(entry.path) else {
                throw PagedPackageError.unsafeFileName(entry.path)
            }
            guard names.insert(entry.path).inserted else {
                throw PagedPackageError.duplicateFileName(entry.path)
            }
        }

        // Record geometry, bounds, duplicates, uniformity, coverage.
        struct Geometry: Equatable {
            let ggmlType: Int32
            let ne: [Int64]
            let length: UInt64
        }
        var geometry: [UInt32: [NoemaPagedPackageManifest.Family: Geometry]] = [:]
        var coverage: [UInt32: [NoemaPagedPackageManifest.Family: Int]] = [:]
        var seen = Set<String>()
        var rangesPerFile: [UInt32: [(UInt64, UInt64)]] = [:]

        guard !mf.records.isEmpty else {
            throw PagedPackageError.incompleteCoverage("no records")
        }
        for r in mf.records {
            let key = "\(r.layer)/\(r.family.rawValue)/\(r.expert)"
            guard r.layer < mf.model.totalLayerCount else {
                throw PagedPackageError.invalidGeometry("record layer \(r.layer)")
            }
            guard r.expert < mf.model.expertCount else {
                throw PagedPackageError.invalidGeometry("record expert \(r.expert)")
            }
            guard Int(r.file) < mf.expertFiles.count else {
                throw PagedPackageError.recordOutOfBounds("\(key): file index")
            }
            guard r.length > 0, r.ne.count == 2, r.ne.allSatisfy({ $0 > 0 }) else {
                throw PagedPackageError.invalidGeometry("record \(key)")
            }
            guard r.offset % mf.alignment == 0 else {
                throw PagedPackageError.recordMisaligned(key)
            }
            let fileSize = mf.expertFiles[Int(r.file)].sizeBytes
            guard r.offset <= fileSize, r.length <= fileSize - r.offset else {
                throw PagedPackageError.recordOutOfBounds(key)
            }
            guard r.xxh64.count <= 16, !r.xxh64.isEmpty, UInt64(r.xxh64, radix: 16) != nil else {
                throw PagedPackageError.invalidGeometry("record \(key) checksum")
            }
            guard seen.insert(key).inserted else {
                throw PagedPackageError.duplicateRecord(key)
            }
            coverage[r.layer, default: [:]][r.family, default: 0] += 1
            let g = Geometry(ggmlType: r.ggmlType, ne: r.ne, length: r.length)
            if let existing = geometry[r.layer]?[r.family] {
                guard existing == g else {
                    throw PagedPackageError.inconsistentFamilies("\(r.layer)/\(r.family.rawValue) not uniform")
                }
            } else {
                geometry[r.layer, default: [:]][r.family] = g
            }
            rangesPerFile[r.file, default: []].append((r.offset, r.length))
        }

        for (file, ranges) in rangesPerFile {
            let sorted = ranges.sorted { $0.0 < $1.0 }
            for i in 1..<sorted.count where sorted[i].0 < sorted[i - 1].0 + sorted[i - 1].1 {
                throw PagedPackageError.recordsOverlap("file \(file)")
            }
        }

        var pagedLayers: UInt32 = 0
        for (layer, families) in geometry {
            pagedLayers += 1
            let separate = families[.gate] != nil && families[.up] != nil && families[.down] != nil && families[.gateUp] == nil
            let fused = families[.gateUp] != nil && families[.down] != nil && families[.gate] == nil && families[.up] == nil
            guard separate || fused else {
                throw PagedPackageError.inconsistentFamilies("layer \(layer) family set")
            }
            guard fused == mf.model.fusedGateUp else {
                throw PagedPackageError.inconsistentFamilies("fusedGateUp flag disagrees with records")
            }
            for family in families.keys {
                guard coverage[layer]?[family] == Int(mf.model.expertCount) else {
                    throw PagedPackageError.incompleteCoverage("layer \(layer) \(family.rawValue)")
                }
            }
        }
        guard pagedLayers == mf.model.moeLayerCount else {
            throw PagedPackageError.incompleteCoverage("moeLayerCount disagrees with records")
        }

        // Files must exist with the declared sizes.
        let fm = FileManager.default
        for entry in [mf.resident] + mf.expertFiles {
            let url = directoryURL.appendingPathComponent(entry.path)
            guard fm.fileExists(atPath: url.path) else {
                throw PagedPackageError.missingFile(entry.path)
            }
            guard Self.fileSize(atPath: url.path) == entry.sizeBytes else {
                throw PagedPackageError.fileSizeMismatch(entry.path)
            }
        }
    }

    // MARK: - Content verification

    public func validate(level: ValidationLevel) throws {
        switch level {
        case .structural:
            return // load(at:) already enforced everything structural
        case .spotCheck:
            try verifyRecords(sampledRecords())
        case .full:
            try verifyRecords(manifest.records)
            let residentHash = try PagedSHA256.hexDigest(ofFileAt: residentGGUFURL)
            guard residentHash == manifest.resident.sha256.lowercased() else {
                throw PagedPackageError.checksumMismatch(manifest.resident.path)
            }
            for entry in manifest.expertFiles {
                let hash = try PagedSHA256.hexDigest(ofFileAt: directoryURL.appendingPathComponent(entry.path))
                guard hash == entry.sha256.lowercased() else {
                    throw PagedPackageError.checksumMismatch(entry.path)
                }
            }
            let expected = NoemaPagedPackageManifest.computeFingerprint(
                residentSha256: manifest.resident.sha256.lowercased(),
                expertFileSha256s: manifest.expertFiles.map { $0.sha256.lowercased() })
            guard expected == manifest.fingerprint.lowercased() else {
                throw PagedPackageError.fingerprintMismatch
            }
        }
    }

    /// Deterministic pseudo-random sample seeded by the package fingerprint so
    /// repeated spot checks cover the same records (and tests can pin them).
    private func sampledRecords() -> [NoemaPagedPackageManifest.Record] {
        let records = manifest.records
        guard records.count > Self.spotCheckSampleCount else { return records }
        var seed = UInt64(manifest.fingerprint.prefix(16), radix: 16) ?? 0x9E37_79B9_7F4A_7C15
        var picked: [NoemaPagedPackageManifest.Record] = []
        var remaining = Set(records.indices)
        for _ in 0..<Self.spotCheckSampleCount {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let index = Int(seed % UInt64(records.count))
            if remaining.remove(index) != nil {
                picked.append(records[index])
            }
        }
        return picked.isEmpty ? [records[0]] : picked
    }

    private func verifyRecords(_ records: [NoemaPagedPackageManifest.Record]) throws {
        var handles: [UInt32: FileHandle] = [:]
        defer { handles.values.forEach { try? $0.close() } }
        for r in records {
            let handle: FileHandle
            if let existing = handles[r.file] {
                handle = existing
            } else {
                let url = directoryURL.appendingPathComponent(manifest.expertFiles[Int(r.file)].path)
                handle = try FileHandle(forReadingFrom: url)
                handles[r.file] = handle
            }
            try handle.seek(toOffset: r.offset)
            guard let payload = try handle.read(upToCount: Int(r.length)), payload.count == Int(r.length) else {
                throw PagedPackageError.checksumMismatch("\(r.layer)/\(r.family.rawValue)/\(r.expert): short read")
            }
            let expected = UInt64(r.xxh64, radix: 16) ?? 0
            guard PagedXXH64.hash(payload) == expected else {
                throw PagedPackageError.checksumMismatch("\(r.layer)/\(r.family.rawValue)/\(r.expert)")
            }
        }
    }
}
